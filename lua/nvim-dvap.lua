--- nvim-dvap
---
--- Transport + state layer for the DVAP debugger protocol. Connects to a
--- debugger's SSE endpoint via curl, parses frames into a typed state, and
--- exposes lifecycle callbacks (on_connected / on_disconnected / on_state_updated)
--- for a UI layer to subscribe to. Optional auto-reconnect with configurable
--- interval.
---
--- Public entry point: require('nvim-dvap').setup(config)

---@class DvapThread
---@field file_path string  Absolute normalized path to the source file
---@field line      integer 1-based line number
---@field tid       integer OS thread ID
---@field lost      boolean? True when the thread position is stale (fell back to previous info)

---@class DvapBreakpoint
---@field file_path      string  Absolute normalized path to the source file
---@field line           integer 1-based line number
---@field nonconditional boolean True when the breakpoint has no condition, thread, or task filter
---@field enabled        boolean Whether the breakpoint is currently active

---@class DvapState
---@field threads     table<string, DvapThread>       Map of debugger thread num -> thread info
---@field breakpoints table<integer, DvapBreakpoint>  Map of debugger bp num -> breakpoint info
---@field selected    string?                         Id of the currently selected thread

---@class DvapConfig  Resolved runtime config (all fields non-nil after setup).
---@field reconnect_interval integer               Reconnect interval in ms; 0 disables auto-reconnect
---@field on_connected       fun()                 Fired once per session, on first successfully received frame
---@field on_disconnected    fun()                 Fired when the connection drops or is explicitly closed
---@field on_state_updated   fun(state: DvapState) Fired for every successfully parsed state frame

---@class DvapConfigInit  User-supplied partial config passed to setup().
---@field reconnect_interval integer?
---@field on_connected       fun()
---@field on_disconnected    fun()
---@field on_state_updated   fun(state: DvapState)

---@class DvapModule
---@field state                DvapState
---@field previous_frame_cache string
---@field client               uv.uv_process_t?
---@field stdout               uv.uv_pipe_t?
---@field stderr               uv.uv_pipe_t?
---@field chunk_buffer         string
---@field started              boolean           True once the first frame of the current session has arrived
---@field reconnect_url        string?           URL to reconnect to on unexpected drops (nil when no session armed)
---@field reconnect_timer      uv.uv_timer_t?    Pending reconnect timer, if any
---@field config               DvapConfig
---@field setup                fun(config: DvapConfigInit)
---@field check                fun()
---@field get_state            fun(): DvapState
---@field connect_entry        fun(url: string, interval: integer?)
---@field disconnect_entry     fun()
---@field connect              fun(url: string)
---@field disconnect           fun()
---@field disconnect_retry     fun()
---@field spawn_reconnect_timer fun()
---@field parse_thread         fun(fields: string[]): string?, DvapThread?
---@field parse_breakpoint     fun(fields: string[]): integer?, DvapBreakpoint?
---@field parse_frame          fun(frame: string): DvapState?
---@field update_state         fun(frame: string)


local FS = ";;" -- field separator (within a record)
local RS = "||" -- record separator (between records)

---@class DvapModule
local M = {
    state = {
        threads     = {},
        breakpoints = {},
        selected    = nil,
    },

    previous_frame_cache = "",
    client               = nil,
    stdout               = nil,
    stderr               = nil,
    chunk_buffer         = "",
    started              = false,

    reconnect_url        = nil,
    reconnect_timer      = nil,

    config = {
        reconnect_interval = 0,
        on_connected       = function() end,
        on_disconnected    = function() end,
        on_state_updated   = function(_) end,
    },
}


---Schedules a one-time vim.notify call. Safe to call from uv callbacks.
---@param msg   string
---@param level integer
local function schedule_notify(msg, level)
    vim.schedule_wrap(vim.notify_once)(msg, level, {})
end


---@param config DvapConfigInit
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


---Returns the last successfully parsed state.
---@return DvapState
function M.get_state()
    return M.state
end


---Cancels any pending reconnect timer and releases its libuv handle.
local function cancel_reconnect_timer()
    if not M.reconnect_timer then return end

    if not M.reconnect_timer:is_closing() then
        M.reconnect_timer:stop()
        M.reconnect_timer:close()
    end
    M.reconnect_timer = nil
