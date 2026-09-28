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
            "describe_device", "runtime_files", "log_session" }) do
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

    -- Exact shapes from a real hdc (host exit code 0 in every case).
    local REAL_FAILS = {
        "[Fail]Error opening file: no such file or directory, path:/data/local/tmp/x/results.xml",
        "[Fail]Not match target founded, check connect-key please",
        "[Fail]ExecuteCommand need connect-key? please confirm a device by help info",
    }

    it("every builder's check catches the real hdc [Fail] shapes (CRLF too)", function()
        local r = new_runner()
        local specs = {
            r.push("S", "/b/x", "/d/x"), r.pull("S", "/d/x", "/b/x"),
            r.exec("S", { argv = { "/d/p" }, cwd = "/d", nonce = "n1" }),
            (r.crash_snapshot("S")), (r.describe_device("S")),
        }
        for _, sp in ipairs(specs) do
            for _, line in ipairs(REAL_FAILS) do
                local err = sp.check_output({ line .. "\r" })
                assert.equals((line:gsub("^%[Fail%]", "")), err)
            end
        end
    end)

    it("exec's check ignores device-side error text (merged, unordered stderr)", function()
        -- `hdc shell` merges device stderr into stdout without ordering:
        -- a program's `error: ...` can land before the pid line or after
        -- the sentinel, where core runs the check. It is not a connector failure.
        local check = new_runner().exec("S", { argv = { "/d/p" }, cwd = "/d", nonce = "n1" }).check_output
        assert.is_nil(check({ "error: config file missing", "sh: cd: x: No such file or directory" }))
        assert.is_nil(check({}))
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
                .. "sh -c 'echo __LW_PID_N0nce=$$; exec \"$0\" \"$@\"' ./prog '--gtest_filter=A.*'",
            "echo __LW_EXIT_N0nce=$?",
        }, "; "), s)
    end)

    it("execs a program living in cwd as ./<basename> (short faultlog PNAME)", function()
        local ep = runner_mod.exec_program
        assert.equals("./prog", ep("/d/app/prog", "/d/app"))
        assert.equals("./prog", ep("/d/app/prog", "/d/app/"))
        assert.equals("./x", ep("/x", "/"))
        assert.equals("/d/app/bin/prog", ep("/d/app/bin/prog", "/d/app"))
        assert.equals("/d/other/prog", ep("/d/other/prog", "/d/app"))
        assert.equals("/d/app/prog", ep("/d/app/prog", nil))
        assert.equals("mkdir", ep("mkdir", "/"))
        assert.equals("sub/prog", ep("sub/prog", "/d"))
        local s = render({ argv = { "/data/local/tmp/.device-staging/ws/u/test/unittest/api_unit_tests", "a" },
            cwd = "/data/local/tmp/.device-staging/ws/u/test/unittest", nonce = "n" })
        assert.truthy(s:find("\"$@\"' ./api_unit_tests a; ", 1, true), s)
        -- elsewhere: the absolute path is kept
        local s2 = render({ argv = { "/d/bin/prog" }, cwd = "/d", nonce = "n" })
        assert.truthy(s2:find("' /d/bin/prog; ", 1, true), s2)
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
            'echo "argv0=$0"',
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
        -- exec'd as ./prog from its cwd (the script says so; $0 of a shebang
        -- script is not portable evidence — MSYS resolves it to a full path)
        assert.truthy(script:find("\"$@\"' ./prog ", 1, true), script)
        assert.truthy(out[3]:match("^argv0=.*prog$"), out[3])
        assert.is_truthy(out[4]:find("dir with space", 1, true), out[4])
        assert.equals("env=v a l'ue $x", out[5])
        assert.equals("ld=" .. sh_dir .. "/lib", out[6])
        for i, a in ipairs(args) do
            assert.equals("arg=[" .. a .. "]", out[6 + i])
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
    local FL = "/data/log/faultlog/faultlogger/"
    local TMP = "/data/log/faultlog/temp/"

    it("snapshots both crash dirs as full paths", function()
        local r = new_runner()
        local s, parse = r.crash_snapshot("S1")
        assert.same({ "-t", "S1", "shell", "for f in /data/log/faultlog/faultlogger/cppcrash-* "
            .. "/data/log/faultlog/temp/cppcrash-*; do [ -e \"$f\" ] && echo \"$f\"; done" }, s.args)
        local set = parse({
            FL .. "cppcrash-foo-20000-1\r", FL .. "appfreeze-x-1", TMP .. "cppcrash-4242-1790000000000.json",
            TMP .. "sub/cppcrash-1-1", "/data/elsewhere/cppcrash-1-1", "cppcrash-bare-1", "",
            "[Fail]ExecuteCommand need connect-key? please confirm a device by help info",
        })
        assert.same({
            [FL .. "cppcrash-foo-20000-1"] = true,
            [TMP .. "cppcrash-4242-1790000000000.json"] = true,
        }, set)
    end)

    it("the listing command runs under a real sh (empty dirs print nothing)", function()
        if vim.fn.executable("sh") ~= 1 then
            pending("no sh on PATH")
            return
        end
        local out = vim.fn.systemlist({ "sh", "-c", runner_mod.crash_list_command() })
        assert.same({}, runner_mod.parse_crash_list(out))
    end)

    it("collects new faultlogger reports and the temp dump of the run's pid", function()
        local r = new_runner()
        local before = { [FL .. "cppcrash-old-1-1"] = true, [TMP .. "cppcrash-77-1.json"] = true }
        local after = {
            [FL .. "cppcrash-old-1-1"] = true, [TMP .. "cppcrash-77-1.json"] = true,
            [FL .. "cppcrash-api_unit_te-0-20260928"] = true,
            [TMP .. "cppcrash-4242-1790000000000.json"] = true,
            [TMP .. "cppcrash-5555-1790000000001.json"] = true,   -- another process
        }
        assert.same({
            FL .. "cppcrash-api_unit_te-0-20260928",
            TMP .. "cppcrash-4242-1790000000000.json",
        }, r.crash_collect(before, after, { pid = 4242 }))
        -- Without the pid (core's current 2-argument call) every new temp dump.
        assert.same({
            FL .. "cppcrash-api_unit_te-0-20260928",
            TMP .. "cppcrash-4242-1790000000000.json",
            TMP .. "cppcrash-5555-1790000000001.json",
        }, r.crash_collect(before, after))
        assert.same(r.crash_collect(before, after), r.crash_collect(before, after, { pid = "x" }))
        assert.same({}, r.crash_collect(after, after, { pid = 4242 }))
    end)

    it("treats a permission error as an empty snapshot", function()
        local _, parse = new_runner().crash_snapshot("S1")
        assert.same({}, parse({ "ls: /data/log/faultlog/faultlogger/: Permission denied" }))
    end)
end)

