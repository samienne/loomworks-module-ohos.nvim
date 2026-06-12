--- harmony module detection + map_variant tests. Pulled out of
--- loomworks.nvim's modules_detect_spec.lua when the ohos plugin
--- was extracted.

local io_mod = require("loomworks.io")
local uv = vim.uv or vim.loop

local function make_tmpdir()
    local path = vim.fn.tempname()
    vim.fn.mkdir(path, "p")
    return path
end

local function write_raw(path, content)
    local fd = uv.fs_open(path, "w", 438)
    uv.fs_write(fd, content, 0)
    uv.fs_close(fd)
end

describe("harmony module detection", function()
    local tmpdirs = {}

    local function tmpdir()
        local d = make_tmpdir()
        tmpdirs[#tmpdirs + 1] = d
        return d
    end

    after_each(function()
        for _, d in ipairs(tmpdirs) do
            io_mod.rm_rf(d)
        end
        tmpdirs = {}
    end)

    describe("harmony.detect", function()
        local harmony = require("loomworks.modules.harmony")

        it("returns marker for directory with build-profile.json5", function()
            local dir = tmpdir()
            write_raw(dir .. "/build-profile.json5", "{}")

            local result = harmony.detect(dir)
            assert.is_not_nil(result)
            assert.equals("build-profile.json5", result.marker)
        end)

        it("returns nil for empty directory", function()
            local dir = tmpdir()
            assert.is_nil(harmony.detect(dir))
        end)
    end)

    --- Harmony's configs all default to `mode=debug` on the hvigor
    --- side, so `map_variant("debug")` returns the first config and
    --- anything else returns nil. Single-config projects take that
    --- one config regardless of the requested variant type.
    describe("harmony.map_variant", function()
        local harmony = require("loomworks.modules.harmony")

        it("maps debug to the first available config", function()
            assert.equals("default",
                harmony.map_variant("debug", { "default", "other" }))
        end)

        it("returns nil for release", function()
            assert.is_nil(harmony.map_variant("release", { "default", "other" }))
        end)

        it("returns nil for release_debug", function()
            assert.is_nil(harmony.map_variant("release_debug", { "default", "other" }))
        end)

        it("returns the sole config for any variant (single-config fallback)", function()
            assert.equals("only", harmony.map_variant("debug", { "only" }))
            assert.equals("only", harmony.map_variant("release", { "only" }))
        end)
    end)

    describe("modules.detect_all_types", function()
        local modules = require("loomworks.modules")

        it("detects harmony project", function()
            local dir = tmpdir()
            write_raw(dir .. "/build-profile.json5", "{}")

            local results = modules.detect_all_types(dir)
            -- The discovery walks rtp; this test only asserts that
            -- harmony is among the detected types, since other
            -- modules sharing the same dir would also match.
            local found = false
            for _, r in ipairs(results) do
                if r.type == "harmony" then found = true end
            end
            assert.is_true(found, "harmony should be detected for build-profile.json5")
        end)
    end)

    describe("loomworks.languages with harmony", function()
        package.loaded["loomworks.languages"] = nil
        local languages = require("loomworks.languages")

        it("includes arkts in the tracked set", function()
            local set = languages.tracked_set()
            assert.is_true(set["arkts"])
        end)

        it("filter preserves arkts", function()
            local out = languages.filter({ "c++", "arkts", "rc" })
            assert.same({ "c++", "arkts" }, out)
        end)
    end)
end)
