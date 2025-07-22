local json = require("lua.json")
local Websocket = {}

-- Platform detection using os.getenv and basic detection
local function detect_platform()
    local path_sep = package.config:sub(1,1)
    if path_sep == '\\' then
        return "windows"
    end
    
    -- Try to detect based on environment variables
    if os.getenv("OSTYPE") then
        local ostype = os.getenv("OSTYPE"):lower()
        if ostype:match("darwin") then
            return "darwin"
        elseif ostype:match("linux") then  
            return "linux"
        end
    end
    
    -- Fallback detection
    local handle = io.popen("uname -s 2>/dev/null")
    if handle then
        local uname = handle:read("*a"):lower():gsub("%s+$", "")
        handle:close()
        if uname:match("darwin") then
            return "darwin"
        elseif uname:match("linux") then
            return "linux"
        end
    end
    
    return "linux" -- default fallback
end

local function detect_arch()
    -- Try environment variable first
    local arch = os.getenv("HOSTTYPE") or os.getenv("MACHTYPE")
    if arch then
        if arch:match("x86_64") or arch:match("amd64") then
            return "x86_64"
        end
    end
    
    -- Try uname
    local handle = io.popen("uname -m 2>/dev/null")
    if handle then
        local machine = handle:read("*a"):gsub("%s+$", "")
        handle:close()
        if machine:match("x86_64") or machine:match("amd64") then
            return "x86_64"
        end
    end
    
    return "arm64" -- default fallback
end

-- Platform detection for binary selection
local function pick_binary()
    local platform = detect_platform()
    local arch = detect_arch()

    local binaries = {
        darwin = {
            x86_64 = "/dist/go-ws-proxy-darwin-amd64",
            default = "/dist/go-ws-proxy-darwin-arm64",
        },
        linux = {
            x86_64 = "/dist/go-ws-proxy-linux-amd64",
            default = "/dist/go-ws-proxy-linux-arm64",
        },
        windows = {
            x86_64 = "/dist/go-ws-proxy-windows-amd64",
            default = "/dist/go-ws-proxy-windows-arm64",
        },
    }

    if binaries[platform] then
        if type(binaries[platform]) == "table" then
            return binaries[platform][arch] or binaries[platform].default
        end
        return binaries[platform]
    end

    return ""
end

-- Reconnection settings
local reconnect_attempts = 0
local max_reconnect_attempts = 300
local reconnect_delay = 1000

-- Internal state
local websocket_job = nil
local message_handlers = {}
local status_callbacks = {}

-- Process management interface - must be provided by caller
Websocket.process = {
    -- spawn(command_args, callbacks) -> job_id
    -- callbacks: { on_stdout, on_stderr, on_exit }
    spawn = nil,
    
    -- send(job_id, message) -> boolean
    send = nil,
    
    -- kill(job_id) -> boolean  
    kill = nil,
    
    -- defer(callback, delay_ms)
    defer = nil
}

-- Logging interface - consumers can override
Websocket.log = {
    debug = function(tag, ...) end,
    notify = function(tag, level, show, message) end,
}

-- Status constants
Websocket.Status = {
    DISCONNECTED = "disconnected",
    CONNECTING = "connecting", 
    CONNECTED = "connected",
    RECONNECTING = "reconnecting",
    SHUTDOWN = "shutdown"
}

local current_status = Websocket.Status.DISCONNECTED

-- Status management
local function set_status(new_status)
    if current_status ~= new_status then
        current_status = new_status
        for _, callback in ipairs(status_callbacks) do
            callback(new_status)
        end
    end
end

-- Register a callback for status changes
function Websocket.on_status_change(callback)
    table.insert(status_callbacks, callback)
end

-- Get current connection status
function Websocket.get_status()
    return current_status
end

-- Check if websocket is connected
function Websocket.is_connected()
    return websocket_job and websocket_job > 0 and current_status == Websocket.Status.CONNECTED
end

-- Send a message to the websocket
function Websocket.send_message(message)
    if not Websocket.is_connected() then
        Websocket.log.debug("websocket", "Connection not established")
        return false
    end

    if not Websocket.process.send then
        Websocket.log.debug("websocket", "send_message not implemented - caller must provide Websocket.process.send")
        return false
    end

    return Websocket.process.send(websocket_job, message .. "\n")
end

-- Send a JSON message
function Websocket.send_json(data)
    local ok, json_str = pcall(json.encode, data)
    if not ok then
        Websocket.log.debug("websocket", "Failed to encode JSON: " .. tostring(json_str))
        return false
    end
    
    return Websocket.send_message(json_str)
end

