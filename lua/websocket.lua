local Websocket = {}

-- Reconnection settings
local reconnect_attempts = 0
local max_reconnect_attempts = 300
local reconnect_delay = 1000

-- Internal state
local websocket_job = nil
local message_handlers = {}
local status_callbacks = {}

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

-- Platform detection for binary selection
local function pick_binary()
    local uv = vim.uv or vim.loop
    local uname = uv.os_uname()
    local sysname = uname.sysname:lower()
    local arch = uname.machine

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

    if binaries[sysname] then
        if type(binaries[sysname]) == "table" then
            return binaries[sysname][arch] or binaries[sysname].default
        end
        return binaries[sysname]
    end

    if vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
        return binaries.windows.default or binaries.windows
    end

    return ""
end

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

    local ok, result = pcall(function()
        return vim.fn.chansend(websocket_job, message .. "\n")
    end)

    if not ok then
        Websocket.log.debug("websocket", "Error sending message: " .. tostring(result))
        return false
    end

    if result == 0 then
        Websocket.log.debug("websocket", "Failed to send message to websocket")
        return false
    end

    return true
end

-- Send a JSON message
function Websocket.send_json(data)
    local ok, json_str = pcall(vim.json.encode, data)
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
        vim.fn.jobstop(websocket_job)
        websocket_job = nil
        set_status(Websocket.Status.SHUTDOWN)
    end
end

-- Setup websocket connection
function Websocket.connect(server_uri, options)
    options = options or {}
    
    Websocket.log.debug("websocket", "Setting up websocket connection")
    set_status(Websocket.Status.CONNECTING)

    -- Kill existing connection if there is one
    if websocket_job then
        vim.fn.jobstop(websocket_job)
        websocket_job = nil
    end

    -- Get the plugin's root directory
    local plugin_root = options.plugin_root
    if not plugin_root then
        local current_file = debug.getinfo(1, "S").source:sub(2)
        plugin_root = vim.fn.fnamemodify(current_file, ":h:h")
    end
    
    local binary_path = plugin_root .. pick_binary()

    -- Build the websocket URI with query parameters
    local ws_uri = server_uri
    if options.user_id then
        ws_uri = ws_uri .. "?user_id=" .. options.user_id .. "&editor=neovim"
        if options.api_key and options.api_key ~= "" then
            ws_uri = ws_uri .. "&api_key=" .. options.api_key
        end
    end

    websocket_job = vim.fn.jobstart({
        binary_path,
        ws_uri,
    }, {
        on_stdout = function(_, data, _)
            if not data then
                return
            end

            for _, line in ipairs(data) do
                if line ~= "" then
                    Websocket.log.debug("websocket", "Got message line: " .. line)

                    local ok, parsed = pcall(vim.json.decode, line)
                    if not ok or type(parsed) ~= "table" then
                        Websocket.log.debug("websocket", "Failed to parse JSON line: " .. line)
                        goto continue
                    end

                    handle_message(parsed)
                end
                ::continue::
            end
        end,
        on_stderr = function(_, data, _)
            if data and #data > 0 then
                local message = table.concat(data, "\n")
                if message ~= "" then
                    Websocket.log.debug("websocket", "Connection error: " .. message)
                end
            end
        end,
        on_exit = function(_, exit_code, _)
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

                vim.defer_fn(function()
                    Websocket.log.debug("websocket", "Reconnecting to websocket...")
                    Websocket.connect(server_uri, options)
                end, reconnect_delay)
            else
                Websocket.log.notify(
                    "websocket",
                    vim.log.levels.WARN,
                    true,
                    "Failed to reconnect after " .. max_reconnect_attempts .. " attempts"
                )
                reconnect_attempts = 0
                set_status(Websocket.Status.DISCONNECTED)
            end
        end,
        stdout_buffered = false,
        stderr_buffered = false,
    })

    if websocket_job <= 0 then
        Websocket.log.notify("websocket", vim.log.levels.ERROR, true, "Failed to start process")
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

return Websocket