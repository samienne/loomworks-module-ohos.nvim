--- Integration check: with this plugin on the runtime path, loomworks
--- core's discovery walks should find the harmony module, the ohos SDK
--- provider, and the hvigor progress parser at the expected Lua
--- module paths. These tests are cheap (no I/O, no workspace setup)
--- but they guard against the silent-breakage failure modes:
---
---   * file at lua/loomworks/modules/harmony.lua gets renamed
---   * harmony module table loses its `id` field (`M.get` rejects
---     module tables without `id` and returns nil — discovery still
---     looks fine to `list()` but `get()` silently returns nothing)
---   * sdks/ohos.lua likewise
---   * progress/hvigor.lua moves or gets renamed (causing the harmony
---     module's `progress_parser()` "hvigor" lookup to fail at task
---     start with a string-concat error — the bug pattern that wedged
---     shell-ninja tasks in PENDING)
---
--- If any of these break, the plugin keeps loading without
--- complaining; harmony projects in loomworks.json just go quiet. A
--- failing test here is the loudest possible signal.

describe("harmony module discovery", function()
    it("is listed by loomworks.modules.list()", function()
        local ids = require("loomworks.modules").list()
        local found = false
        for _, id in ipairs(ids) do
            if id == "harmony" then found = true end
        end
        assert.is_true(found,
            "loomworks.modules.list() should include 'harmony'; got: "
                .. vim.inspect(ids))
    end)

    it("resolves via loomworks.modules.get('harmony')", function()
        local mod = require("loomworks.modules").get("harmony")
        assert.is_not_nil(mod, "modules.get('harmony') returned nil")
        assert.equals("harmony", mod.id,
            "harmony module table must expose `M.id = 'harmony'` "
                .. "(M.get() rejects tables without it)")
    end)
end)

describe("ohos SDK provider discovery", function()
    it("is listed by loomworks.sdks.list()", function()
        local ids = require("loomworks.sdks").list()
        local found = false
        for _, id in ipairs(ids) do
            if id == "ohos" then found = true end
        end
        assert.is_true(found,
            "loomworks.sdks.list() should include 'ohos'; got: "
                .. vim.inspect(ids))
    end)

    it("resolves via loomworks.sdks.get('ohos')", function()
        local provider = require("loomworks.sdks").get("ohos")
        assert.is_not_nil(provider, "sdks.get('ohos') returned nil")
        assert.equals("ohos", provider.id,
            "ohos provider table must expose `M.id = 'ohos'` "
                .. "(M.get() rejects tables without it)")
    end)
end)

describe("hvigor progress parser", function()
    --- The harmony module declares `progress_parser() = "hvigor"` —
    --- core looks up `loomworks.progress.hvigor` from this string.
    --- This test isolates the lookup so a file-rename breakage shows
    --- up here instead of mid-build with a string-concat traceback.
    it("is requireable as loomworks.progress.hvigor", function()
        local ok, parser = pcall(require, "loomworks.progress.hvigor")
        assert.is_true(ok,
            "loomworks.progress.hvigor must resolve; got: "
                .. tostring(parser))
        assert.is_function(parser,
            "loomworks.progress.hvigor must be a function (the parser)")
    end)

    it("harmony.progress_parser() returns the string 'hvigor'", function()
        local harmony = require("loomworks.modules.harmony")
        assert.is_function(harmony.progress_parser,
            "harmony must declare progress_parser as a function")
        local name = harmony.progress_parser()
        assert.equals("hvigor", name,
            "progress_parser() must return the registry key string, "
                .. "NOT the parser function itself — returning a "
                .. "function wedges task start with a string-concat "
                .. "error inside overseer.lua")
    end)
end)
