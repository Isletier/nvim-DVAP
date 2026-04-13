local M = {
    state = {
        threads = {},
        breakpoints = {},
        selected = nil
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

function M.check()
    vim.health.start("nvim-dvap report")

    if vim.fn.executable("curl") == 1 then
        vim.health.ok("curl: found")
    else
        vim.health.error("curl: haven't been found")
    end
end

local function split_string_full(inputstr, sep)
    sep = sep or "%s"
    local t = {}
    local i = 1

    for str in string.gmatch(inputstr, "([^"..sep.."]*)("..sep.."?)") do
        t[i] = str
        i = i + 1
    end

    return i, t
end

local function validate_and_normalize_path(path_str)
    if type(path_str) ~= "string" then
        return nil
    end

    local abs_path = vim.fs.normalize(vim.fn.fnamemodify(path_str, ":p"))

    local is_readable = vim.uv.fs_access(abs_path, "r")
    local stat = vim.uv.fs_stat(abs_path)
    if is_readable and stat and stat.type == "file" then
        return abs_path
    end

    return nil
end

local function schedule_notify(msg, level, opts)
    vim.schedule_wrap(vim.notify_once)(msg, level, opts)
end

function M.parse_thread(occurancies, len)
    local thr_num_ok, thread_num = pcall(tonumber, occurancies[2])
    if not thr_num_ok then
        schedule_notify("[DVAP] Invalid thread num field, ignoring", vim.log.levels.WARN, {})
        return nil, nil
    end

    local file_path = validate_and_normalize_path(occurancies[3])
    local line_ok, line_nr = pcall(tonumber, occurancies[4])
    local tid_ok, tid = pcall(tonumber, occurancies[5])

    if not file_path or not line_ok or not tid_ok then
        local prev_thread = M.state.threads[thread_num]
        if not prev_thread then
            schedule_notify("[DVAP] Invalid thread data or file_path haven't been found, ignored", vim.log.levels.WARN, {})
            return nil, nil
        end

        schedule_notify("[DVAP] Invalid thread data or file_path haven't been found, fallback to previous info", vim.log.levels.WARN, {})
        return thread_num, M.state.threads[thread_num]
    end

    return thread_num, {
        file_path = file_path,
        line = line_nr,
        tid = tid
    }
end

function M.parse_breakpoint(occurancies, len)
    local br_num_ok, br_num = pcall(tonumber, occurancies[2])
    if not br_num_ok then
        schedule_notify("[DVAP] Invalid breakpoint num field, ignoring", vim.log.levels.WARN, {})
        return nil, nil
    end

    local file_path = validate_and_normalize_path(occurancies[3])
    local line_ok, line_nr = pcall(tonumber, occurancies[4])
    local nonconditional = occurancies[7] == "True"
    local enabled = occurancies[8] == "True"

    if not file_path or not line_ok then
        schedule_notify("[DVAP] Invalid breakpoint data, ignoring", vim.log.levels.WARN, {})
        return nil, nil
    end

    return br_num, {
        file_path = file_path,
        line = line_nr,
        nonconditional = nonconditional,
        enabled = enabled
    }
end

function M.update_state(frame)
    if M.previous_frame_cache == frame then
        return
    end
    M.previous_frame_cache = frame

    local state = M.parse_frame(frame)
    if state == nil then
        return
    end

    M.state = state
    vim.schedule_wrap(M.config.on_state_updated)(M.state)
end

function M.parse_frame(frame)
    local state = {}
    state.threads = {}
    state.breakpoints = {}

    local _, lines = split_string_full(frame, ' ')

    for _, line in ipairs(lines) do
        local num, occurancies = split_string_full(line, ':')

        if num < 2 then
            schedule_notify("[DVAP] Validation failed, dropping frame", vim.log.levels.ERROR, {})
            return nil
        end

        if occurancies[1] == "thread" then
            local thr_num, thr = M.parse_thread(occurancies, num)
            if thr_num ~= nil then
                state.threads[thr_num] = thr
            end

        elseif occurancies[1] == "bp" then
            local br_num, br = M.parse_breakpoint(occurancies, num)
            if br_num ~= nil then
                state.breakpoints[br_num] = br
            end

        elseif occurancies[1] == "selected" then
            local ok, selected = pcall(tonumber, occurancies[2])
            if not ok then
                schedule_notify("[DVAP] invalid selected data, dropping frame", vim.log.levels.ERROR, {})
                return
            end
            state.selected = selected
        end
    end

    if state.threads[state.selected] == nil then
        schedule_notify("[DVAP] Selected thread info not presented, dropping frame", vim.log.levels.ERROR, {})
        return nil
    end

    return state
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
