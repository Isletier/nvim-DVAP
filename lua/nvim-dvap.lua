---@class DvapThread
---@field file_path string  Absolute normalized path to the source file
---@field line     integer  1-based line number
---@field tid      integer  OS thread ID

---@class DvapBreakpoint
---@field file_path      string  Absolute normalized path to the source file
---@field line           integer 1-based line number
---@field nonconditional boolean True when the breakpoint has no condition, thread, or task filter
---@field enabled        boolean Whether the breakpoint is currently active

---@class DvapState
---@field threads     table<integer, DvapThread>      Map of debugger thread num -> thread info
---@field breakpoints table<integer, DvapBreakpoint>  Map of debugger bp num -> breakpoint info
---@field selected    integer?                        Debugger thread num of the currently selected thread

---@class DvapConfig
---@field on_connected     fun()                     Called when the SSE connection is established
---@field on_disconnected  fun()                     Called when the connection drops or is explicitly closed
---@field on_state_updated fun(state: DvapState)     Called on every successfully parsed state frame

---@class DvapModule
---@field state                DvapState
---@field previous_frame_cache string
---@field client               userdata?
---@field stdout               userdata?
---@field stderr               userdata?
---@field chunk_buffer         string
---@field config               DvapConfig


local FS = ";;"   -- field separator (within a record)
local RS = "||"   -- record separator (between records)

local M = {
    ---@type DvapState
    state = {
        threads = {},
        breakpoints = {},
        selected = nil
    },

    previous_frame_cache = "",
    client               = nil,
    stdout               = nil,
    stderr               = nil,
    chunk_buffer         = "",

    ---@type DvapConfig
    config = {
        on_connected     = function() end,
        on_disconnected  = function() end,
        on_state_updated = function(_) end,
    }
}


---@param config DvapConfig
function M.setup(config)
    M.config = vim.tbl_deep_extend("force", M.config, config)
end


function M.check()
    vim.health.start("nvim-dvap report")

    if vim.fn.executable("curl") == 1 then
        vim.health.ok("curl: found")
    else
        vim.health.error("curl: not found")
    end
end


---Returns the absolute normalized path if the file exists and is readable, nil otherwise.
---@param path_str any
---@return string?
local function validate_and_normalize_path(path_str)
    if type(path_str) ~= "string" then
        return nil
    end

    local abs_path = vim.fs.normalize(vim.fn.fnamemodify(path_str, ":p"))

    local is_readable = vim.uv.fs_access(abs_path, "r")
    local stat        = vim.uv.fs_stat(abs_path)
    if is_readable and stat and stat.type == "file" then
        return abs_path
    end

    return nil
end


---Schedules a one-time vim.notify call. Safe to call from uv callbacks.
---@param msg   string
---@param level integer
local function schedule_notify(msg, level)
    vim.schedule_wrap(vim.notify_once)(msg, level, {})
end


---Parses a single thread record from its already-split fields.
---@param  fields string[]
---@return integer?    thread_num
---@return DvapThread?
function M.parse_thread(fields)
    local thread_num = tonumber(fields[2])
    if not thread_num or #fields < 5 then
        schedule_notify("[DVAP] Invalid thread record, ignoring", vim.log.levels.WARN)
        return nil, nil
    end

    local file_path = validate_and_normalize_path(fields[3])
    local line_nr   = tonumber(fields[4])
    local tid       = tonumber(fields[5])

    if not file_path or not line_nr or not tid then
        -- Attempt to keep the last known position for this thread (e.g. it is running)
        local prev_thread = M.state.threads[thread_num]
        if not prev_thread then
            schedule_notify("[DVAP] Invalid thread data and no previous info, ignoring", vim.log.levels.WARN)
            return nil, nil
        end

        schedule_notify("[DVAP] Invalid thread data, falling back to previous info", vim.log.levels.WARN)
        return thread_num, prev_thread
    end

    ---@type DvapThread
    local result = { file_path = file_path, line = line_nr --[[@as integer]], tid = tid --[[@as integer]] }
    return thread_num, result
end


