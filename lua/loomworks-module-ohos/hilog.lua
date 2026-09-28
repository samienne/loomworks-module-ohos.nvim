--- loomworks-module-ohos/hilog.lua — everything this plugin knows about
--- hilog, the HarmonyOS/OpenHarmony device log.
---
--- Core knows no device log format (core §18.13): the line grammar, level
--- order, session prefilter, soft filter, option vocabulary and defaults
--- live here. Used by the ohos device runner's log session (native
--- executables, spec/sdks/ohos.md §8.5) and, once core grows the generic
--- device-log seam, by the harmony module's device-log view
--- (spec/modules/harmony.md §6.5). Ported from core's
--- `lua/loomworks/device_log.lua`, which keeps its own copy until then —
--- keep the two in step.
---
--- Pure functions only; nothing spawns a process.

local M = {}

-- ---------------------------------------------------------------------------
-- Sanitize + parse
-- ---------------------------------------------------------------------------

--- Strip escape sequences, BOM and stray control bytes from a line. The
--- connector can prepend colour sequences, send BEL, or mix CRLF;
--- unsanitized, those break the parse or leak odd glyphs into output.
--- @param line string
--- @return string
function M.sanitize(line)
    if type(line) ~= "string" then return "" end
    if line:sub(1, 3) == "\xEF\xBB\xBF" then line = line:sub(4) end
    -- ANSI CSI: ESC '[' [params] final-byte
    line = line:gsub("\27%[[%d;?]*[@-~]", "")
    -- OSC: ESC ']' ... (BEL or ESC terminated)
    line = line:gsub("\27%][^\7\27]*[\7\27]", "")
    -- Other single-char escapes (ESC(A, ESC=, ESC\ ...)
    line = line:gsub("\27[^%[%]]", "")
    -- Headless CSI remnants (`[41;155H` whose ESC was eaten upstream).
    -- Two+ digits required so `[a92ab178]` / `[0xABCD]` survive.
    line = line:gsub("%[%??%d%d+[%d; ]*[A-Za-z]", "")
    -- C0 controls except TAB, LF, CR; and DEL.
    line = line:gsub("[%z\1-\8\11-\12\14-\31\127]", "")
    line = line:gsub("\r+$", "")
    return line
end

--- Parse one hilog line into a record.
---
---   MM-DD HH:MM:SS.mmm PID TID LEVEL DOMAIN/PROC/TAG: msg
---   MM-DD HH:MM:SS.mmm PID TID LEVEL DOMAIN/TAG: msg        (proc = nil)
---
--- Returns `nil, cleaned` for a line in neither form; callers keep the
--- cleaned text as a raw record (it reveals connector problems).
--- @param line string
--- @return table|nil record { time, pid, tid, level, domain, proc?, tag, msg }
--- @return string|nil cleaned
function M.parse_line(line)
    if type(line) ~= "string" or line == "" then return nil, "" end
    line = M.sanitize(line)
    if line == "" then return nil, "" end

    local time, pid, tid, level, rest = line:match(
        "^(%d%d%-%d%d %d%d:%d%d:%d%d%.%d+)%s+(%d+)%s+(%d+)%s+([A-Z])%s+(.*)$")
    if not time then return nil, line end

    local domain, proc, tag, msg = rest:match("^([^/%s]+)/([^/]+)/([^:]+):%s?(.*)$")
    if not domain then
        domain, tag, msg = rest:match("^([^/%s]+)/([^:]+):%s?(.*)$")
        proc = nil
    end
    if not domain then return nil, line end

    return {
        time = time,
        pid = tonumber(pid),
        tid = tonumber(tid),
        level = level,
        domain = domain,
        proc = proc,
        tag = tag,
        msg = msg or "",
    }
end

-- ---------------------------------------------------------------------------
-- Levels
-- ---------------------------------------------------------------------------

--- Accepted minimum levels.
M.LEVELS = { D = true, I = true, W = true, E = true, F = true }

--- Level order; `V` ranks lowest.
M.LEVEL_RANK = { V = 0, D = 1, I = 2, W = 3, E = 4, F = 5 }

-- ---------------------------------------------------------------------------
-- Session prefilter
-- ---------------------------------------------------------------------------

--- Does hilog's proc column refer to `name` (bundle or program name)?
--- Exact match; `name.` / `name:` sub-process prefixes; or hilog's
--- left-truncated proc column for long names (`proc` is a suffix).
--- @param proc string|nil
--- @param name string|nil
--- @return boolean
function M.proc_matches(proc, name)
    if not proc or not name or name == "" or proc == "" then return false end
    if proc == name then return true end
    local prefix = proc:sub(1, #name + 1)
    if prefix == name .. "." or prefix == name .. ":" then return true end
    if #name > #proc and name:sub(-#proc) == proc then return true end
    return false
end

--- Build the session prefilter (applied on receive; drops are final).
---   strict      — pid matches AND proc matches (degrades to whichever
---                 of the two is known)
---   app-related — pid matches OR proc matches
---   all         — everything
--- Raw (unparseable) and header records always pass.
--- @param opts { mode?: "strict"|"app-related"|"all", pid?: integer, name?: string, bundle?: string }
--- @return fun(record: table): boolean
function M.make_prefilter(opts)
    opts = opts or {}
    local mode = opts.mode or "strict"
    local pid = opts.pid
    local name = opts.name or opts.bundle

    if mode == "all" then return function() return true end end

    if mode == "app-related" then
        return function(record)
            if not record then return false end
            if record.header or record.raw then return true end
            if pid and record.pid == pid then return true end
            return name ~= nil and M.proc_matches(record.proc, name)
        end
    end

    return function(record)
        if not record then return false end
        if record.header or record.raw then return true end
        local pid_ok = pid ~= nil and record.pid == pid
        local name_ok = name ~= nil and M.proc_matches(record.proc, name)
        if pid and name then return pid_ok and name_ok end
        if pid then return pid_ok end
        if name then return name_ok end
        return false
    end
end

-- ---------------------------------------------------------------------------
-- Rendering + soft filter
-- ---------------------------------------------------------------------------

--- Verbose layout — the device line 1:1.
local function render_verbose(record)
    local pid = record.pid or 0
    local locator
    if record.proc and record.proc ~= "" then
        locator = string.format("%s/%s/%s", record.domain or "?", record.proc, record.tag or "?")
    else
        locator = string.format("%s/%s", record.domain or "?", record.tag or "?")
    end
    return string.format("%s %5d %5d %s %s: %s",
        record.time or "??-?? ??:??:??.???", pid, record.tid or pid,
        record.level or "?", locator, record.msg or "")
end

--- Compact layout — `HH:MM:SS.mmm PID LEVEL [PROC/]TAG: msg`.
local function render_compact(record)
    local t = record.time or ""
    local sp = t:find(" ")
    local time = sp and t:sub(sp + 1) or t
    local locator
    if record.proc and record.proc ~= "" then
        locator = string.format("%s/%s", record.proc, record.tag or "?")
    else
        locator = record.tag or "?"
    end
    return string.format("%s %d %s %s: %s",
        time, record.pid or 0, record.level or "?", locator, record.msg or "")
end

--- Render a record: header text, `[UNPARSED] <raw>`, or a layout.
--- @param record table
--- @param layout? "compact"|"verbose"
--- @return string
function M.render(record, layout)
    if not record then return "" end
    if record.header then return record.header end
    if record.raw then return "[UNPARSED] " .. record.raw end
    if layout == "verbose" then return render_verbose(record) end
    return render_compact(record)
end

--- Soft filter (applied on display). AND over every set field:
--- `pid`, `proc` (contains), `tag` (contains), `level` (minimum), `grep`
--- (Lua pattern the rendered line must match; `regex` is an alias kept
--- for core's view), `exclude` (Lua pattern the rendered line must NOT
--- match). Header records always pass; raw records are hidden only by a
--- pattern.
--- @param filter table
--- @param record table
--- @param rendered? string rendered line (pattern target); defaults to msg / raw
--- @return boolean
function M.match_filter(filter, record, rendered)
    if not record then return false end
    filter = filter or {}
    if record.header then return true end
    local grep = filter.grep or filter.regex
    local text = rendered or record.raw or record.msg or ""
    if grep and not text:match(grep) then return false end
    if filter.exclude and text:match(filter.exclude) then return false end
    if record.raw then return true end

    if filter.pid and record.pid ~= filter.pid then return false end
    if filter.proc and not (record.proc and record.proc:find(filter.proc, 1, true)) then
        return false
    end
    if filter.tag and not (record.tag and record.tag:find(filter.tag, 1, true)) then
        return false
    end
    if filter.level then
        local r = M.LEVEL_RANK[record.level] or 0
        local m = M.LEVEL_RANK[filter.level] or 0
        if r < m then return false end
    end
    return true
end

-- ---------------------------------------------------------------------------
-- Option vocabulary (core §18.13 log options; `device_log` / `--log`)
-- ---------------------------------------------------------------------------

--- Accepted option keys, in documentation order.
M.OPTION_KEYS = { "show", "prefilter", "level", "tag", "proc", "grep", "exclude", "tail" }

local SHOW = { stdout = true, hilog = true, both = true }
local PREFILTER = { strict = true, ["app-related"] = true, all = true }

--- Defaults by target type. `level = nil` means "derived from show".
M.DEFAULTS = {
    -- .hap app (harmony module, core §11): the view opens live.
    hap = { show = "hilog", prefilter = "strict", level = "I", tail = 30 },
    -- native executable (ohos runner, core §18): program output live,
    -- hilog captured and printed (last `tail` lines) only on failure.
    native = { show = "stdout", prefilter = "app-related", level = nil, tail = 30 },
}

local function known_keys()
    return table.concat(M.OPTION_KEYS, ", ")
end

local function bad(key, value, why)
    return string.format("device_log: invalid value %s for option '%s' (%s)",
        vim.inspect(value), key, why)
end

--- Validate and complete a log-option map for a target type.
---
--- Values may come from JSON (typed) or from `--log key=value` (strings);
--- both are accepted. Unknown keys and bad values are rejected with an
--- error naming them. Option values are data only: they never become a
--- program, a path, or device command text (the runner never interpolates
--- them into a device command).
---
--- Returns the resolved options plus `show_policy`, the core §18.13 show
--- table `{ program = live|off, log = live|on_failure|off, tail }`.
--- @param options table|nil
--- @param target_type "native"|"hap"
--- @return table|nil resolved, string|nil err
function M.resolve_options(options, target_type)
    local defaults = M.DEFAULTS[target_type]
    if not defaults then
        return nil, "device_log: unknown target type " .. vim.inspect(target_type)
    end
    options = options or {}
    if type(options) ~= "table" then
        return nil, "device_log: options must be a table"
    end

    local known = {}
    for _, k in ipairs(M.OPTION_KEYS) do known[k] = true end
    local keys = vim.tbl_keys(options)
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
        if not known[k] then
            return nil, string.format("device_log: unknown option '%s' (known: %s)",
                tostring(k), known_keys())
        end
    end

    local o = {}

    local show = options.show
    if show ~= nil then
        if type(show) ~= "string" or not SHOW[show] then
            return nil, bad("show", show, "one of stdout, hilog, both")
        end
        if target_type == "hap" and show ~= "hilog" then
            return nil, bad("show", show, "an app package has no program output; only hilog applies")
        end
    end
    o.show = show or defaults.show

    local pf = options.prefilter
    if pf ~= nil and (type(pf) ~= "string" or not PREFILTER[pf]) then
        return nil, bad("prefilter", pf, "one of strict, app-related, all")
    end
    o.prefilter = pf or defaults.prefilter

    local level = options.level
    if level ~= nil then
        if type(level) ~= "string" or not M.LEVELS[level:upper()] then
            return nil, bad("level", level, "one of D, I, W, E, F")
        end
        level = level:upper()
    end

    for _, key in ipairs({ "tag", "proc" }) do
        local v = options[key]
        if v ~= nil then
            if type(v) == "number" then v = tostring(v) end
            if type(v) ~= "string" then return nil, bad(key, v, "text") end
            o[key] = v ~= "" and v or nil
        end
    end

    for _, key in ipairs({ "grep", "exclude" }) do
        local v = options[key]
        if v ~= nil then
            if type(v) ~= "string" then return nil, bad(key, v, "a Lua pattern") end
            if v ~= "" then
                local ok, err = pcall(string.find, "", v)
                if not ok then
                    return nil, bad(key, v, "not a valid Lua pattern: "
                        .. tostring(err):gsub("^.-:%d+: ", ""))
                end
                o[key] = v
            end
        end
    end

    local tail = options.tail
    if tail ~= nil then
        local n = tonumber(tail)
        if type(tail) ~= "number" and not (type(tail) == "string" and tail:match("^%d+$")) then
            n = nil
        end
        if not n or n < 0 or n ~= math.floor(n) then
            return nil, bad("tail", tail, "a non-negative integer")
        end
        tail = n
    end
    o.tail = tail or defaults.tail

    -- Show policy (core §18.13).
    if target_type == "hap" or o.show == "hilog" then
        o.show_policy = { program = "off", log = "live", tail = o.tail }
    elseif o.show == "both" then
        o.show_policy = { program = "live", log = "live", tail = o.tail }
    else
        o.show_policy = { program = "live", log = "on_failure", tail = o.tail }
    end

    -- Level: explicit wins; else the type default; else W while hilog is
    -- only shown on failure, I when it is shown live.
    o.level = level or defaults.level
        or (o.show_policy.log == "on_failure" and "W" or "I")

    return o
end

--- Soft-filter table for resolved options.
--- @param o table resolved options
--- @return table filter for `M.match_filter`
function M.filter_from_options(o)
    return { level = o.level, tag = o.tag, proc = o.proc, grep = o.grep, exclude = o.exclude }
end

return M
