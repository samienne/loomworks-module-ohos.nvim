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

--- Where the device writes native crash reports (faultlogger).
M.FAULTLOG_DIR = "/data/log/faultlog/faultlogger"

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

local function check_nonce(nonce)
    if type(nonce) ~= "string" or not nonce:match("^%w+$") then
        error("ohos runner: nonce must be alphanumeric", 3)
    end
end

--- Render the device-side shell script for an exec request (core §18.2).
---
---   cd '<cwd>' || { echo __LW_EXIT_<n>=126; exit 126; };
---   K='V' ... LD_LIBRARY_PATH='<d1>:<d2>'"${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
---     sh -c 'echo __LW_PID_<n>=$$; exec "$0" "$@"' '<argv1>' '<argv2>' ...;
---   echo __LW_EXIT_<n>=$?
---
--- The inner `sh -c ... exec` makes the announced pid the program's own
--- (exec keeps the pid) while the outer shell survives to print the exit
--- sentinel. Env NAMES are emitted unquoted — a quoted name is not an
--- assignment — which is safe because they are checked to be portable
--- identifiers (core refuses anything else before calling us; we check
--- again). Every value and argument is single-quoted (`hdc.quote`).
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
    run[#run + 1] = hdc.join(argv)

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
        -- VERIFY on device: toybox `sha256sum` on HarmonyOS NEXT. If it
        -- is missing the command fails, no digests come back and core
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

    function R.exec(serial, request)
        return spec(hdc.shell_argv(serial, M.render_exec_script(request)),
            hdc.check_output)
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

    --- Snapshot of existing native crash reports: returns the spec and a
    --- parser turning its output into a set of `cppcrash-*` names.
    function R.crash_snapshot(serial)
        local s = spec(hdc.shell_words(serial, { "ls", "-1", M.FAULTLOG_DIR .. "/" }))
        local function parse(lines)
            local set = {}
            for _, raw in ipairs(lines or {}) do
                for word in hdc.normalize_line(raw):gmatch("%S+") do
                    local name = word:match("([^/]+)$")
                    if name and name:match("^cppcrash%-") then set[name] = true end
                end
            end
            return set
        end
        return s, parse
    end

    --- Remote paths of crash reports present in `after` but not `before`.
    function R.crash_collect(before, after)
        local out = {}
        for name in pairs(after or {}) do
            if not (before or {})[name] then
                out[#out + 1] = M.FAULTLOG_DIR .. "/" .. name
            end
        end
        table.sort(out)
        return out
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
