--- Structural conformance to loomworks core's module-interface
--- contract. These tests don't invoke any device, build, or LSP code
--- — they just shape-check the harmony module table. The point is
--- to break loud when the contract drifts on the core side:
---
---   * a new required field is added to the module interface, and
---     harmony forgets it
---   * an existing capability flag (has_devices, has_keyed_tools)
---     implies new methods that didn't exist when this plugin was
---     last touched
---   * a return type changes (progress_parser was the canary — it
---     started returning a function instead of a string and wedged
---     task start with a string-concat error)
---
--- If a check here fails on a loomworks core upgrade, the plugin's
--- users get a clean test signal instead of a runtime crash at
--- build/launch time.

local harmony = require("loomworks.modules.harmony")

describe("harmony module table — required fields", function()
    it("declares M.id = 'harmony'", function()
        assert.equals("harmony", harmony.id)
    end)

    it("api_version matches loomworks core's MODULE version", function()
        local API = require("loomworks.api_versions")
        assert.equals(API.module, harmony.api_version,
            "harmony declares api_version=" .. tostring(harmony.api_version)
                .. " but loomworks core expects " .. tostring(API.module)
                .. ". If core's API.module bumped, update harmony's "
                .. "declaration and adapt to the new contract; "
                .. "loomworks.modules.get() refuses to load on mismatch.")
    end)

    it("declares M.languages as a non-empty string array", function()
        assert.is_table(harmony.languages)
        assert.is_true(#harmony.languages > 0,
            "languages must list at least one language for DAP routing")
        for i, lang in ipairs(harmony.languages) do
            assert.is_string(lang,
                "languages[" .. i .. "] must be a string; got " .. type(lang))
        end
    end)

    it("declares capability flags as booleans (or absent)", function()
        for _, flag in ipairs({ "has_keyed_tools", "has_options", "has_devices" }) do
            if harmony[flag] ~= nil then
                assert.is_boolean(harmony[flag],
                    "harmony." .. flag .. " must be a boolean if set; got "
                        .. type(harmony[flag]))
            end
        end
    end)
end)

describe("harmony module table — required methods", function()
    --- Every module must implement these.
    local REQUIRED = {
        "detect", "info", "map_variant", "progress_parser",
    }

    for _, name in ipairs(REQUIRED) do
        it(name .. " is a function", function()
            assert.is_function(harmony[name],
                "harmony." .. name .. " must be defined as a function")
        end)
    end
end)

describe("harmony module table — progress_parser contract", function()
    --- The bug-trip wire: core looks up
    --- `loomworks.progress.<parser_name>` via the string returned
    --- here. Returning the parser function itself (the
    --- shell-ninja regression) makes core string-concat a function
    --- value inside overseer's task-start path, which wedges the
    --- task in PENDING without an obvious error path to the user.
    it("returns a non-empty string", function()
        local name = harmony.progress_parser()
        assert.is_string(name)
        assert.is_true(#name > 0,
            "progress_parser() returned an empty string")
    end)

    it("returns a name that resolves to a parser function", function()
        local name = harmony.progress_parser()
        local ok, parser = pcall(require, "loomworks.progress." .. name)
        assert.is_true(ok,
            "loomworks.progress." .. name .. " not requireable: "
                .. tostring(parser))
        assert.is_function(parser,
            "loomworks.progress." .. name .. " must export a parser function")
    end)
end)

describe("harmony module table — device interface (has_devices = true)", function()
    --- When a module declares has_devices = true, loomworks core
    --- expects the full device interface to be present. Missing any
    --- of these manifests as a nil-call inside session_tracker.lua
    --- mid-launch, which is hard to diagnose from a user's
    --- standpoint.
    local DEVICE_METHODS = {
        "list_devices",   -- query connected devices
        "device_targets", -- enumerate per-config deploy targets
        "device_install", -- install / push artifact onto device
        "device_launch",  -- start the app on device
        "device_log",     -- compose the on-device log stream cmd
    }

    it("has_devices is true (test prerequisite)", function()
        assert.is_true(harmony.has_devices,
            "this group's premise is that harmony reports devices")
    end)

    for _, m in ipairs(DEVICE_METHODS) do
        it(m .. " is a function", function()
            assert.is_function(harmony[m],
                "has_devices = true requires harmony." .. m
                    .. " to be defined")
        end)
    end

    it("device_log_options returns { level, strict_pid }", function()
        local opts = harmony.device_log_options({})
        assert.is_table(opts)
        assert.is_string(opts.level)
        assert.is_boolean(opts.strict_pid)
    end)
end)

describe("harmony module table — setup contract", function()
    --- The plugin wrapper's setup({...}) forwards into M.setup. If
    --- the wrapper drifts from the module's accepted opts, users
    --- silently get defaults — which is the worst kind of bug
    --- (looks fine until it doesn't).
    it("setup is a function", function()
        assert.is_function(harmony.setup)
    end)

    it("setup(nil) is a no-op (no error, no state change)", function()
        local before = harmony.device_log_options({})
        assert.has_no.errors(function() harmony.setup(nil) end)
        local after = harmony.device_log_options({})
        assert.equals(before.level, after.level)
        assert.equals(before.strict_pid, after.strict_pid)
    end)

    it("setup({}) is a no-op", function()
        local before = harmony.device_log_options({})
        assert.has_no.errors(function() harmony.setup({}) end)
        local after = harmony.device_log_options({})
        assert.equals(before.level, after.level)
        assert.equals(before.strict_pid, after.strict_pid)
    end)

    it("setup with an invalid device_log_level warns and ignores", function()
        local before_level = harmony.device_log_options({}).level
        -- vim.notify is the warning channel; we don't need to capture
        -- it here — the assertion is that the level didn't change.
        assert.has_no.errors(function()
            harmony.setup({ device_log_level = "Q" })
        end)
        assert.equals(before_level,
            harmony.device_log_options({}).level,
            "invalid level must not alter the stored value")
    end)
end)
