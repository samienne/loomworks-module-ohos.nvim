--- Tests for the ohos device runner (spec/sdks/ohos.md §8; core §18.2).
---
--- The runner only builds specs and parses output. A fake executor
--- captures every spec instead of running hdc — NOTHING here talks to a
--- device. The exec script is additionally executed by the host's POSIX
--- sh (standing in for the device shell) to prove quoting, cwd, env,
--- loader path, pid and sentinel behaviour end to end.

local runner_mod = require("loomworks-module-ohos.runner")
local ohos = require("loomworks.sdks.ohos")

local is_win = vim.fn.has("win32") == 1
local exe = is_win and ".exe" or ""

local HDC = "/sdk/toolchains/hdc"

--- Fake executor: records specs, returns canned output per call.
local function fake_executor(outputs)
    local calls = {}
    local function run(spec)
        calls[#calls + 1] = { cmd = spec.cmd, args = vim.deepcopy(spec.args) }
        local out = outputs and outputs[#calls] or {}
        local err = spec.check_output and spec.check_output(out) or nil
        return out, err
    end
    return run, calls
end

local function new_runner(o)
    o = o or {}
    return runner_mod.new({
        hdc = HDC, sdk_path = o.sdk_path, platforms = { "ohos-aarch64", "ohos-arm" },
        win = o.win or false,
    })
end

local function touch(path)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "wb"))
    f:write("")
    f:close()
end

describe("ohos runner identity", function()
    it("declares the §18.2 capability fields", function()
        local r = new_runner()
        assert.equals("ohos", r.id)
        assert.same({ "ohos-aarch64", "ohos-arm" }, r.platforms)
        assert.equals("/data/local/tmp/.device-staging", r.staging_base)
        assert.is_true(r.archive)
        assert.same({ "sha256sum" }, r.digest)
        assert.is_true(r.combined_output)
        assert.is_nil(r.timeouts)
        for _, b in ipairs({ "list_devices", "parse_devices", "push", "pull", "exec",
            "parse_exit", "parse_pid", "terminate", "crash_snapshot", "crash_collect",
            "runtime_files", "log_session" }) do
            assert.is_function(r[b], b)
        end
    end)
end)

