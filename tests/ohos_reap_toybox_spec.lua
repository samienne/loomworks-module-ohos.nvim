--- The ohos device scripts under a RESTRICTED toolset that emulates the
--- phone's toybox (spec/sdks/ohos.md §8.10): only the proven tools are on
--- PATH (no `tr`, no `awk`), and `grep` stops at the first NUL byte of each
--- input, as toybox 0.8.12's grep does on /proc/<pid>/{environ,cmdline}.
--- The host's POSIX sh and /proc stand in for the device's. Beta.3 phone
--- regressions this catches: the wrapper survived the next-run reap (its
--- NUL-separated cmdline was never matched) and a program whose staging was
--- removed could not be identified by its run token ("could not tell").

local runner_mod = require("loomworks-module-ohos.runner")

local function to_sh(p) return (p:gsub("\\", "/"):gsub("^(%a):", function(d) return "/" .. d:lower() end)) end

local function sh_ok()
    if vim.fn.executable("sh") ~= 1 then return false end
    local out = vim.fn.systemlist({ "sh", "-c",
        "[ -d /proc/$$ ] && readlink /proc/$$/exe && command -v head tr grep xargs >/dev/null" })
    return vim.v.shell_error == 0 and out[1] ~= nil and out[1] ~= ""
end

local function real(tool)
    -- the executable file, never a shell builtin's bare name (a shim that
    -- execs "echo" would find itself on the restricted PATH and loop)
    local out = vim.fn.systemlist({ "sh", "-c", "type -P " .. tool .. " 2>/dev/null || command -v " .. tool })
    local p = (out[1] or ""):gsub("\r$", "")
    return p:find("/", 1, true) and p or nil
end

local function write_exe(path, body)
    local f = assert(io.open(path, "wb"))
    f:write(body)
    f:close()
    vim.fn.setfperm(path, "rwxr-xr-x")
end

