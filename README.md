# lua-go-ws

A clean WebSocket client library for Lua/Neovim that wraps a Go binary proxy for WebSocket connections.

## Features

- Simple WebSocket connection management
- Automatic reconnection with configurable retry logic
- Message type-based event handlers
- JSON message encoding/decoding
- Connection status tracking with callbacks
- Cross-platform binary support (Linux, macOS, Windows; x86_64 and ARM64)

## Usage

```lua
local websocket = require("lua.websocket")

-- Optional: Set up logging
websocket.set_logger({
    debug = function(tag, ...) print("DEBUG", tag, ...) end,
    notify = function(tag, level, show, message) print("NOTIFY", tag, message) end,
})

-- Connect to WebSocket server
local success = websocket.connect("wss://api.example.com/ws", {
    user_id = "your-user-id",
    api_key = "your-api-key",
    plugin_root = "/path/to/plugin" -- optional, auto-detected if not provided
})

if success then
    print("Connected to WebSocket")
end

-- Register message handlers
websocket.on_message("chat-message", function(message)
    print("Received chat:", message.text)
end)

websocket.on_message("notification", function(message)
    print("Notification:", message.title, message.body)
end)

-- Monitor connection status
websocket.on_status_change(function(status)
    print("Connection status:", status)
    -- status can be: "disconnected", "connecting", "connected", "reconnecting", "shutdown"
end)

-- Send messages
websocket.send_message("Hello, server!")

-- Send JSON messages
websocket.send_json({
    type = "user-action",
    action = "click",
    target = "button-1"
})

-- Check connection status
if websocket.is_connected() then
    print("Currently connected")
end

print("Status:", websocket.get_status())

-- Clean shutdown
websocket.shutdown()
```

## API Reference

### Connection Management

#### `websocket.connect(server_uri, options)`
Establish a WebSocket connection.

**Parameters:**
- `server_uri` (string): The WebSocket server URI (ws:// or wss://)
- `options` (table, optional): Configuration options
  - `user_id` (string): User identifier for authentication
  - `api_key` (string): API key for authentication
  - `plugin_root` (string): Path to plugin directory containing binaries (auto-detected if omitted)

**Returns:** `boolean` - Success status

#### `websocket.shutdown()`
Close the WebSocket connection and stop reconnection attempts.

#### `websocket.is_connected()`
**Returns:** `boolean` - True if currently connected

#### `websocket.get_status()`
**Returns:** `string` - Current connection status

**Status Values:**
- `websocket.Status.DISCONNECTED` - Not connected
- `websocket.Status.CONNECTING` - Establishing connection
- `websocket.Status.CONNECTED` - Successfully connected
- `websocket.Status.RECONNECTING` - Attempting to reconnect
- `websocket.Status.SHUTDOWN` - Intentionally shut down

### Message Handling

#### `websocket.send_message(message)`
Send a raw string message.

**Parameters:**
- `message` (string): The message to send

**Returns:** `boolean` - Success status

#### `websocket.send_json(data)`
Send a JSON-encoded message.

**Parameters:**
- `data` (table): The data to encode and send

**Returns:** `boolean` - Success status

#### `websocket.on_message(message_type, handler)`
Register a handler for messages of a specific type.

**Parameters:**
- `message_type` (string): The message type to handle
- `handler` (function): Callback function that receives the parsed message

### Status Monitoring

#### `websocket.on_status_change(callback)`
Register a callback for connection status changes.

**Parameters:**
- `callback` (function): Function called with the new status string

### Configuration

#### `websocket.set_logger(logger)`
Configure logging functions.

**Parameters:**
- `logger` (table): Logger implementation with `debug` and `notify` functions

## Binary Dependencies

The library requires platform-specific binaries in the `dist/` directory:
- `go-ws-proxy-linux-amd64`
- `go-ws-proxy-linux-arm64`
- `go-ws-proxy-darwin-amd64`
- `go-ws-proxy-darwin-arm64`
- `go-ws-proxy-windows-amd64`
- `go-ws-proxy-windows-arm64`

The appropriate binary is automatically selected based on the detected platform.

## Testing

Run tests with your preferred Lua testing framework:

```bash
# Using busted
busted tests/

# Or with Neovim's test runner
nvim --headless -c "PlenaryBustedDirectory tests/ {minimal_init = 'tests/minimal_init.lua'}"
```