--- loomworks-module-ohos/runner.lua — the ohos device runner (core §18.2).
---
--- Runs plain native executables built by the ohos SDK's cmake kits on an
--- attached HarmonyOS/OpenHarmony device through `hdc`. Like every device
--- runner it only BUILDS command specs and PARSES output: core spawns every
--- process, owns timeouts, cancellation, line normalization and locking.
---
--- Returned by the ohos SDK provider's `device_runner(sdk)` hook
--- (`lua/loomworks/sdks/ohos.lua`). The builders are plain functions
--- (closures over the hdc path), called as `runner.push(...)`, never with
--- `:`. See spec/sdks/ohos.md §8 for the contract as implemented here.

local hdc = require("loomworks-module-ohos.hdc")
local hilog = require("loomworks-module-ohos.hilog")

local M = {}

--- Device-side directory under which core stages files (core §18.4).
M.STAGING_BASE = "/data/local/tmp/.device-staging"

--- Where hiview publishes native crash reports (`cppcrash-*.log`).
M.FAULTLOG_DIR = "/data/log/faultlog/faultlogger"

--- Where faultloggerd writes its raw crash dump
--- (`cppcrash-<pid>-<timestamp>.json`, full stack) at the moment of the
--- crash. Observed on a device: hiview did NOT always publish a
--- faultlogger report for a crash (none >90 s after a SIGSEGV of a
--- program exec'd by a long absolute path) while this file was written.
M.FAULTLOG_TEMP_DIR = "/data/log/faultlog/temp"

--- Crash report directories the snapshot lists (both, always).
M.CRASH_DIRS = { M.FAULTLOG_DIR, M.FAULTLOG_TEMP_DIR }

--- OHOS ABI → LLVM target triple (the per-arch lib dir under the
--- SDK's `native/llvm/lib/`).
M.ARCH_TRIPLE = {
    ["arm64-v8a"] = "aarch64-linux-ohos",
    ["armeabi-v7a"] = "arm-linux-ohos",
    ["x86_64"] = "x86_64-linux-ohos",
}

--- Sentinel line prefixes. The nonce is appended and is alphanumeric,
--- so the lines need no quoting on the device.
local EXIT_TAG = "__LW_EXIT_"
local PID_TAG = "__LW_PID_"

--- Escape Lua pattern magic characters. Local (not `vim.pesc`): the
--- runner also runs under the standalone `lw` host, whose `vim` shim
--- provides only a subset of the editor API.
local function pesc(s)
    return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0"))
end

--- The program word the exec script hands to `exec`: `./<basename>`
--- when the program lives in the working directory, else unchanged.
---
--- Why: faultloggerd records the crashing process's name (PNAME) from its
--- exec path truncated to 128 bytes, and hiview's faultlogger report was
--- observed missing for a program exec'd by its long absolute staging
--- path, while `./<name>` from the cwd produced one (device-verified).
--- Only an absolute `argv[1]` whose directory equals `cwd` is rewritten;
--- bare utility names (`mkdir`, resolved via PATH) and relative or other
--- paths are kept as they are.
--- @param program string argv[1]
--- @param cwd string|nil
--- @return string
function M.exec_program(program, cwd)
    if type(program) ~= "string" or type(cwd) ~= "string" or cwd == "" then return program end
    local dir, base = program:match("^(/.-)/?([^/]+)$")
    if not dir or not base then return program end
    dir = dir:gsub("/+$", "")
    local c = cwd:gsub("/+$", "")
    if dir ~= c then return program end
    return "./" .. base
end

local function check_nonce(nonce)
    if type(nonce) ~= "string" or not nonce:match("^%w+$") then
        error("ohos runner: nonce must be alphanumeric", 3)
    end
end

--- Render the device-side shell script for an exec request (core §18.2).
---
---   cd '<cwd>' || { echo __LW_EXIT_<n>=126; exit 126; };
---   K='V' ... LD_LIBRARY_PATH='<d1>:<d2>'"${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
---     sh -c 'echo __LW_PID_<n>=$$; exec "$0" "$@"' '<prog>' '<argv2>' ...;
---   echo __LW_EXIT_<n>=$?
---
--- The inner `sh -c ... exec` makes the announced pid the program's own
--- (exec keeps the pid) while the outer shell survives to print the exit
--- sentinel. `<prog>` is `./<basename>` when argv[1] lives in `cwd`
--- (`M.exec_program`), else argv[1] itself. Env NAMES are emitted
--- unquoted — a quoted name is not an assignment — which is safe because
--- they are checked to be portable identifiers (core refuses anything
--- else before calling us; we check again). Every value and argument is single-quoted (`hdc.quote`).
--- @param request { argv: string[], cwd?: string, env?: table<string,string>, library_dirs?: string[], nonce: string }
--- @return string script ONE device command line
function M.render_exec_script(request)
    check_nonce(request.nonce)
    local argv = request.argv or {}
    if #argv == 0 then error("ohos runner: exec request has an empty argv", 2) end
    -- cwd is optional: without one (nil / empty) the program runs in the
    -- device shell's default directory and no `cd` is emitted.
    local cwd = request.cwd
    if cwd ~= nil and type(cwd) ~= "string" then
        error("ohos runner: exec request cwd must be a string", 2)
    end
    if cwd == "" then cwd = nil end
    local n = request.nonce

    local assigns = {}
    local env = request.env or {}
    local names = vim.tbl_keys(env)
    table.sort(names)
    for _, name in ipairs(names) do
        if type(name) ~= "string" or not name:match("^[A-Za-z_][A-Za-z0-9_]*$") then
            error("ohos runner: invalid environment name " .. vim.inspect(name), 2)
        end
        if name ~= "LD_LIBRARY_PATH" then
            assigns[#assigns + 1] = name .. "=" .. hdc.quote(tostring(env[name]))
        end
    end
    local dirs = request.library_dirs or {}
    if #dirs > 0 then
        for _, d in ipairs(dirs) do
            if d:find(":", 1, true) then
                error("ohos runner: library dir contains ':' (loader path separator): " .. d, 2)
            end
        end
        -- The manifest's library dirs are the loader path (core §18.9);
        -- keep whatever the device already had after them.
        assigns[#assigns + 1] = "LD_LIBRARY_PATH=" .. hdc.quote(table.concat(dirs, ":"))
            .. '"${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"'
    end

    local inner = "echo " .. PID_TAG .. n .. "=$$; exec \"$0\" \"$@\""
    local run = {}
    if #assigns > 0 then run[#run + 1] = table.concat(assigns, " ") end
    run[#run + 1] = "sh -c " .. hdc.quote(inner)
    local words = { M.exec_program(argv[1], cwd) }
    for i = 2, #argv do words[i] = argv[i] end
    run[#run + 1] = hdc.join(words)

    local parts = {}
    if cwd then
        parts[#parts + 1] = "cd " .. hdc.quote(cwd) .. " || { echo " .. EXIT_TAG .. n .. "=126; exit 126; }"
    end
    parts[#parts + 1] = table.concat(run, " ")
    parts[#parts + 1] = "echo " .. EXIT_TAG .. n .. "=$?"
    return table.concat(parts, "; ")
end

--- Recognise the exit sentinel for `nonce`.
---
--- The sentinel is matched at the END of the line: a program whose last
--- output lacks a trailing newline makes the device print
--- `<partial output>__LW_EXIT_<n>=<status>` on one line. The second
--- return value is that preceding program text (nil when the line is
--- the bare sentinel) so a caller can keep it as program output. A line
--- without this nonce is never a sentinel.
--- @param line string
--- @param nonce string
--- @return integer|nil status, string|nil preceding_output
function M.parse_exit(line, nonce)
    if type(line) ~= "string" or type(nonce) ~= "string" then return nil end
    line = hdc.normalize_line(line)
    local pre, st = line:match("^(.-)" .. pesc(EXIT_TAG .. nonce) .. "=(%d+)$")
    if not st then return nil end
    return tonumber(st), (pre ~= "" and pre or nil)
end

--- Recognise the process-id line for `nonce` (printed before the program
--- produces any output, so it is always a whole line).
--- @param line string
--- @param nonce string
--- @return integer|nil
function M.parse_pid(line, nonce)
    if type(line) ~= "string" or type(nonce) ~= "string" then return nil end
    line = hdc.normalize_line(line)
    local pid = line:match("^" .. pesc(PID_TAG .. nonce) .. "=(%d+)$")
    return pid and tonumber(pid) or nil
end

-- ---------------------------------------------------------------------------
-- Reaping a leftover program (core §18.7 / §18.2 `reap`)
-- ---------------------------------------------------------------------------

local REAP_TAG = "__LW_REAP_"

--- Seconds between the polite `kill`, the `kill -9` and the final check.
M.REAP_GRACE = 1

--- Render the device-side script that stops a program an interrupted run
--- left behind — ONLY while process `pid` is still that program:
---
---   p=<pid>; w=<program>; x() { e=$(readlink /proc/$p/exe 2>/dev/null);
---     [ "$e" = "$w" ] || [ "$e" = "$w (deleted)" ]; };
---   if ! [ -d /proc/$p ]; then echo __LW_REAP_<n>=gone;
---   elif [ -z "$(readlink /proc/$p/exe 2>/dev/null)" ]; then echo __LW_REAP_<n>=unknown;
---   elif ! x; then echo __LW_REAP_<n>=gone;
---   else kill $p 2>/dev/null; sleep <grace>; x && kill -9 $p 2>/dev/null; sleep <grace>;
---   if x; then echo __LW_REAP_<n>=unknown; else echo __LW_REAP_<n>=stopped; fi; fi
---
--- The identity check is `/proc/<pid>/exe`: the pid the exec script
--- announces is the program's own (`exec` keeps it), so its executable link
--- is the staged program; a pid the device has since reused for another
--- process points elsewhere and is reported `gone`, never signalled. An
--- unreadable link on a live process (another user's) cannot be judged:
--- `unknown`, nothing sent. `(deleted)` covers a program file replaced since.
--- Each signal is re-guarded by the check. A zombie (exited, not yet waited
--- for) has no readable link, so it counts as stopped.
--- @param leftover { pid: integer, nonce: string, program: string }
--- @return string|nil script, string|nil err
function M.render_reap_script(leftover)
    if type(leftover) ~= "table" then return nil, "no leftover" end
    local pid = leftover.pid
    if type(pid) ~= "number" or pid < 2 or pid ~= math.floor(pid) then return nil, "invalid pid" end
    local nonce = leftover.nonce
    if type(nonce) ~= "string" or not nonce:match("^%w+$") then return nil, "invalid nonce" end
    local program = leftover.program
    if type(program) ~= "string" or not program:match("^/") or program:find("[%z\r\n]") then
        return nil, "invalid program path"
    end
    local tag = REAP_TAG .. nonce .. "="
    local grace = tostring(M.REAP_GRACE)
    return table.concat({
        string.format("p=%d; w=%s", pid, hdc.quote(program)),
        'x() { e=$(readlink /proc/$p/exe 2>/dev/null); [ "$e" = "$w" ] || [ "$e" = "$w (deleted)" ]; }',
        "if ! [ -d /proc/$p ]; then echo " .. tag .. "gone",
        'elif [ -z "$(readlink /proc/$p/exe 2>/dev/null)" ]; then echo ' .. tag .. "unknown",
        "elif ! x; then echo " .. tag .. "gone",
        "else x && kill $p 2>/dev/null; sleep " .. grace .. "; x && kill -9 $p 2>/dev/null; sleep " .. grace,
        "if x; then echo " .. tag .. "unknown; else echo " .. tag .. "stopped; fi; fi",
    }, "; ")
end

--- Parse the reap script's output for `nonce`: "stopped", "gone" or nil
--- (unknown, or no verdict line).
--- @param lines string[]
--- @param nonce string
--- @return "stopped"|"gone"|nil
function M.parse_reap(lines, nonce)
    if type(lines) ~= "table" or type(nonce) ~= "string" then return nil end
    for _, l in ipairs(lines) do
        local v = hdc.normalize_line(tostring(l)):match("^" .. pesc(REAP_TAG .. nonce) .. "=(%a+)$")
        if v == "stopped" or v == "gone" then return v end
        if v then return nil end
    end
    return nil
end

-- ---------------------------------------------------------------------------
-- Crash reports
-- ---------------------------------------------------------------------------

--- Device command listing every crash report in `M.CRASH_DIRS`, one full
--- path per line. A shell loop (not `ls`) so an empty or missing
--- directory prints nothing; the unmatched glob word is skipped by the
--- `-e` test. The paths are constants — no caller data reaches the text.
--- @return string
function M.crash_list_command()
    local globs = {}
    for i, d in ipairs(M.CRASH_DIRS) do globs[i] = d .. "/cppcrash-*" end
    return "for f in " .. table.concat(globs, " ")
        .. '; do [ -e "$f" ] && echo "$f"; done'
end

--- Parse the crash listing into a set of full remote paths. Only whole
--- lines naming a `cppcrash-*` file directly inside one of
--- `M.CRASH_DIRS` count; anything else (errors, `[Fail]`) is ignored.
--- @param lines string[]
--- @return table<string, true>
function M.parse_crash_list(lines)
    local set = {}
    for _, raw in ipairs(lines or {}) do
        local line = vim.trim(hdc.normalize_line(raw))
        for _, d in ipairs(M.CRASH_DIRS) do
            if line:sub(1, #d + 1) == d .. "/" then
                local name = line:sub(#d + 2)
                if name:match("^cppcrash%-[^/]+$") then set[line] = true end
            end
        end
    end
    return set
end

--- Crash reports new since the snapshot (core §18.2 `crash_collect`).
---
--- Every new faultlogger report is returned (its name does not reliably
--- carry the pid). A new faultloggerd dump in the temp dir is returned
--- when its name is `cppcrash-<pid>-…` for the run's pid; without a pid
--- (`ctx` absent — core may not pass it) every new temp dump is returned:
--- the snapshot diff already confines them to the run's window.
--- @param before table<string, true>|nil
--- @param after table<string, true>|nil
--- @param ctx { pid?: integer }|nil optional run context
--- @return string[] sorted remote paths
function M.crash_collect(before, after, ctx)
    before = before or {}
    local pid = type(ctx) == "table" and tonumber(ctx.pid) or nil
    if pid and (pid < 1 or pid ~= math.floor(pid)) then pid = nil end
    local temp_prefix = M.FAULTLOG_TEMP_DIR .. "/"
    local out = {}
    for path in pairs(after or {}) do
        if type(path) == "string" and not before[path] then
            local keep = true
            if pid and path:sub(1, #temp_prefix) == temp_prefix then
                local file_pid = path:sub(#temp_prefix + 1):match("^cppcrash%-(%d+)%-")
                keep = file_pid ~= nil and tonumber(file_pid) == pid
            end
            if keep then out[#out + 1] = path end
        end
    end
    table.sort(out)
    return out
end

-- ---------------------------------------------------------------------------
-- Device description (model names)
-- ---------------------------------------------------------------------------

--- System parameters queried per device, with their `properties` keys.
--- Display name preference: market name, then product name, then model
--- (device-verified, Mate 60 Pro: no marketname parameter,
--- const.product.name = "HUAWEI Mate 60 Pro", model = "ALN-AL00").
M.DESCRIBE_PARAMS = {
    { param = "const.product.marketname", key = "market_name" },
    { param = "const.product.model", key = "model" },
    { param = "const.product.name", key = "product_name" },
}

--- Device command printing `<param>=<value>` for each describe param
--- (constants only). `param get` of an unset parameter prints an error
--- text (e.g. `get param: const.product.marketname fail! errNum is:106!`);
--- the parser discards it.
--- @return string
function M.describe_command()
    local ps = {}
    for i, p in ipairs(M.DESCRIBE_PARAMS) do ps[i] = p.param end
    return "for k in " .. table.concat(ps, " ")
        .. '; do echo "$k=$(param get $k 2>/dev/null)"; done'
end

--- True when `text` is `param get` error output rather than a value.
local function is_param_error(text)
    local lower = text:lower()
    return lower:find("fail!", 1, true) ~= nil
        or lower:find("errnum", 1, true) ~= nil
        or lower:match("^get param") ~= nil
end

--- Parse the describe output. A parameter whose value is `param get`
--- error text — or that a bare error line names — is treated as absent.
--- @param lines string[]
--- @return { display_name?: string, properties: table<string,string> }|nil
function M.parse_describe(lines)
    local by_param = {}
    for _, p in ipairs(M.DESCRIBE_PARAMS) do by_param[p.param] = p.key end
    local props, failed = {}, {}
    for _, raw in ipairs(lines or {}) do
        local line = vim.trim(hdc.normalize_line(raw))
        local k, v = line:match("^([%w%._]+)=(.*)$")
        local key = k and by_param[k]
        if key then
            v = vim.trim(v)
            if is_param_error(v) then
                failed[key] = true
            elseif v ~= "" then
                props[key] = v
            end
        elseif is_param_error(line) then
            -- Bare error line (e.g. a multi-line `param get` result):
            -- every describe param it names is absent.
            for param, pkey in pairs(by_param) do
                if line:find(param, 1, true) then failed[pkey] = true end
            end
        end
    end
    for key in pairs(failed) do props[key] = nil end
    if next(props) == nil then return nil end
    return {
        display_name = props.market_name or props.product_name or props.model,
        properties = props,
    }
end

--- Build the log Session (core §18.13) for one run.
---
---   clear      `hdc -t S shell hilog -r` — flush the buffer so the run's
---              log starts clean (best-effort, core ignores failure).
---   stream(p)  `hdc -t S shell hilog -P <p>` — ONLY `-P`: no `-L` (it
---              suppresses some native log paths), no `-t`/`-T` (native
---              OH_LOG_Print lands on type `core`; tags are filtered
---              client-side). hilog first replays the pid's buffered
---              records, then follows. Without a pid: plain `hilog`.
---   receive    sanitize → parse → session prefilter (mode `prefilter`,
---              the pid given to `stream`, the program name as proc).
---              Unparseable lines are kept raw.
---   display    parse → soft filter (level/tag/proc/grep/exclude) →
---              compact rendering; nil when filtered out.
---   show       show policy from the `show` option.
--- @param spec fun(args: string[]): table spec builder bound to hdc
--- @param serial string
--- @param options table|nil
--- @param program { path: string, name: string }|nil
--- @return table|nil session, string|nil err
function M.log_session(spec, serial, options, program)
    local o, err = hilog.resolve_options(options, "native")
    if not o then return nil, err end

    local name = program and program.name
    local filter = hilog.filter_from_options(o)
    local prefilter = hilog.make_prefilter({ mode = o.prefilter, name = name })

    local S = {
        clear = spec(hdc.shell_argv(serial, "hilog -r")),
        show = o.show_policy,
        options = o,
    }

    function S.stream(pid)
        pid = tonumber(pid)
        if pid and (pid < 1 or pid ~= math.floor(pid)) then pid = nil end
        prefilter = hilog.make_prefilter({ mode = o.prefilter, pid = pid, name = name })
        if pid then
            return spec(hdc.shell_argv(serial, string.format("hilog -P %d", pid)))
        end
        return spec(hdc.shell_argv(serial, "hilog"))
    end

    function S.receive(line)
        local clean = hilog.sanitize(line)
        if clean == "" then return nil end
        local record = hilog.parse_line(clean)
        if not record then return clean end
        if prefilter(record) then return clean end
        return nil
    end

    function S.display(line)
        local record, clean = hilog.parse_line(line)
        if not record then
            if not clean or clean == "" then return nil end
            if hilog.match_filter(filter, { raw = clean }, clean) then return clean end
            return nil
        end
        local rendered = hilog.render(record, "compact")
        if hilog.match_filter(filter, record, rendered) then return rendered end
        return nil
    end

    return S
end

--- Construct a runner.
--- @param opts { hdc: string, sdk_path?: string, platforms: string[], win?: boolean }
--- @return table Runner (core §18.2)
function M.new(opts)
    assert(opts and opts.hdc, "ohos runner: hdc path required")
    local hdc_path = opts.hdc
    local win = opts.win

    local function spec(args, check)
        return { cmd = hdc_path, args = args, check_output = check }
    end

    local R = {
        id = "ohos",
        platforms = opts.platforms or {},
        staging_base = M.STAGING_BASE,
        archive = true,
        -- Device-side argv prefix printing `<hex>  <path>` per file.
        -- toybox `sha256sum` exists on HarmonyOS (device-verified). If it
        -- is ever missing the command fails, no digests come back and core
        -- simply re-stages (safe, only slower). md5sum is deliberately
        -- NOT used as an automatic fallback: the device digest must be
        -- the same algorithm core records on the host.
        digest = { "sha256sum" },
        -- `hdc shell` merges the program's stderr into stdout (verified).
        combined_output = true,
        -- Core defaults (query 120 s, transfer 600 s) are used.
        timeouts = nil,
    }

    function R.list_devices()
        return spec(hdc.argv(nil, "list", "targets", "-v"))
    end

    R.parse_devices = hdc.parse_targets

    function R.push(serial, local_path, remote)
        return spec(hdc.argv(serial, "file", "send",
            hdc.local_path(local_path, win), remote), hdc.check_output)
    end

    function R.pull(serial, remote, local_path)
        return spec(hdc.argv(serial, "file", "recv",
            remote, hdc.local_path(local_path, win)), hdc.check_output)
    end

    -- exec's check sees only connector lines (before the pid line, after
    -- the exit sentinel) — but merged device stderr can arrive out of
    -- order and land there, so it uses the connector-only check: hdc's
    -- `[Fail]` markers, never a program's own `error: ...` text.
    function R.exec(serial, request)
        return spec(hdc.shell_argv(serial, M.render_exec_script(request)),
            hdc.check_connector_output)
    end

    R.parse_exit = M.parse_exit
    R.parse_pid = M.parse_pid

    --- Stop the program started with `nonce`. Only a pid reported by
    --- `parse_pid` is used; without one nothing is sent (nil).
    function R.terminate(serial, nonce, pid)
        pid = tonumber(pid)
        if not pid or pid < 1 or pid ~= math.floor(pid) then return nil end
        local p = string.format("%d", pid)
        return spec(hdc.shell_argv(serial,
            "kill " .. p .. " 2>/dev/null; sleep 1; kill -9 " .. p .. " 2>/dev/null"))
    end

    --- Stop a program an interrupted run left (core §18.7), verified by
    --- `/proc/<pid>/exe` against the staged program before any signal
    --- (`M.render_reap_script`). Returns the spec and `parse(lines)` →
    --- "stopped" | "gone" | nil. An invalid leftover raises (core reports a
    --- warning; nothing is sent).
    function R.reap(serial, leftover)
        local script, err = M.render_reap_script(leftover)
        if not script then error("ohos runner: cannot reap: " .. tostring(err), 2) end
        local nonce = leftover.nonce
        return spec(hdc.shell_argv(serial, script), hdc.check_connector_output),
            function(lines) return M.parse_reap(lines, nonce) end
    end

    --- Snapshot of existing native crash reports in both crash dirs
    --- (faultlogger reports and faultloggerd temp dumps): returns the
    --- spec and a parser turning its output into a set of full paths.
    function R.crash_snapshot(serial)
        return spec(hdc.shell_argv(serial, M.crash_list_command()), hdc.check_connector_output),
            M.parse_crash_list
    end

    --- Remote paths of crash reports new since the snapshot; the optional
    --- third argument `{ pid }` confines temp dumps to the run's pid.
    R.crash_collect = M.crash_collect

    --- Optional device description (model name) for one ONLINE device:
    --- returns the spec and `parse(lines)` →
    --- `{ display_name?, properties }` or nil. One hdc call per device.
    function R.describe_device(serial)
        return spec(hdc.shell_argv(serial, M.describe_command()), hdc.check_connector_output),
            M.parse_describe
    end

    --- Platform runtime files a program built by `tool` needs beside it:
    --- the shared C++ runtime from the SDK's native sysroot, staged
    --- UNCONDITIONALLY (0.9 MB; harmless for a static-STL program — the
    --- runner sees only the tool, not the configuration's OHOS_STL).
    --- @param tool table loomworks.Tool (uses `.data`) or raw tool_data
    --- @return { local: string, relative: string }[]
    function R.runtime_files(tool)
        if not opts.sdk_path or not tool then return {} end
        local data = tool.data or tool
        local triple = data.arch and M.ARCH_TRIPLE[data.arch]
        if not triple then return {} end
        local path = opts.sdk_path .. "/sdk/default/openharmony/native/llvm/lib/"
            .. triple .. "/libc++_shared.so"
        if not (vim.uv or vim.loop).fs_stat(path) then return {} end
        return { { ["local"] = path, relative = "libc++_shared.so" } }
    end

    --- Runner log stream for one run (core §18.13): hilog for the
    --- program's pid. `options` is the merged `device_log` / `--log` map
    --- (hilog.lua vocabulary, native-executable defaults); `program` is
    --- `{ path, name }` of the staged program.
    --- @return table|nil Session, string|nil err
    function R.log_session(serial, options, program)
        return M.log_session(spec, serial, options, program)
    end

    return R
end

return M
