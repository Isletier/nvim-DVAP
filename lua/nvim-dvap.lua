local M = {
    state = {
        threads = {},
        breakpoints = {}
    },

    previous_fram_cache = "",
    client = nil,

    config = {
        on_connected = function() end,
        on_disconnected = function() end,
        on_state_updated = function(state) end
    }
}

-- Function to set up the plugin
function M.setup(config)
    M.config = config
end

local function parse_frame(data)
    if #data < 2 then return nil, data end
    local b1 = string.byte(data, 1)
    local b2 = string.byte(data, 2)

    local bit = require("bit")

    local opcode = bit.band(b1, 0x0F)
    local payload_len = bit.band(b2, 0x7F)
    local header_size = 2

    if payload_len == 126 then
        if #data < 4 then return nil, data end
        payload_len = bit.lshift(string.byte(data, 3), 8) + string.byte(data, 4)
        header_size = 4
    elseif payload_len == 127 then
        if #data < 10 then return nil, data end
        -- Берем только младшие 4 байта для простоты (до 4ГБ)
        payload_len = bit.lshift(string.byte(data, 7), 24) + bit.lshift(string.byte(data, 8), 16) +
                      bit.lshift(string.byte(data, 9), 8) + string.byte(data, 10)
        header_size = 10
    end

    if #data < header_size + payload_len then return nil, data end

    local payload = string.sub(data, header_size + 1, header_size + payload_len)
    local remaining = string.sub(data, header_size + payload_len + 1)

    return { opcode = opcode, payload = payload }, remaining
end


local function split_string_full(inputstr, sep)
    sep = sep or "%s"
    local t = {}
    local i = 1

    for str in string.gmatch(inputstr, "([^"..sep.."]*)("..sep.."?)") do
        t[i] = str
        i = i + 1
    end

    return t
end


function M.update_state(frame)
    if M.previous_fram_cache == frame then
        return
    end

    M.state.threads = {}
    M.state.breakpoints = {}

    local lines = split_string_full(frame)
    for _, line in ipairs(lines) do
        local occurancies = split_string_full(line, ':')
        if occurancies[1] == "thread" then
            M.state.threads[occurancies[2]] = {
                file_path = occurancies[3],
                line = occurancies[4],
                tid = occurancies[5]
            }
        elseif occurancies[1] == "bp" then
            M.state.breakpoints[occurancies[2]] = {
                file_path = occurancies[3],
                line = occurancies[4],
                type_str = occurancies[5],
                nonconditional = occurancies[6],
                enabled = occurancies[7]
            }
        else
        end
    end

    M.previous_fram_cache = frame

    vim.schedule_wrap(M.config.on_state_updated)(M.state)
end

function M.disconnect()
    if not M.client then
        return
    end

    local close_frame = string.char(0x88, 0x00)
    M.client:write(close_frame, function(err)
        if not M.client:is_closing() then
            M.client:read_stop()
            M.client:close()
        end

        M.client = nil
        --print("WebSocket connection closed gracefully")
    end)

    vim.schedule_wrap(M.config.on_disconnected)()
end

function M.connect(PATH, HOST, PORT)
    if not HOST and PORT then
        return
    end

    M.disconnect()

    M.client = vim.uv.new_tcp()

    if M.client == nil then
        --print("Conenction failed")
        return
    end

    local buffer = ""
    local handshaked = false

    M.client:connect(HOST, PORT, function(err)
        if err then return print("Connection error: " .. err) end

        -- Handshake
        local key = "dGhlIHNhbXBsZSBub25jZQ=="
        local req = string.format(
            "GET %s HTTP/1.1\r\nHost: %s\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n",
            PATH, HOST, key
        )
        M.client:write(req)

        M.client:read_start(function(err, chunk)
            if err or not chunk then
                print("Connection closed")
                M.client:close()
                M.client = nil
                vim.schedule_wrap(M.config.on_disconnected)()
                return
            end

            buffer = buffer .. chunk

            if not handshaked then
                local _, e = buffer:find("\r\n\r\n")
                if e then
                    if buffer:find("101 Switching Protocols") then
                        handshaked = true
                        vim.schedule_wrap(M.config.on_connected)()
                        print("WebSocket Connected to " .. HOST .. ":" .. PORT)
                        buffer = buffer:sub(e + 1)
                    else
                        print("Handshake failed")
                        vim.schedule_wrap(M.config.on_disconnected)()
                        M.client:close()
                        M.client = nil
                    end
                end
            end

            if handshaked then
                while #buffer > 0 do
                    local frame, remaining = parse_frame(buffer)
                    if frame then
                        buffer = remaining
                        if frame.opcode == 1 then -- Text frame
                            M.update_state(frame.payload)
                        elseif frame.opcode == 8 then -- Close frame
                            vim.schedule_wrap(M.config.on_disconnected)()
                            M.client:close()
                            M.client = nil
                        end
                    else
                        break
                    end
                end
            end
        end)
    end)
end

function M.get_state()
    return M.state
end

_G.ws_instance = M

return _G.ws_instance