--- Build a shim directory. `tools` = the plain tools linked through; the
--- grep shim cuts every input at its first NUL; `strings` is emulated
--- (printable runs of 4+). Returns the directory as the host sh sees it.
--- @param opts { no_xargs?: boolean }
local function make_toolbox(opts)
    opts = opts or {}
    local dir = vim.fn.tempname():gsub("\\", "/") .. "-toybox"
    vim.fn.mkdir(dir, "p")
    local plain = { "cut", "od", "readlink", "sleep", "timeout", "cat", "ls", "echo", "sh", "kill" }
    if not opts.no_xargs then plain[#plain + 1] = "xargs" end
    for _, t in ipairs(plain) do
        local r = real(t)
        if r then write_exe(dir .. "/" .. t, "#!/bin/sh\nexec '" .. r .. "' \"$@\"\n") end
    end
    local HEAD, TR, GREP = real("head"), real("tr"), real("grep")
    write_exe(dir .. "/grep", table.concat({
        "#!/bin/sh",
        "# toybox 0.8.12 grep: an input ends at its first NUL byte",
        "o=; while [ $# -gt 0 ]; do case \"$1\" in --) shift; break;; -?*) o=\"$o $1\"; shift;; *) break;; esac; done",
        "p=$1; shift",
        "cut0() { '" .. HEAD .. "' -z -n1 | '" .. TR .. "' -d '\\000'; }",
        "if [ $# -eq 0 ]; then cut0 | '" .. GREP .. "' $o -- \"$p\"; exit $?; fi",
        "r=1; for f in \"$@\"; do if cut0 < \"$f\" | '" .. GREP .. "' $o -- \"$p\"; then r=0; fi; done; exit $r",
        "",
    }, "\n"))
    write_exe(dir .. "/strings", table.concat({
        "#!/bin/sh",
        "'" .. TR .. "' -c '[:print:]' '\\n' < \"$1\" | '" .. GREP .. "' -a '.\\{4,\\}'",
        "",
    }, "\n"))
    return to_sh(dir), dir
end

local function run_in(toolbox, script)
    local out = vim.fn.systemlist({ "sh", "-c", "PATH='" .. toolbox .. "'; export PATH; " .. script })
    for i, l in ipairs(out) do out[i] = l:gsub("\r$", "") end
    return out
end

local function alive(pid)
    vim.fn.system({ "sh", "-c", "[ -d /proc/" .. pid .. " ]" })
    return vim.v.shell_error == 0
end
--- A killed process can linger briefly in /proc on the host (MSYS).
local function gone_soon(pid) vim.wait(3000, function() return not alive(pid) end, 100) end
local function kill9(pid) vim.fn.system({ "sh", "-c", "kill -9 " .. pid .. " 2>/dev/null" }) end
--- Start `cmd` under the (full) host sh in the background; returns its pid.
local function bg(cmd)
    local out = vim.fn.systemlist({ "sh", "-c", "sh -c '" .. cmd:gsub("'", "'\\''")
        .. "' >/dev/null 2>&1 </dev/null & echo $!" })
    return tonumber((out[1] or ""):match("%d+"))
end
local function read_pid(file)
    vim.wait(3000, function() return vim.fn.filereadable(file) == 1 and vim.fn.getfsize(file) > 0 end, 50)
    local f = io.open(file, "rb")
    local s = f and f:read("*a") or ""
    if f then f:close() end
    return tonumber(s:match("%d+"))
end
--- A copy of the host's `sleep` named `prog` stands in for the staged program.
local function make_prog()
    local root = vim.fn.tempname():gsub("\\", "/")
    vim.fn.mkdir(root, "p")
    vim.fn.system({ "sh", "-c", 'cp "$(command -v sleep)" "' .. to_sh(root) .. '/prog"' })
    return root, to_sh(root)
end

local STAGED = "/data/local/tmp/.device-staging/ws/u/bin/prog"

for _, variant in ipairs({ { name = "toybox" }, { name = "toybox without xargs (strings)", no_xargs = true } }) do
    describe("ohos device scripts under " .. variant.name, function()
        local toolbox, toolbox_dir, grace
        before_each(function()
            grace = runner_mod.REAP_GRACE
            runner_mod.REAP_GRACE = 0.3
            if sh_ok() then toolbox, toolbox_dir = make_toolbox(variant) end
        end)
        after_each(function()
            runner_mod.REAP_GRACE = grace
            if toolbox_dir then vim.fn.delete(toolbox_dir, "rf") end
        end)
        local function reap(leftover)
            local out = run_in(toolbox, assert(runner_mod.render_reap_script(leftover)))
            return runner_mod.parse_reap(out, leftover.nonce), out
        end

        it("the emulation holds: no tr/awk, grep stops at the first NUL", function()
            if not sh_ok() then pending("no sh with /proc"); return end
            local out = run_in(toolbox, "command -v tr; command -v awk; "
                .. "echo x | grep -q x && echo grep-ok; "
                .. "grep -qF PATH= /proc/$$/environ && echo nul-crossed || echo nul-stops")
            local all = table.concat(out, "\n")
            assert.truthy(all:find("grep-ok", 1, true), all)
            assert.truthy(all:find("nul-stops", 1, true), all)
            assert.is_nil(all:find("/tr", 1, true), all)
        end)

        it("B2: staging removed — the run token in environ identifies the program", function()
            if not sh_ok() then pending("no sh with /proc"); return end
            local root, sh_root = make_prog()
            bg("echo $$ > " .. sh_root .. "/pid; exec env A=1 LOOMWORKS_RUN_NONCE=t1 Z=2 " .. sh_root .. "/prog 60")
            local pid = read_pid(root .. "/pid")
            assert.is_true(alive(pid))
            local verdict, out = reap({ pid = pid, nonce = "t1", program = STAGED })
            assert.equals("stopped", verdict, table.concat(out, "\n"))
            assert.is_false(alive(pid))
            vim.fn.delete(root, "rf")
        end)

        it("B2: another run's token is never signalled", function()
            if not sh_ok() then pending("no sh with /proc"); return end
            local root, sh_root = make_prog()
            bg("echo $$ > " .. sh_root .. "/pid; exec env LOOMWORKS_RUN_NONCE=t1x " .. sh_root .. "/prog 60")
            local pid = read_pid(root .. "/pid")
            local verdict, out = reap({ pid = pid, nonce = "t1", program = STAGED })
            assert.equals("gone", verdict, table.concat(out, "\n"))
            assert.is_true(alive(pid))
            kill9(pid)
            vim.fn.delete(root, "rf")
        end)

        it("B1b: next-run reap of a live program also stops its wrapper", function()
            if not sh_ok() then pending("no sh with /proc"); return end
            local root, sh_root = make_prog()
            local wrapper = bg(": __LW_EXIT_w1=; sh -c 'echo $$ > " .. sh_root
                .. "/pid; exec env LOOMWORKS_RUN_NONCE=w1 " .. sh_root .. "/prog 60'; sleep 60; true")
            local pid = read_pid(root .. "/pid")
            assert.is_number(pid)
            local verdict, out = reap({ pid = pid, nonce = "w1", program = sh_root .. "/prog" })
            assert.equals("stopped", verdict, table.concat(out, "\n"))
            assert.is_false(alive(pid))
            gone_soon(wrapper)
            assert.is_false(alive(wrapper), "wrapper stopped: " .. table.concat(out, "\n"))
            vim.fn.delete(root, "rf")
        end)

        it("a wrapper whose program already exited is stopped; another run's is not", function()
            if not sh_ok() then pending("no sh with /proc"); return end
            local wrapper = bg(": __LW_EXIT_w2=; sleep 60; true")
            local decoy = bg(": __LW_EXIT_w2x=; sleep 60; true")
            local dead = bg("sleep 60")
            kill9(dead)
            vim.wait(300)
            local verdict, out = reap({ pid = dead, nonce = "w2", program = "/x/prog" })
            assert.equals("gone", verdict, table.concat(out, "\n"))
            gone_soon(wrapper)
            assert.is_false(alive(wrapper), "wrapper stopped: " .. table.concat(out, "\n"))
            assert.is_true(alive(decoy), "another run's wrapper untouched")
            kill9(decoy)
        end)

        it("the exec script runs with only these tools", function()
            if not sh_ok() then pending("no sh with /proc"); return end
            local out = run_in(toolbox, runner_mod.render_exec_script({
                argv = { "echo", "hi" }, env = { K = "v" }, nonce = "x1" }))
            assert.is_number(runner_mod.parse_pid(out[1], "x1"))
            assert.equals("hi", out[2])
            assert.equals(0, runner_mod.parse_exit(out[3], "x1"))
        end)
    end)
end