end


---Public entry: start observing a debug session.
---Updates reconnect_interval (0 disables auto-reconnect) and reconnects.
---@param url      string
---@param interval integer?
function M.connect_entry(url, interval)
    if interval then
        M.config.reconnect_interval = interval
    end

    M.disconnect()
    M.connect(url)
end


---Public entry: explicit disconnect. Cancels any pending reconnect and
---disables auto-reconnect until the next connect_entry().
function M.disconnect_entry()
    cancel_reconnect_timer()
    M.disconnect()
    M.config.reconnect_interval = 0
    M.reconnect_url             = nil
end


---Returns the absolute normalized path if the file exists and is readable, nil otherwise.
---@param  path_str any
---@return string?
local function validate_and_normalize_path(path_str)
    if type(path_str) ~= "string" then
        return nil
    end

    local abs_path    = vim.fs.normalize(vim.fn.fnamemodify(path_str, ":p"))
    local is_readable = vim.uv.fs_access(abs_path, "r")
    local stat        = vim.uv.fs_stat(abs_path)
    if is_readable and stat and stat.type == "file" then
        return abs_path
    end

    return nil
end


---Parses a single thread record from its already-split fields.
---@param  fields string[]
---@return string?
---@return DvapThread?
function M.parse_thread(fields)
    local thread_num = tonumber(fields[2])
    if not thread_num or #fields < 6 then
        schedule_notify("[DVAP] Invalid thread record, ignoring", vim.log.levels.WARN)
        return nil, nil
    end

    local type_str = fields[3]
    if type_str == "" then
        schedule_notify("[DVAP] Invalid thread record, ignoring", vim.log.levels.WARN)
        return nil, nil
    end

    local thr_id = thread_num .. '|' .. type_str

    local file_path = validate_and_normalize_path(fields[4])
    local line_nr   = tonumber(fields[5])
    local tid       = tonumber(fields[6])

    if not file_path or not line_nr or not tid then
        -- Keep the last known position for this thread (e.g. it is running).
        local prev_thread = M.state.threads[thr_id]
        if not prev_thread then
            schedule_notify("[DVAP] Invalid thread data and no previous info, ignoring", vim.log.levels.WARN)
            return nil, nil
        end

        schedule_notify("[DVAP] Invalid thread data, falling back to previous info", vim.log.levels.WARN)
        return thr_id, vim.tbl_extend("force", prev_thread, { lost = true })
    end

    ---@type DvapThread
    local result = {
        file_path = file_path,
        line      = line_nr --[[@as integer]],
        tid       = tid --[[@as integer]],
    }
    return thr_id, result
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
    local result = {
        file_path      = file_path,
        line           = line_nr --[[@as integer]],
        nonconditional = nonconditional,
        enabled        = enabled,
    }
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
        if #fields < 3 then
            schedule_notify("[DVAP] Malformed record, dropping frame", vim.log.levels.ERROR)
            return nil
        end

        if fields[1] == "thread" then
            local thr_id, thr = M.parse_thread(fields)
            if thr_id ~= nil then
                state.threads[thr_id] = thr
            end
        elseif fields[1] == "bp" then
            local br_num, br = M.parse_breakpoint(fields)
            if br_num ~= nil then
                state.breakpoints[br_num] = br
            end
        elseif fields[1] == "selected" then
            local id       = tonumber(fields[2])
            local type_str = fields[3]
            if not id or type_str == "" then
                schedule_notify("[DVAP] Invalid selected field, dropping frame", vim.log.levels.ERROR)
                return nil
            end

            state.selected = fields[2] .. "|" .. type_str
        end

        ::continue::
    end

    local selected_valid = (state.selected == nil and vim.tbl_isempty(state.threads))
        or (state.selected ~= nil and state.threads[state.selected] ~= nil)

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


---Closes the current curl process and releases transport state. Fires
---on_disconnected. Idempotent. Does NOT cancel a pending reconnect timer —
---see cancel_reconnect_timer / disconnect_entry.
function M.disconnect()
    if not M.client then return end  -- guard against double-disconnect from exit + EOF callbacks

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
    M.started              = false

    vim.schedule_wrap(M.config.on_disconnected)()
