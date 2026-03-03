local M = {
    state = {
        threads = {},
        breakpoints = {}
    },

    previous_frame_cache = "",
    client = nil,

    stdout = nil,
    stdin = nil,
    chunk_buffer = "",

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
    if M.previous_frame_cache == frame then
        return
    end

    M.state.threads = {}
    M.state.breakpoints = {}

    local lines = split_string_full(frame, ' ')
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

    M.previous_frame_cache = frame

    vim.schedule_wrap(M.config.on_state_updated)(M.state)
end

function M.disconnect()
    if M.stdout then M.stdout:close() end
    if M.stderr then M.stderr:close() end
    if M.client then M.client:close() end
    if M.client then M.client:kill(15) end

    M.client = nil
    M.stdout = nil
    M.stderr = nil
    M.chunk_buffer = ""
    M.previous_frame_cache = ""

    vim.schedule_wrap(M.config.on_disconnected)()
end

function M.connect(url)
    M.disconnect()
    M.stdout = vim.uv.new_pipe(false)
    M.stderr = vim.uv.new_pipe(false)

    vim.schedule_wrap(M.config.on_connected)()
    M.client = vim.uv.spawn("curl", {
        args = {
            "-N",
            "-sS",
            "-H",
            "Accept: text/event-stream",
           url
        },
        stdio = { nil, M.stdout, M.stderr },
    }, function(_, _) M.disconnect() end
    )

    -- 1. Listen to stderr for connection/network errors
    vim.uv.read_start(M.stderr, function(err, data)
        if data then
            vim.schedule(function()
                print("curl error happend: " .. data)
            end)
        end
    end)

    vim.uv.read_start(M.stdout, function(err, chunk)
        if err or not chunk then
            M.disconnect()
            return
        end

        M.chunk_buffer = M.chunk_buffer .. chunk
        while true do
            local start_idx, end_idx = M.chunk_buffer:find("\n\n")
            if not start_idx then break end

            local full_event = M.chunk_buffer:sub(1, end_idx)
            M.chunk_buffer = M.chunk_buffer:sub(end_idx + 1)

            local data_content = full_event:match("data: (.*)\n\n")
            if not data_content then
                print("Unexpected event format, disconnecting")
                M.disconnect()
            end

            M.update_state(data_content)
        end
    end)
end

function M.get_state()
    return M.state
end

_G.ws_instance = M

return _G.ws_instance
