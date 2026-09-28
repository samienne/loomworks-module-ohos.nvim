--- Tests for the ohos SDK provider's cmake capabilities.
---
--- The SDK bundles ninja next to its cmake
--- (`native/build-tools/cmake/bin/ninja`). Kits must pin it via
--- `-DCMAKE_MAKE_PROGRAM` so configure uses the SDK's cmake+ninja
--- pairing instead of whatever ninja is first on PATH. When the bundled
--- ninja is absent, no pin is emitted (PATH fallback, prior behavior).

local ohos = require("loomworks.sdks.ohos")

local is_win = vim.fn.has("win32") == 1
local exe = is_win and ".exe" or ""

local function touch(path)
    vim.fn.mkdir(vim.fs.dirname(path), "p")
    local f = assert(io.open(path, "w"))
    f:write("")
    f:close()
end

--- Build a fake DevEco layout; returns its forward-slash root.
local function fake_sdk(opts)
    local root = vim.fn.tempname():gsub("\\", "/")
    local native = root .. "/sdk/default/openharmony/native"
    touch(native .. "/build/cmake/ohos.toolchain.cmake")
    touch(root .. "/sdk/default/hms/native/build/cmake/hmos.toolchain.cmake")
    touch(native .. "/build-tools/cmake/bin/cmake" .. exe)
    if opts.ninja then
        touch(native .. "/build-tools/cmake/bin/ninja" .. exe)
    end
    return root, native
end

local function all_arch_args(caps)
    local out = {}
    for _, platform in ipairs(caps.platforms) do
        for _, arch in ipairs(platform.archs) do
            out[#out + 1] = {
                label = platform.name .. "/" .. arch,
                args = platform.arch_args[arch],
            }
        end
    end
    return out
end

local function make_program_of(args)
    for _, a in ipairs(args) do
        local v = a:match("^%-DCMAKE_MAKE_PROGRAM=(.*)$")
        if v then return v end
    end
    return nil
end

describe("ohos SDK cmake capabilities", function()
    local roots = {}
    after_each(function()
        for _, r in ipairs(roots) do vim.fn.delete(r, "rf") end
        roots = {}
    end)

    it("pins the SDK-bundled ninja on every platform/arch", function()
        local root, native = fake_sdk({ ninja = true })
        roots[#roots + 1] = root
        local sdk = ohos.create_sdk("ohos-test", root, "5.0.0")
        local caps = ohos.query_capabilities(sdk, "cmake")
        assert.is_not_nil(caps)
        assert.equals(2, #caps.platforms, "HarmonyOS + OpenHarmony")

        local expected = native .. "/build-tools/cmake/bin/ninja" .. exe
        local entries = all_arch_args(caps)
        assert.equals(3, #entries)
        for _, e in ipairs(entries) do
            assert.equals(expected, make_program_of(e.args),
                e.label .. " must pin the SDK ninja")
        end
        assert.is_nil(expected:find("\\", 1, true), "forward-slash path")
        assert.equals(native .. "/build-tools/cmake/bin/cmake" .. exe, caps.cmake_path)
    end)

    it("flows through core's kits_from_sdk into kit extra_args", function()
        local root, native = fake_sdk({ ninja = true })
        roots[#roots + 1] = root
        local sdk = ohos.create_sdk("ohos-test", root, "5.0.0")
        local caps = ohos.query_capabilities(sdk, "cmake")
        local cmake = require("loomworks.modules.cmake")
        local kits = cmake.kits_from_sdk(caps, sdk)
        assert.equals(3, #kits)
        local expected = native .. "/build-tools/cmake/bin/ninja" .. exe
        for _, k in ipairs(kits) do
            assert.equals("Ninja", k.tool_data.generator)
            assert.equals(expected, make_program_of(k.tool_data.extra_args))
        end
    end)

    it("does not pin a make program when the SDK has no bundled ninja", function()
        local root = fake_sdk({ ninja = false })
        roots[#roots + 1] = root
        local sdk = ohos.create_sdk("ohos-test", root, "5.0.0")
        local caps = ohos.query_capabilities(sdk, "cmake")
        for _, e in ipairs(all_arch_args(caps)) do
            assert.is_nil(make_program_of(e.args), e.label)
            -- Existing args are untouched.
            assert.equals("-DOHOS_ARCH=" .. e.label:match("/(.*)$"), e.args[1])
        end
    end)
end)