describe("ohos runner specs (fake executor)", function()
    it("lists devices with `list targets -v` and parses them", function()
        local r = new_runner()
        local run, calls = fake_executor({ { "S1\tUSB\tConnected\tlocalhost", "[Empty]" } })
        local out = run(r.list_devices())
        assert.same({ cmd = HDC, args = { "list", "targets", "-v" } }, calls[1])
        local devs = r.parse_devices(out)
        assert.equals(1, #devs)
        assert.equals("S1", devs[1].serial)
        assert.equals("online", devs[1].state)
    end)

    it("push renders the local path with backslashes on Windows", function()
        local r = new_runner({ win = true })
        local run, calls = fake_executor()
        run(r.push("S1", "C:/b/test/x.so", "/data/local/tmp/.device-staging/w/u/test/x.so"))
        assert.same({ "-t", "S1", "file", "send", "C:\\b\\test\\x.so",
            "/data/local/tmp/.device-staging/w/u/test/x.so" }, calls[1].args)
    end)

    it("pull keeps device path POSIX and renders the local one", function()
        local r = new_runner({ win = true })
        local s = r.pull("S1", "/data/log/faultlog/faultlogger/cppcrash-1", "C:/b/.device-runs/r/c")
        assert.same({ "-t", "S1", "file", "recv", "/data/log/faultlog/faultlogger/cppcrash-1",
            "C:\\b\\.device-runs\\r\\c" }, s.args)
    end)

    it("push/pull/exec detect [Fail] reported with exit 0", function()
        local r = new_runner()
        local run = fake_executor({ { "[Fail]Error opening file: no such file" } })
        local _, err = run(r.push("S1", "/b/x", "/d/x"))
        assert.is_truthy(err and err:find("Error opening file", 1, true))
        assert.is_function(r.pull("S", "/a", "/b").check_output)
        assert.is_function(r.exec("S", { argv = { "/d/p" }, cwd = "/d", nonce = "n1" }).check_output)
    end)

    it("exec renders the device command as ONE argv element after shell", function()
        local r = new_runner()
        local s = r.exec("S1", { argv = { "/d/p", "a b" }, cwd = "/d", env = {}, library_dirs = {}, nonce = "abc123" })
        assert.equals(HDC, s.cmd)
        assert.equals(4, #s.args)
        assert.same({ "-t", "S1", "shell" }, { s.args[1], s.args[2], s.args[3] })
        assert.equals(runner_mod.render_exec_script({ argv = { "/d/p", "a b" }, cwd = "/d", nonce = "abc123" }),
            s.args[4])
    end)

    it("terminate kills the reported pid, and sends nothing without one", function()
        local r = new_runner()
        local s = r.terminate("S1", "n1", 4242)
        assert.same({ "-t", "S1", "shell",
            "kill 4242 2>/dev/null; sleep 1; kill -9 4242 2>/dev/null" }, s.args)
        assert.is_nil(r.terminate("S1", "n1", nil))
        assert.is_nil(r.terminate("S1", "n1", "1; rm -rf /"))
        assert.is_nil(r.terminate("S1", "n1", -1))
    end)
end)

describe("ohos runner exec script", function()
    local render = runner_mod.render_exec_script

    it("has cd guard, env, loader path, inner exec and sentinel", function()
        local s = render({
            argv = { "/d/app/prog", "--gtest_filter=A.*" },
            cwd = "/d/app",
            env = { ZED = "z", ALPHA = "it's" },
            library_dirs = { "/d/app", "/d/app/plugins" },
            nonce = "N0nce",
        })
        assert.equals(table.concat({
            "cd /d/app || { echo __LW_EXIT_N0nce=126; exit 126; }",
            "ALPHA='it'\\''s' ZED=z LD_LIBRARY_PATH=/d/app:/d/app/plugins\"${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}\" "
                .. "sh -c 'echo __LW_PID_N0nce=$$; exec \"$0\" \"$@\"' /d/app/prog '--gtest_filter=A.*'",
            "echo __LW_EXIT_N0nce=$?",
        }, "; "), s)
    end)

    it("housekeeping requests: no cwd / env / library_dirs emits no cd", function()
        local s = render({ argv = { "mkdir", "-p", "/d/x y" }, nonce = "hk1" })
        assert.equals(table.concat({
            "sh -c 'echo __LW_PID_hk1=$$; exec \"$0\" \"$@\"' mkdir -p '/d/x y'",
            "echo __LW_EXIT_hk1=$?",
        }, "; "), s)
        assert.equals(s, render({ argv = { "mkdir", "-p", "/d/x y" }, cwd = "", env = {},
            library_dirs = {}, nonce = "hk1" }))
        assert.has_error(function() render({ argv = { "/p" }, cwd = 5, nonce = "n" }) end)
    end)

    it("housekeeping utilities resolve through the device shell (real sh)", function()
        if vim.fn.executable("sh") ~= 1 then
            pending("no sh on PATH")
            return
        end
        local out = vim.fn.systemlist({ "sh", "-c", render({ argv = { "echo", "hi there" }, nonce = "u1" }) })
        for i, l in ipairs(out) do out[i] = l:gsub("\r$", "") end
        assert.is_number(runner_mod.parse_pid(out[1], "u1"))
        assert.equals("hi there", out[2])
        assert.equals(0, runner_mod.parse_exit(out[3], "u1"))
    end)

    it("omits LD_LIBRARY_PATH without library dirs and ignores it in env", function()
        local s = render({ argv = { "/p" }, cwd = "/", env = { LD_LIBRARY_PATH = "/evil" }, nonce = "n" })
        assert.is_nil(s:find("LD_LIBRARY_PATH", 1, true))
    end)

    it("refuses bad nonces, env names and loader dirs", function()
        assert.has_error(function() render({ argv = { "/p" }, cwd = "/", nonce = "a;b" }) end)
        assert.has_error(function() render({ argv = { "/p" }, cwd = "/", nonce = "" }) end)
        assert.has_error(function() render({ argv = { "/p" }, cwd = "/", nonce = "n", env = { ["A B"] = "x" } }) end)
        assert.has_error(function() render({ argv = { "/p" }, cwd = "/", nonce = "n", env = { ["1A"] = "x" } }) end)
        assert.has_error(function() render({ argv = { "/p" }, cwd = "/", nonce = "n", library_dirs = { "/a:b" } }) end)
        assert.has_error(function() render({ argv = { "/p\nx" }, cwd = "/", nonce = "n" }) end)
        assert.has_error(function() render({ argv = {}, cwd = "/", nonce = "n" }) end)
    end)

    it("runs under a real POSIX sh: args byte-for-byte, cwd, env, loader path, pid, status", function()
        if vim.fn.executable("sh") ~= 1 then
            pending("no sh on PATH")
            return
        end
        local root = vim.fn.tempname():gsub("\\", "/")
        local dir = root .. "/dir with space"
        vim.fn.mkdir(dir .. "/lib", "p")
        local prog = dir .. "/prog"
        local f = assert(io.open(prog, "wb"))
        f:write(table.concat({
            "#!/bin/sh",
            'echo "self=$$"',
            'echo "cwd=$(pwd)"',
            'echo "env=$MYVAR"',
            'echo "ld=$LD_LIBRARY_PATH"',
            'for a in "$@"; do printf "arg=[%s]\\n" "$a"; done',
            'echo "to stderr" 1>&2',
            "exit 3",
            "",
        }, "\n"))
        f:close()
        vim.fn.setfperm(prog, "rwxr-xr-x")

        -- The "device" paths as the host sh sees them (C:/x → /c/x under
        -- Git Bash on Windows; a drive colon is not a loader-path entry).
        local sh_dir = dir:gsub("^(%a):", function(d) return "/" .. d:lower() end)

        local args = { "one arg", "it's", "\"dq\"", "mixed 'single' \"double\"", "$HOME",
            "$(echo pwned)", "back\\slash", "a;b", "*", "" }
        local argv = { sh_dir .. "/prog" }
        vim.list_extend(argv, args)
        local script = render({
            argv = argv, cwd = sh_dir,
            env = { MYVAR = "v a l'ue $x" },
            library_dirs = { sh_dir .. "/lib" },
            nonce = "T3st",
        })
        local out = vim.fn.systemlist({ "sh", "-c", "unset LD_LIBRARY_PATH; " .. script })
        for i, l in ipairs(out) do out[i] = l:gsub("\r$", "") end
        vim.fn.delete(root, "rf")

        local pid = runner_mod.parse_pid(out[1], "T3st")
        assert.is_number(pid, "first line is the pid line: " .. tostring(out[1]))
        assert.equals("self=" .. pid, out[2], "announced pid is the program's own")
        assert.is_truthy(out[3]:find("dir with space", 1, true), out[3])
        assert.equals("env=v a l'ue $x", out[4])
        assert.equals("ld=" .. sh_dir .. "/lib", out[5])
        for i, a in ipairs(args) do
            assert.equals("arg=[" .. a .. "]", out[5 + i])
        end
        local joined = table.concat(out, "\n")
        assert.equals(3, runner_mod.parse_exit(out[#out], "T3st"))
    end)

    it("reports 126 when cwd does not exist", function()
        if vim.fn.executable("sh") ~= 1 then
            pending("no sh on PATH")
            return
        end
        local out = vim.fn.systemlist({ "sh", "-c",
            render({ argv = { "/p" }, cwd = "/no/such/dir/xyz", nonce = "c" }) .. " 2>/dev/null" })
        local status
        for _, l in ipairs(out) do status = status or runner_mod.parse_exit(l, "c") end
        assert.equals(126, status)
    end)
end)

describe("ohos runner sentinel parsing", function()
    it("parses exit and pid lines for the nonce, tolerating CR", function()
        assert.equals(0, runner_mod.parse_exit("__LW_EXIT_ab1=0", "ab1"))
        assert.equals(139, runner_mod.parse_exit("__LW_EXIT_ab1=139\r", "ab1"))
        assert.equals(777, runner_mod.parse_pid("__LW_PID_ab1=777\r", "ab1"))
    end)

    it("ignores other nonces and look-alikes", function()
        assert.is_nil(runner_mod.parse_exit("__LW_EXIT_other=0", "ab1"))
        assert.is_nil(runner_mod.parse_exit("__LW_EXIT_ab1=", "ab1"))
        assert.is_nil(runner_mod.parse_exit("__LW_EXIT_ab1=0 trailing", "ab1"))
        assert.is_nil(runner_mod.parse_exit("__LW_EXIT_ab12=0", "ab1"))
        assert.is_nil(runner_mod.parse_pid("x __LW_PID_ab1=5", "ab1"))
        assert.is_nil(runner_mod.parse_pid("__LW_PID_other=5", "ab1"))
        assert.is_nil(runner_mod.parse_exit(nil, "ab1"))
    end)

    it("recovers the status after unterminated program output", function()
        local st, pre = runner_mod.parse_exit("partial line__LW_EXIT_ab1=2", "ab1")
        assert.equals(2, st)
        assert.equals("partial line", pre)
        local st2, pre2 = runner_mod.parse_exit("__LW_EXIT_ab1=2", "ab1")
        assert.equals(2, st2)
        assert.is_nil(pre2)
    end)
end)

describe("ohos runner crash reports", function()
    it("snapshots cppcrash-* names and diffs before/after", function()
        local r = new_runner()
        local s, parse = r.crash_snapshot("S1")
        assert.same({ "-t", "S1", "shell", "ls -1 /data/log/faultlog/faultlogger/" }, s.args)
        local before = parse({ "cppcrash-foo-20000-1\r", "appfreeze-x", "syswarning-1", "" })
        assert.same({ ["cppcrash-foo-20000-1"] = true }, before)
        local after = parse({
            "cppcrash-foo-20000-1", "cppcrash-LumeSceneAPITestRunner-20010-20260928",
            "cppcrash-b-1  cppcrash-a-2",   -- multi-column ls output is tolerated
        })
        assert.same({
            "/data/log/faultlog/faultlogger/cppcrash-LumeSceneAPITestRunner-20010-20260928",
            "/data/log/faultlog/faultlogger/cppcrash-a-2",
            "/data/log/faultlog/faultlogger/cppcrash-b-1",
        }, r.crash_collect(before, after))
    end)

    it("treats a permission error as an empty snapshot", function()
        local _, parse = new_runner().crash_snapshot("S1")
        assert.same({}, parse({ "ls: /data/log/faultlog/faultlogger/: Permission denied" }))
    end)
end)

describe("ohos runner runtime_files", function()
    local root
    after_each(function() if root then vim.fn.delete(root, "rf") end end)

    it("stages libc++_shared.so from the SDK sysroot for the kit's arch", function()
        root = vim.fn.tempname():gsub("\\", "/")
        local lib = root .. "/sdk/default/openharmony/native/llvm/lib/aarch64-linux-ohos/libc++_shared.so"
        touch(lib)
        local r = new_runner({ sdk_path = root })
        assert.same({ { ["local"] = lib, relative = "libc++_shared.so" } },
            r.runtime_files({ data = { arch = "arm64-v8a" } }))
        -- raw tool_data is accepted too
        assert.equals(1, #r.runtime_files({ arch = "arm64-v8a" }))
        -- arch whose runtime is absent from the SDK → nothing
        assert.same({}, r.runtime_files({ data = { arch = "armeabi-v7a" } }))
        assert.same({}, r.runtime_files({ data = {} }))
    end)
end)

describe("ohos provider device_runner", function()
    local root
    after_each(function() if root then vim.fn.delete(root, "rf") end end)

    it("uses the SDK's own hdc and returns nil without one", function()
        root = vim.fn.tempname():gsub("\\", "/")
        vim.fn.mkdir(root, "p")
        local sdk = ohos.create_sdk("ohos-t", root, "5.0.0")
        assert.is_nil(ohos.device_runner(sdk), "no hdc in the installation → no runner")

        local hdc_path = root .. "/sdk/default/openharmony/toolchains/hdc" .. exe
        touch(hdc_path)
        local r = ohos.device_runner(sdk)
        assert.is_not_nil(r)
        assert.equals(hdc_path, r.list_devices().cmd)
        assert.same({ "ohos-aarch64", "ohos-arm" }, r.platforms)
    end)
end)