-- Register a message handler for a specific message type
function Websocket.on_message(message_type, handler)
    if not message_handlers[message_type] then
        message_handlers[message_type] = {}
    end
    table.insert(message_handlers[message_type], handler)
end

-- Handle incoming message
local function handle_message(parsed_message)
    local msg_type = parsed_message.type
    if message_handlers[msg_type] then
        for _, handler in ipairs(message_handlers[msg_type]) do
            local ok, err = pcall(handler, parsed_message)
            if not ok then
                Websocket.log.debug("websocket", "Error in message handler for " .. msg_type .. ": " .. tostring(err))
            end
        end
    else
        Websocket.log.debug("websocket", "No handler for message type: " .. msg_type)
    end
end

-- Shutdown the websocket connection
function Websocket.shutdown()
    if websocket_job then
        Websocket.log.debug("websocket", "Shutting down websocket process")
        if Websocket.process.kill then
            Websocket.process.kill(websocket_job)
        end
        websocket_job = nil
        set_status(Websocket.Status.SHUTDOWN)
    end
end

-- Setup websocket connection
function Websocket.connect(server_uri, options)
    options = options or {}
    
    if not Websocket.process.spawn then
        Websocket.log.notify("websocket", "ERROR", true, "Process spawner not configured - caller must provide Websocket.process.spawn")
        return false
    end
    
    Websocket.log.debug("websocket", "Setting up websocket connection")
    set_status(Websocket.Status.CONNECTING)

    -- Kill existing connection if there is one
    if websocket_job then
        if Websocket.process.kill then
            Websocket.process.kill(websocket_job)
        end
        websocket_job = nil
    end

    -- Get the current file directory for binary resolution
    local current_file = debug.getinfo(1, "S").source:sub(2)
    local current_dir = current_file:match("(.+)/[^/]*$") or "."
    
    local binary_path = current_dir .. "/.." .. pick_binary()

    -- Use the server URI as provided by the caller
    local ws_uri = server_uri

    -- Spawn the websocket process using caller-provided function
    websocket_job = Websocket.process.spawn(
        { binary_path, ws_uri },
        {
            on_stdout = function(data)
                if not data then
                    return
                end

                for _, line in ipairs(data) do
                    if line ~= "" then
                        Websocket.log.debug("websocket", "Got message line: " .. line)

                        local ok, parsed = pcall(json.decode, line)
                        if not ok or type(parsed) ~= "table" then
                            Websocket.log.debug("websocket", "Failed to parse JSON line: " .. line)
                        else
                            handle_message(parsed)
                        end
                    end
                end
            end,
            
            on_stderr = function(data)
                if data and #data > 0 then
                    local message = table.concat(data, "\n")
                    if message ~= "" then
                        Websocket.log.debug("websocket", "Connection error: " .. message)
                    end
                end
            end,
            
            on_exit = function(exit_code)
                Websocket.log.debug("websocket", "Websocket connection closed with exit code: " .. exit_code)
                websocket_job = nil

                -- Don't reconnect if we're shutting down
                if current_status == Websocket.Status.SHUTDOWN then
                    return
                end

                -- Attempt to reconnect if not shutting down intentionally
                if reconnect_attempts < max_reconnect_attempts then
                    reconnect_attempts = reconnect_attempts + 1
                    set_status(Websocket.Status.RECONNECTING)

                    if Websocket.process.defer then
                        Websocket.process.defer(function()
                            Websocket.log.debug("websocket", "Reconnecting to websocket...")
                            Websocket.connect(server_uri, options)
                        end, reconnect_delay)
                    else
                        Websocket.log.debug("websocket", "No defer function provided - cannot reconnect automatically")
                        set_status(Websocket.Status.DISCONNECTED)
                    end
                else
                    Websocket.log.notify(
                        "websocket",
                        "WARN",
                        true,
                        "Failed to reconnect after " .. max_reconnect_attempts .. " attempts"
                    )
                    reconnect_attempts = 0
                    set_status(Websocket.Status.DISCONNECTED)
                end
            end
        }
    )

    if not websocket_job or websocket_job <= 0 then
        Websocket.log.notify("websocket", "ERROR", true, "Failed to start process")
        set_status(Websocket.Status.DISCONNECTED)
        return false
    end

    Websocket.log.debug("websocket", "Started process with job ID: " .. websocket_job)
    set_status(Websocket.Status.CONNECTED)
    reconnect_attempts = 0

    return true
end

-- Configure logging
function Websocket.set_logger(logger)
    Websocket.log = logger
end

-- Configure process management functions
function Websocket.set_process_manager(process_manager)
    Websocket.process = process_manager
end

return Websocket