describe("ohos runner describe_device", function()
    it("queries model params in one device command", function()
        local s, parse = new_runner().describe_device("FMR0123504000090")
        assert.same({ "-t", "FMR0123504000090", "shell",
            "for k in const.product.marketname const.product.model const.product.name; "
                .. "do echo \"$k=$(param get $k 2>/dev/null)\"; done" }, s.args)
        assert.is_function(parse)
    end)

    it("prefers market name, then product name, then model", function()
        local parse = runner_mod.parse_describe
        assert.same({
            display_name = "HUAWEI Mate 60",
            properties = { market_name = "HUAWEI Mate 60", model = "ALN-AL00", product_name = "HUAWEI Mate 60 Pro" },
        }, parse({ "const.product.marketname=HUAWEI Mate 60\r", "const.product.model=ALN-AL00\r",
            "const.product.name=HUAWEI Mate 60 Pro\r" }))
        assert.same({ display_name = "ALN-AL00", properties = { model = "ALN-AL00" } }, parse({
            "const.product.marketname=", "const.product.model=ALN-AL00", "const.product.name=",
        }))
    end)

    it("real Mate 60 Pro shape: missing marketname error is absent, product name wins", function()
        local parse = runner_mod.parse_describe
        local want = {
            display_name = "HUAWEI Mate 60 Pro",
            properties = { model = "ALN-AL00", product_name = "HUAWEI Mate 60 Pro" },
        }
        -- Error text captured into the value.
        assert.same(want, parse({
            "const.product.marketname=get param: const.product.marketname fail! errNum is:106!\r",
            "const.product.model=ALN-AL00\r",
            "const.product.name=HUAWEI Mate 60 Pro\r",
        }))
        -- Variant wording.
        assert.same(want, parse({
            'const.product.marketname=Get parameter "const.product.marketname" fail! errNum is:106!',
            "const.product.model=ALN-AL00", "const.product.name=HUAWEI Mate 60 Pro",
        }))
        -- Error on its own line after an empty value (multi-line result).
        assert.same(want, parse({
            "const.product.marketname=",
            "get param: const.product.marketname fail! errNum is:106!",
            "const.product.model=ALN-AL00", "const.product.name=HUAWEI Mate 60 Pro",
        }))
        -- A bare error line naming a key drops that key even after a
        -- stray value.
        assert.same(want, parse({
            "const.product.marketname=garbage",
            "param get const.product.marketname errNum is:106",
            "const.product.model=ALN-AL00", "const.product.name=HUAWEI Mate 60 Pro",
        }))
        -- A legitimate value merely containing "fail" is kept.
        assert.same({ display_name = "Failsafe X", properties = { product_name = "Failsafe X" } },
            parse({ "const.product.name=Failsafe X" }))
        assert.is_nil(parse({}))
        assert.is_nil(parse({ "[Fail]ExecuteCommand need connect-key? please confirm a device by help info" }))
        assert.is_nil(parse({ "unrelated=Thing", "const.product.model=" }))
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
