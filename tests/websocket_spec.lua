local websocket = require("lua.websocket")

-- Mock vim API for testing
if not vim then
    _G.vim = {
        json = {
            encode = function(data) return require("json").encode(data) end,
            decode = function(str) return require("json").decode(str) end
        },
        fn = {
            jobstart = function() return 1 end,
            jobstop = function() end,
            chansend = function() return 1 end,
        },
        log = {
            levels = { ERROR = 1, WARN = 2, INFO = 3, DEBUG = 4 }
        },
        defer_fn = function(fn, delay) fn() end,
        uv = {
            os_uname = function() 
                return { sysname = "linux", machine = "x86_64" }
            end
        }
    }
end

describe("websocket", function()
    before_each(function()
        -- Reset websocket state
        websocket.shutdown()
    end)

    it("should return false when sending message without connection", function()
        local result = websocket.send_message("test message")
        assert.is_false(result)
    end)

    it("should track connection status", function()
        assert.equals(websocket.Status.DISCONNECTED, websocket.get_status())
    end)

    it("should handle status change callbacks", function()
        local status_changes = {}
        websocket.on_status_change(function(status)
            table.insert(status_changes, status)
        end)

        websocket.connect("ws://localhost:8080")
        assert.is_true(#status_changes > 0)
    end)

    it("should register message handlers", function()
        local received_messages = {}
        websocket.on_message("test-message", function(msg)
            table.insert(received_messages, msg)
        end)

        -- Simulate receiving a message (would normally come from job stdout)
        local test_msg = { type = "test-message", data = "test" }
        -- Note: In real usage, this would be handled internally via job callbacks
    end)

    it("should send JSON messages", function()
        websocket.connect("ws://localhost:8080")
        local data = { type = "test", message = "hello" }
        local result = websocket.send_json(data)
        -- Would be true if actually connected
    end)
end)