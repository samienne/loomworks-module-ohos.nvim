--- End-to-end: the REAL ohos device runner driven by the REAL loomworks core
--- remote-execution path (core §18.4–§18.6, §18.13), against a fake `hdc`
--- that emulates one device on the host. NOTHING here talks to a device.
---
--- The fake hdc (tests/fixtures/fake_hdc/main.lua) is fused into a real
--- executable with `luvi` and placed where the SDK ships hdc
--- (`sdk/default/openharmony/toolchains/hdc[.exe]`), so core spawns it exactly
--- like the real connector. `hdc shell <cmd>` runs `<cmd>` with a real POSIX
--- sh inside a directory standing in for the device's `/data`; file
--- send/recv are copies; hilog prints canned lines.
---
--- Covered: device listing, staging (mkdir -p, push, chmod 755, sha256sum
--- verification, one ustar/pax archive unpacked with tar -xf then deleted
--- behind an `.ok` marker; core's shortened §18.4 device root), incremental
--- re-staging, the platform runtime file (libc++_shared.so), exec with an
--- argument holding both quote kinds, env + loader path + cwd, pid and exit
--- sentinels, unterminated last output, the log session (clear, hilog -P
--- <program pid>, receive prefilter, display filter, device.log), the
--- `--log` string form of numeric options (tail), gtest framework probe +
--- results XML pull (then removed with its empty directory), crash collection (a faultlogger cppcrash report AND a
--- faultloggerd temp dump `faultlog/temp/cppcrash-<pid>-<ts>.json` for the
--- program's pid only, via crash_collect ctx.pid), the program exec'd as `./<basename>` from its directory,
--- and hilog's proc-less system-domain records kept by the pid prefilter.
---
--- Skipped unless: LOOMWORKS_PATH points at a core with remote execution
--- (`loomworks.remote.run`), `luvi` is on PATH, and a POSIX sh is found.

local uv = vim.uv or vim.loop
local is_win = vim.fn.has("win32") == 1

local have_core = pcall(require, "loomworks.remote.run")

local function find_sh()
    local cands = {}
    if is_win then
        -- Git for Windows' launcher sets up PATH for its utilities.
        cands = { "C:/Program Files/Git/bin/sh.exe", "C:/Program Files/Git/usr/bin/sh.exe" }
    end
    local p = vim.fn.exepath("sh")
    if p ~= "" then cands[#cands + 1] = p end
    for _, c in ipairs(cands) do
        if uv.fs_stat(c) then return (c:gsub("\\", "/")) end
    end
    return nil
end

local SH = find_sh()
local LUVI = vim.fn.exepath("luvi")

local function skip_reason()
    if not have_core then return "LOOMWORKS_PATH core has no loomworks.remote (remote execution)" end
    if LUVI == "" then return "luvi not on PATH (needed to build the fake hdc)" end
    if not SH then return "no POSIX sh" end
    return nil
end

local function write(path, data, mode)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write(data)
    f:close()
    if mode then vim.fn.setfperm(path, mode) end
end

local function read(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local d = f:read("*a")
    f:close()
    return d
end

--- The path of a host dir as the POSIX sh sees it (Git Bash: C:/x → /c/x).
local function sh_path(p)
    if is_win then
        return (p:gsub("^(%a):", function(d) return "/" .. d:lower() end))
    end
    return p
end

--- The program: a POSIX sh script standing in for a native test executable.
local PROGRAM = [==[#!/bin/sh
for a in "$@"; do
  case "$a" in
    --gtest_list_tests) printf 'Suite.\n  Passes\n  Fails\n'; exit 0 ;;
  esac
done
echo "self=$$"
echo "argv0=$0"
echo "cwd=$(pwd)"
for a in "$@"; do printf 'arg=[%s]\n' "$a"; done
echo "env=$E2E_VAR"
echo "ld=$LD_LIBRARY_PATH"
[ -f ./libc++_shared.so ] && echo "runtime=beside"
cat ../assets/deep/data.txt
echo "to stderr" 1>&2
for a in "$@"; do
  case "$a" in
    --gtest_output=xml:*)
      x=${a#--gtest_output=xml:}
      cat > "$x" <<'XML'
<?xml version="1.0" encoding="UTF-8"?>
<testsuites tests="2" failures="1" errors="0" name="AllTests">
  <testsuite name="Suite" tests="2" failures="1" errors="0">
    <testcase name="Passes" status="run" result="completed" time="0" classname="Suite" />
    <testcase name="Fails" status="run" result="completed" time="0" classname="Suite">
      <failure message="expected 1" type=""><![CDATA[boom]]></failure>
    </testcase>
  </testsuite>
</testsuites>
XML
      ;;
  esac
done
if [ -n "$E2E_CRASH" ]; then
  : > "$FAKE_HDC_SHROOT/data/log/faultlog/faultlogger/cppcrash-prog-$$-20260928"
  echo '{"pid":'"$$"',"reason":"SIGSEGV"}' > "$FAKE_HDC_SHROOT/data/log/faultlog/temp/cppcrash-$$-1790000000000.json"
  # Another process's dump in the same window: excluded via crash_collect's ctx.pid.
  other=$(( $$ + 1 ))
  echo '{"pid":'"$other"'}' > "$FAKE_HDC_SHROOT/data/log/faultlog/temp/cppcrash-$other-1790000000001.json"
fi
printf 'last line without newline'
exit 3
]==]

describe("ohos device runner end-to-end (fake hdc, real core)", function()
    local reason = skip_reason()
    if reason then
        it("is skipped: " .. reason, function() pending(reason) end)
        return
    end

    local remote_run = require("loomworks.remote.run")
    local manifest = require("loomworks.remote.manifest")
    local test_run = require("loomworks.remote.test_run")
    local runners = require("loomworks.remote.runners")
    local ohos = require("loomworks.sdks.ohos")
    local runner_mod = require("loomworks-module-ohos.runner")

    local tmp, sdk_dir, dev_root, build, calls_file, runner, saved_env
    local ENV_KEYS = { "FAKE_HDC_ROOT", "FAKE_HDC_SHROOT", "FAKE_HDC_SH", "FAKE_HDC_SERIAL",
        "FAKE_HDC_HILOG", "FAKE_HDC_CALLS", "LOOMWORKS_DEVICE_LOCK_DIR" }

    local function calls()
        local out = {}
        for l in (read(calls_file) or ""):gmatch("[^\n]+") do out[#out + 1] = l end
        return out
    end

    local function unit_and_target()
        local targets = {
            prog = { type = "executable", artifact = "bin/prog", dependencies = { "foo" } },
            foo = { type = "shared_library", artifact = "lib/libfoo.so" },
        }
        local tool = { data = { arch = "arm64-v8a" } }
        local unit = { id = "build/App/Debug", targets = targets }
        return unit, targets.prog, tool
    end

    local function execute(o)
        local unit, target, tool = unit_and_target()
        local device = { archive = { "assets/**" }, env = { E2E_VAR = [[v 'a' "b" $x]] } }
        if o.crash then device.env.E2E_CRASH = "1" end
        local man = assert(manifest.build({ build_dir = build, artifact = build .. "/bin/prog", unit = unit,
            target = target, runner = runner, tool = tool, device = device }))
        local out, err = {}, {}
        local ws = o.ws
        local res, rerr = remote_run.execute({
            ws = ws, runner = runner, unit = unit, manifest = man, device = device,
            args = o.args or {}, log_options = o.log_options, results = o.results,
            before_exec = o.before_exec, fresh = o.fresh,
            liveness_ms = 60000,
            write_out = function(s) out[#out + 1] = s end,
            write_err = function(s) err[#err + 1] = s end,
            note = function(s) err[#err + 1] = "lw: " .. s end,
        })
        assert(res, rerr)
        return res, out, err, man
    end

    before_each(function()
        runners._reset()
        tmp = vim.fn.tempname():gsub("\\", "/")
        sdk_dir = tmp .. "/sdk"
        dev_root = tmp .. "/device"
        build = tmp .. "/build"
        calls_file = tmp .. "/hdc-calls.txt"
        saved_env = {}
        for _, k in ipairs(ENV_KEYS) do saved_env[k] = vim.env[k] end

        -- SDK layout: hdc + the kit's shared C++ runtime.
        local hdc = sdk_dir .. "/sdk/default/openharmony/toolchains/hdc" .. (is_win and ".exe" or "")
        vim.fn.mkdir(vim.fs.dirname(hdc), "p")
        local fixture = vim.fn.fnamemodify("tests/fixtures/fake_hdc", ":p"):gsub("\\", "/"):gsub("/$", "")
        -- luvi only recognises native absolute paths (backslashes on Windows).
        local native = function(p) return is_win and (p:gsub("/", "\\")) or p end
        local r = vim.system({ LUVI, native(fixture), "-o", native(hdc) }, { text = true }):wait()
        assert(r.code == 0 and uv.fs_stat(hdc), "luvi could not build the fake hdc: " .. tostring(r.stderr))
        write(sdk_dir .. "/sdk/default/openharmony/native/llvm/lib/aarch64-linux-ohos/libc++_shared.so", "libcxx")

        -- The emulated device's filesystem.
        vim.fn.mkdir(dev_root .. "/data/local/tmp", "p")
        vim.fn.mkdir(dev_root .. "/data/log/faultlog/faultlogger", "p")
        write(dev_root .. "/data/log/faultlog/faultlogger/cppcrash-old-1-1", "old crash")
        write(dev_root .. "/data/log/faultlog/temp/cppcrash-1-1.json", "old dump")

        -- Build tree: program, a derived shared library, an archive set with a
        -- path too long for plain ustar (pax record).
        write(build .. "/bin/prog", PROGRAM, "rwxr-xr-x")
        write(build .. "/lib/libfoo.so", "foo")
        write(build .. "/assets/deep/data.txt", "asset-data")
        local long = "assets/" .. string.rep("very-long-directory-name/", 5) .. string.rep("n", 60) .. ".bin"
        write(build .. "/" .. long, "long")

        write(tmp .. "/hilog.txt", table.concat({
            "09-28 12:00:00.100  {PID}  {PID} I C01234/prog/E2E: program started",
            "09-28 12:00:00.200  {PID}  {PID} D C01234/prog/E2E: debug detail",
            "09-28 12:00:00.250  {PID}  {PID} I C03F00/MUSL-LDSO: load /data/x/libfoo.so: ok",
            "09-28 12:00:00.300  999  999 E C05555/other/Noise: unrelated process",
            "09-28 12:00:00.400  {PID}  {PID} E C01234/prog/E2E: something failed",
        }, "\n") .. "\n")

        vim.env.FAKE_HDC_ROOT = dev_root
        vim.env.FAKE_HDC_SHROOT = sh_path(dev_root)
        vim.env.FAKE_HDC_SH = SH
        vim.env.FAKE_HDC_SERIAL = "FAKE0001"
        vim.env.FAKE_HDC_HILOG = tmp .. "/hilog.txt"
        vim.env.FAKE_HDC_CALLS = calls_file
        vim.env.LOOMWORKS_DEVICE_LOCK_DIR = tmp .. "/locks"

        runner = ohos.device_runner({ sdk_path = function() return sdk_dir end })
        assert.is_table(runner, "the provider found the SDK's hdc")
        assert.is_true(runners.validate(runner))
    end)

    after_each(function()
        for _, k in ipairs(ENV_KEYS) do vim.env[k] = saved_env[k] end
        vim.fn.delete(tmp, "rf")
        runners._reset()
    end)

    it("stages, runs, streams, recovers status and logs through the real runner", function()
        local ws = { name = "e2e ws", _device_sync = {}, _devices = {} }
        local tricky = [[it's "both" $HOME;`x`]]
        local res, out, err = execute({ ws = ws, args = { "plain", tricky, "" },
            log_options = { show = "both", tail = "5" } })

        assert.is_nil(res.transport_error, res.transport_error)
        assert.equals("FAKE0001", res.serial)
        assert.equals(3, res.status)
        assert.equals(3, res.exit_code)
        assert.is_true(res.failed)

        -- Device root derived the way core names it (§18.4: shortened
        -- workspace + `<last id component>-<10 hex>` unit segments).
        local _, droot = manifest.device_roots(runner_mod.STAGING_BASE, ws.name, "build/App/Debug")
        assert.truthy(droot:match("^/data/local/tmp/%.device%-staging/e2e_ws/Debug%-%x+$"), droot)
        -- ...and it is the one unit directory actually staged on the device.
        local staged = vim.fn.glob(dev_root .. "/data/local/tmp/.device-staging/e2e_ws/*", false, true)
        assert.same({ dev_root .. droot }, vim.tbl_map(function(x) return (x:gsub("\\", "/")) end, staged))
        local text = table.concat(out, "\n")
        -- cwd = the artifact's device directory (device path, as the device sees it)
        assert.truthy(text:find("cwd=" .. droot .. "/bin", 1, true), text)
        -- exec'd as ./<basename> from its own directory (short faultlog
        -- PNAME). Checked on the command hdc received: `$0` of a shebang
        -- script is resolved to a full path by some hosts' sh (MSYS).
        local exec_calls = vim.tbl_filter(function(l) return l:find("__LW_PID_", 1, true) ~= nil
            and l:find("cd " .. droot .. "/bin ||", 1, true) ~= nil end, calls())
        assert.truthy(#exec_calls > 0, table.concat(calls(), "\n"))
        for _, l in ipairs(exec_calls) do
            assert.truthy(l:find("\"$@\"' ./prog", 1, true), l)
        end
        -- every argument byte-for-byte, the empty one included
        assert.truthy(text:find("arg=[plain]", 1, true), text)
        assert.truthy(text:find("arg=[" .. tricky .. "]", 1, true), text)
        assert.truthy(text:find("arg=[]", 1, true), text)
        assert.truthy(text:find([[env=v 'a' "b" $x]], 1, true), text)
        -- loader path = staged library dirs (sorted): bin (runtime), lib
        assert.truthy(text:find("ld=" .. droot .. "/bin:" .. droot .. "/lib", 1, true), text)
        assert.truthy(text:find("runtime=beside", 1, true), text)
        -- the archive set was unpacked on the device
        assert.truthy(text:find("asset-data", 1, true), text)
        -- stderr merged into the one program stream (combined_output)
        assert.truthy(text:find("to stderr", 1, true), text)
        -- unterminated last output is program output, not lost with the sentinel
        assert.equals("last line without newline", out[#out])
        assert.falsy(text:find("__LW_", 1, true), "connector lines never reach program output")

        -- Staged tree on the "device".
        local host_root = dev_root .. droot
        assert.equals("foo", read(host_root .. "/lib/libfoo.so"))
        assert.equals("libcxx", read(host_root .. "/bin/libc++_shared.so"))
        assert.equals("asset-data", read(host_root .. "/assets/deep/data.txt"))
        local long = "assets/" .. string.rep("very-long-directory-name/", 5) .. string.rep("n", 60) .. ".bin"
        assert.equals("long", read(host_root .. "/" .. long), "pax path record honoured by tar -xf")
        -- The archive is deleted after unpack; an `.ok` marker records it.
        assert.same({}, vim.fn.glob(host_root .. "/.loomworks/archive-*.tar", false, true),
            "archive removed after unpack")
        local oks = vim.fn.glob(host_root .. "/.loomworks/archive-*.ok", false, true)
        assert.equals(1, #oks, "unpack marker under .loomworks/")
        assert.truthy(oks[1]:gsub("\\", "/"):match("/archive%-%x%x%x%x%x%x%x%x%x%x%x%x%.ok$"), oks[1])

        -- Housekeeping went through exec with POSIX utilities; the log
        -- stream followed the program's own pid.
        local c = table.concat(calls(), "\n")
        for _, needle in ipairs({ "shell | hilog -r", "mkdir -p", "chmod 755", "sha256sum", "tar -xf",
            "file | send", "list | targets | -v" }) do
            assert.truthy(c:find(needle, 1, true), "hdc saw " .. needle)
        end
        local self_pid = text:match("self=(%d+)")
        assert.truthy(c:find("shell | hilog -P " .. self_pid, 1, true),
            "hilog -P follows the pid announced before the program ran (" .. tostring(self_pid) .. ")")

        -- Log session: receive prefilter (pid) dropped the other process but
        -- kept the pid's proc-less system-domain record; display (show=both,
        -- level I) printed live; tail as a string.
        local dlog = read(res.run_dir .. "/device.log")
        assert.truthy(dlog:find("program started", 1, true), dlog)
        assert.truthy(dlog:find("MUSL-LDSO: load /data/x/libfoo.so: ok", 1, true), dlog)
        assert.truthy(dlog:find("debug detail", 1, true), "kept lines are saved unfiltered by display")
        assert.falsy(dlog:find("unrelated process", 1, true))
        local shown = table.concat(err, "\n")
        assert.truthy(shown:find("something failed", 1, true), shown)
        assert.falsy(shown:find("debug detail", 1, true))
        assert.equals(5, res.show.tail)

        -- output.log: unfiltered program output, no connector lines.
        local olog = read(res.run_dir .. "/output.log")
        assert.truthy(olog:find("last line without newline\n", 1, true))
        assert.falsy(olog:find("__LW_", 1, true))
        -- No crash: the pre-existing report is not "new".
        assert.same({}, res.crashes)

        -- Second run: incremental — the record is verified against the device
        -- (sha256sum) and nothing is re-sent.
        local sends_before = select(2, table.concat(calls(), "\n"):gsub("file | send", ""))
        local res2, _, err2 = execute({ ws = ws, args = {} })
        assert.equals(3, res2.status)
        local sends_after = select(2, table.concat(calls(), "\n"):gsub("file | send", ""))
        assert.equals(sends_before, sends_after, "nothing re-sent")
        assert.truthy(table.concat(err2, "\n"):find("no changed files", 1, true))

        -- A wiped device is detected by digest verification and re-staged.
        vim.fn.delete(dev_root .. "/data/local/tmp/.device-staging", "rf")
        local res3 = execute({ ws = ws, args = {} })
        assert.equals(3, res3.status)
        assert.equals("foo", read(host_root .. "/lib/libfoo.so"))
    end)

    it("works the same under the standalone lw host's vim shim", function()
        local core = os.getenv("LOOMWORKS_PATH")
        if not core or not uv.fs_stat(core .. "/lua/loomworks/shim/init.lua") then
            pending("LOOMWORKS_PATH core has no standalone shim")
            return
        end
        local native = function(p) return is_win and (p:gsub("/", "\\")) or p end
        local root = vim.fn.getcwd():gsub("\\", "/")
        local r = vim.system({ LUVI, native(root .. "/tests/fixtures/shim_e2e"), "--",
            (core:gsub("\\", "/")) .. "/lua", root, sdk_dir, build }, { text = true }):wait()
        local line = (r.stdout or ""):match("[^\r\n]*{.*}[^\r\n]*")
        assert.is_string(line, "driver output: " .. tostring(r.stdout) .. tostring(r.stderr))
        local res = vim.json.decode(line)
        assert.is_nil(res.error, res.error)
        assert.equals(0, r.code)
        assert.equals(vim.NIL, res.transport_error, vim.inspect(res))
        assert.equals(3, res.status)
        assert.equals(7, res.tail)
        local text = table.concat(res.out, "\n")
        assert.truthy(text:find('arg=[it\'s "both"]', 1, true), text)
        assert.truthy(text:find("env=shim", 1, true), text)
        assert.equals("last line without newline", res.out[#res.out])
        assert.truthy(table.concat(res.err, "\n"):find("something failed", 1, true))
    end)

    it("gtest probe + results XML pull, and a new crash report fails the run", function()
        local ws = { name = "e2e ws", _device_sync = {}, _devices = {} }
        local hook, st = test_run.device_hook("prog")
        local res = execute({ ws = ws, crash = true, before_exec = hook })
        assert.is_nil(res.transport_error, res.transport_error)
        assert.equals("gtest", st.framework)
        local xml = res.results[st.results_name]
        assert.is_string(xml, "results file pulled")
        local parsed = require("loomworks.gtest").parse_xml_results(xml)
        local counts = test_run.count(parsed)
        assert.equals(2, counts.total)
        assert.equals(1, counts.failed)

        -- The pulled results file is removed from the device, and its
        -- now-empty results directory with it.
        local _, droot = manifest.device_roots(runner_mod.STAGING_BASE, ws.name, "build/App/Debug")
        local results_dir = dev_root .. droot .. "/" .. test_run.RESULTS_REL
        assert.is_nil(uv.fs_stat(results_dir .. "/" .. st.results_name), "results file cleared")
        assert.is_nil(uv.fs_stat(results_dir), "empty results dir removed")
        assert.truthy(uv.fs_stat(dev_root .. droot .. "/bin/prog"), "staged tree itself kept")

        -- Both the faultlogger report and the faultloggerd temp dump of the
        -- program's pid (crash_collect gets ctx.pid, so another process's new
        -- dump is excluded); the pre-existing ones are not new.
        assert.equals(2, #res.crashes, vim.inspect(res.crashes))
        local by = {}
        for _, c in ipairs(res.crashes) do by[c:match("[^/]+$")] = c end
        local report = vim.tbl_filter(function(n) return n:match("^cppcrash%-prog%-%d+%-20260928$") end,
            vim.tbl_keys(by))[1]
        assert.is_string(report, vim.inspect(res.crashes))
        local pid = report:match("^cppcrash%-prog%-(%d+)%-")
        local dump = by["cppcrash-" .. pid .. "-1790000000000.json"]
        assert.is_string(dump, "temp dump for the program's pid collected: " .. vim.inspect(res.crashes))
        assert.truthy(read(dump):find('"pid":' .. pid, 1, true))
        assert.is_true(res.failed)
    end)
end)
