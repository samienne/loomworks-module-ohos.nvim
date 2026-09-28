--- Standalone-host driver for tests/ohos_device_e2e_spec.lua: the same remote
--- run, but under the `lw` host's `vim` shim (luvi + LuaJIT) instead of
--- Neovim — the device runner is used by the `lw` CLI there, and the shim
--- provides only a subset of the editor API.
---
---   luvi tests/fixtures/shim_e2e -- <core lua dir> <plugin root> <sdk dir> <build dir>
---
--- Expects the fake-hdc environment (FAKE_HDC_*) the spec sets up. Prints ONE
--- JSON line with the outcome; exit 0 unless the run could not be set up.

local core_lua, plugin_root, sdk_dir, build = ...
package.path = table.concat({
    core_lua .. "/?.lua", core_lua .. "/?/init.lua",
    plugin_root .. "/lua/?.lua", plugin_root .. "/lua/?/init.lua",
}, ";") .. ";" .. package.path
_G.vim = require("loomworks.shim")

local ok, err = pcall(function()
    local ohos = require("loomworks.sdks.ohos")
    local manifest = require("loomworks.remote.manifest")
    local remote_run = require("loomworks.remote.run")
    local runner = assert(ohos.device_runner({ sdk_path = function() return sdk_dir end }), "no runner")
    assert(require("loomworks.remote.runners").validate(runner))
    local targets = {
        prog = { type = "executable", artifact = "bin/prog", dependencies = { "foo" } },
        foo = { type = "shared_library", artifact = "lib/libfoo.so" },
    }
    local unit = { id = "build/App/Debug", targets = targets }
    local device = { archive = { "assets/**" }, env = { E2E_VAR = "shim" } }
    local man = assert(manifest.build({ build_dir = build, artifact = build .. "/bin/prog", unit = unit,
        target = targets.prog, runner = runner, tool = { data = { arch = "arm64-v8a" } }, device = device }))
    local out, errs = {}, {}
    local res, rerr = remote_run.execute({
        ws = { name = "shim ws", _device_sync = {}, _devices = {} },
        runner = runner, unit = unit, manifest = man, device = device,
        args = { [[it's "both"]] }, log_options = { show = "both", tail = "7" },
        liveness_ms = 60000,
        write_out = function(s) out[#out + 1] = s end,
        write_err = function(s) errs[#errs + 1] = s end,
        note = function(s) errs[#errs + 1] = "lw: " .. s end,
    })
    assert(res, rerr)
    io.stdout:write(vim.json.encode({
        status = res.status, exit_code = res.exit_code, transport_error = res.transport_error or vim.NIL,
        tail = res.show and res.show.tail or vim.NIL, out = out, err = errs,
        warnings = res.warnings, run_dir = res.run_dir,
    }), "\n")
end)
if not ok then
    io.stdout:write(vim.json.encode({ error = tostring(err) }), "\n")
    os.exit(1)
end
os.exit(0)