end


---Schedules a one-shot libuv timer that reconnects to `M.reconnect_url`
---after `config.reconnect_interval` ms. Closes any existing pending timer
---before arming a new one.
function M.spawn_reconnect_timer()
    cancel_reconnect_timer()

    local timer = vim.uv.new_timer()
    if timer == nil then
        schedule_notify("[DVAP] Failed to create reconnect timer", vim.log.levels.ERROR)
        return
    end

    M.reconnect_timer = timer
    timer:start(M.config.reconnect_interval, 0, vim.schedule_wrap(function()
        timer:close()
        M.reconnect_timer = nil
        if M.reconnect_url then
            M.connect(M.reconnect_url)
        end
    end))
end


---Drops the current transport and, if auto-reconnect is armed, schedules a
---reconnect attempt. Called from curl exit and SSE error paths.
function M.disconnect_retry()
    M.disconnect()

    if M.reconnect_url and M.config.reconnect_interval ~= 0 then
        M.spawn_reconnect_timer()
    end
end


---Connects to a DVAP SSE endpoint. The caller is expected to have disconnected
---any prior session (connect_entry does this); connect() itself does not.
---@param url string  Full URL, e.g. "127.0.0.1:9000/events"
function M.connect(url)
    local pipe_stdout, err_out, err_name_out = vim.uv.new_pipe(false)
    local pipe_stderr, err_err, err_name_err = vim.uv.new_pipe(false)

    if not pipe_stdout then
        schedule_notify(string.format("[DVAP] Failed to create pipe: %s (%s)", err_out, err_name_out), vim.log.levels.ERROR)
        return
    end
    if not pipe_stderr then
        schedule_notify(string.format("[DVAP] Failed to create pipe: %s (%s)", err_err, err_name_err), vim.log.levels.ERROR)
        pipe_stdout:close()
        return
    end

    M.stdout = pipe_stdout
    M.stderr = pipe_stderr

    ---@diagnostic disable-next-line: missing-fields
    M.client = vim.uv.spawn("curl", {
        args  = { "-N", "-sS", "-H", "Accept: text/event-stream", url },
        stdio = { nil, M.stdout, M.stderr },
    }, function(_, _) M.disconnect_retry() end)

    if not M.client then
        schedule_notify("[DVAP] Failed to spawn curl — is it installed?", vim.log.levels.ERROR)
        M.stdout:close()
        M.stderr:close()
        M.stdout = nil
        M.stderr = nil
        return
    end

    M.reconnect_url = url

    vim.uv.read_start(M.stderr, function(_, data)
        -- Suppress curl errors during retry loops: we'll be noisy otherwise on
        -- every failed attempt while the server is down. Surface errors only
        -- in non-retry mode.
        if data and M.config.reconnect_interval == 0 then
            schedule_notify("[DVAP] curl: " .. data, vim.log.levels.ERROR)
        end
    end)

    vim.uv.read_start(M.stdout, function(err, chunk)
        if not M.started then
            vim.schedule_wrap(M.config.on_connected)()
            schedule_notify("[DVAP] Connected to " .. url, vim.log.levels.INFO)
            M.started = true
        end

        if err then
            schedule_notify("[DVAP] Error reading network data: " .. tostring(err) .. ", disconnecting",
                vim.log.levels.WARN)
            M.disconnect_retry()
            return
        end

        if not chunk then
            return  -- EOF; the spawn exit callback will run disconnect_retry
        end

        M.chunk_buffer = M.chunk_buffer .. chunk

        while true do
            local _, end_idx = M.chunk_buffer:find("\n\n")
            if not end_idx then break end

            local full_event = M.chunk_buffer:sub(1, end_idx)
            M.chunk_buffer   = M.chunk_buffer:sub(end_idx + 1)

            local data_content = full_event:match("data: (.*)\n\n")
            if not data_content then
                schedule_notify("[DVAP] Unexpected SSE frame format, disconnecting", vim.log.levels.ERROR)
                M.disconnect_retry()
                return
            end

            M.update_state(data_content)
        end
    end)
end


return M
