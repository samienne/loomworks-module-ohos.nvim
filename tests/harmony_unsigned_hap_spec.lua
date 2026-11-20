--- An unsigned HAP (build-profile.json5 with `"signingConfigs": []`; hvigor
--- logs "Will skip sign 'hos_hap'. No signingConfigs") only fails on the
--- phone: `hdc install` -> "code:9568320 error: no signature file.".
--- The module refuses it before installing (spec/modules/harmony.md §6.4).

local harmony = require("loomworks.modules.harmony")

local uv = vim.uv or vim.loop

local function mkproject(haps)
    local root = vim.fn.tempname()
    local out = root .. "/proj/entry/build/default/outputs/default"
    vim.fn.mkdir(out, "p")
    for i, name in ipairs(haps) do
        local p = out .. "/" .. name
        local f = assert(io.open(p, "wb")); f:write("hap"); f:close()
        -- Later names newer, so mtime alone would pick the last one.
        uv.fs_utime(p, 1000 + i, 1000 + i)
    end
    return root, out
end

local function ctx(root)
    return { workspace_root = root, path = "proj", tool_data = { hdc = "/usr/bin/hdc" },
        config_info = { product = "default", target = "default", module_name = "entry" } }
end

describe("harmony unsigned HAP", function()
    it("resolve_artifact prefers the signed HAP over a newer unsigned one", function()
        local root, out = mkproject({ "entry-default-signed.hap", "entry-default-unsigned.hap" })
        assert.equals(out .. "/entry-default-signed.hap", harmony.resolve_artifact(ctx(root), "default"))
    end)

    it("device_install refuses an unsigned HAP without running hdc install", function()
        local root, out = mkproject({ "entry-default-unsigned.hap" })
        local artifact = harmony.resolve_artifact(ctx(root), "default")
        assert.equals(out .. "/entry-default-unsigned.hap", artifact)
        local spec = harmony.device_install({ hdc = "/usr/bin/hdc" }, "SERIAL", artifact)
        assert.is_nil(vim.tbl_contains(spec.args, "install") or nil)
        local err = spec.check_output({ "Ver: 3.1.0a" })
        assert.is_not_nil(err)
        assert.is_truthy(err:find("the HAP is unsigned", 1, true))
        assert.is_truthy(err:find(root:gsub("\\", "/") .. "/proj/build-profile.json5 has no signingConfigs", 1, true))
        assert.is_truthy(err:find("Signing Configs", 1, true))
    end)

    it("device_install installs a signed HAP", function()
        local spec = harmony.device_install({ hdc = "/usr/bin/hdc" }, "SERIAL", "/p/entry/build/default/outputs/default/entry-default-signed.hap")
        assert.is_true(vim.tbl_contains(spec.args, "install"))
        assert.is_nil(spec.check_output({ "install bundle successfully." }))
    end)
end)