---Parses a single breakpoint record from its already-split fields.
---@param  fields string[]
---@return integer?        br_num
---@return DvapBreakpoint?
function M.parse_breakpoint(fields)
    local br_num = tonumber(fields[2])
    if not br_num or #fields < 6 then
        schedule_notify("[DVAP] Invalid breakpoint record, ignoring", vim.log.levels.WARN)
        return nil, nil
    end

    local file_path      = validate_and_normalize_path(fields[3])
    local line_nr        = tonumber(fields[4])
    local nonconditional = fields[5] == "True"
    local enabled        = fields[6] == "True"

    if not file_path or not line_nr then
        schedule_notify("[DVAP] Invalid breakpoint data, ignoring", vim.log.levels.WARN)
        return nil, nil
    end

    ---@type DvapBreakpoint
    local result = { file_path = file_path, line = line_nr --[[@as integer]], nonconditional = nonconditional, enabled = enabled }
    return br_num, result
end


---Parses a raw SSE data string into a DvapState. Returns nil on any structural error.
---@param  frame string
---@return DvapState?
function M.parse_frame(frame)
    ---@type DvapState
    local state = { threads = {}, breakpoints = {}, selected = nil }

    local records = vim.split(frame, RS, { plain = true })

    for _, record in ipairs(records) do
        if record == "" then goto continue end

        local fields = vim.split(record, FS, { plain = true })

        if #fields < 2 then
            schedule_notify("[DVAP] Malformed record, dropping frame", vim.log.levels.ERROR)
            return nil
        end

        if fields[1] == "thread" then
            local thr_num, thr = M.parse_thread(fields)
            if thr_num ~= nil then
                state.threads[thr_num] = thr
            end

        elseif fields[1] == "bp" then
            local br_num, br = M.parse_breakpoint(fields)
            if br_num ~= nil then
                state.breakpoints[br_num] = br
            end

        elseif fields[1] == "selected" then
            local selected = tonumber(fields[2])
            if not selected then
                schedule_notify("[DVAP] Invalid selected field, dropping frame", vim.log.levels.ERROR)
                return nil
            end
            state.selected = selected
        end

        ::continue::
    end

    local selected_valid = (state.selected == nil and #state.threads == 0) or (state.selected ~= nil and state.threads[state.selected] ~= nil)

    if not selected_valid then
        schedule_notify("[DVAP] Selected thread not present in frame, dropping", vim.log.levels.ERROR)
        return nil
    end

    return state
end


---Updates internal state from a raw SSE frame string. No-op on duplicate or invalid frames.
---@param frame string
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


---Closes the current curl connection and resets all transport state.
function M.disconnect()
    if not M.client then return end  -- guard against double-disconnect from exit+EOF callbacks

    -- Kill the process before closing pipes so the handle is still valid.
    M.client:kill(15)
    if M.stdout then M.stdout:close() end
    if M.stderr then M.stderr:close() end
    M.client:close()

    M.client               = nil
    M.stdout               = nil
    M.stderr               = nil
    M.chunk_buffer         = ""
    M.previous_frame_cache = ""

    vim.schedule_wrap(M.config.on_disconnected)()
end


---Connects to a DVAP SSE endpoint. Disconnects any existing connection first.
---@param url string  Full URL, e.g. "127.0.0.1:9000/events"
function M.connect(url)
    M.disconnect()

    M.stdout = vim.uv.new_pipe(false)
    M.stderr = vim.uv.new_pipe(false)

    ---@diagnostic disable-next-line: missing-fields
    M.client = vim.uv.spawn("curl", {
        args  = { "-N", "-sS", "-H", "Accept: text/event-stream", url },
        stdio = { nil, M.stdout, M.stderr },
    }, function(_, _) M.disconnect() end)

    if not M.client then
        schedule_notify("[DVAP] Failed to spawn curl — is it installed?", vim.log.levels.ERROR)
        M.stdout:close()
        M.stderr:close()
        M.stdout = nil
        M.stderr = nil
        return
    end

    vim.schedule_wrap(M.config.on_connected)()

    vim.uv.read_start(M.stderr, function(_, data)
        if data then
            vim.schedule(function()
                vim.notify("[DVAP] curl: " .. data, vim.log.levels.ERROR, {})
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
            local _, end_idx = M.chunk_buffer:find("\n\n")
            if not end_idx then break end

            local full_event = M.chunk_buffer:sub(1, end_idx)
            M.chunk_buffer   = M.chunk_buffer:sub(end_idx + 1)

            local data_content = full_event:match("data: (.*)\n\n")
            if not data_content then
                vim.schedule(function()
                    vim.notify("[DVAP] Unexpected SSE frame format, disconnecting", vim.log.levels.ERROR, {})
                end)
                M.disconnect()
                return
            end

            M.update_state(data_content)
        end
    end)
end


---Returns the last successfully parsed state.
---@return DvapState
function M.get_state()
    return M.state
end

_G.dvap_instance = M

return M
