--- Tests for harmony.list_devices (spec/modules/harmony.md §6.1): it
--- delegates to the ohos runner's list spec + parser and never falls back
--- to an hdc found on PATH. jobstart is stubbed — no hdc is ever run.

local harmony = require("loomworks.modules.harmony")

describe("harmony.list_devices", function()
    local orig_jobstart, orig_exepath, orig_notify
    local started

    before_each(function()
        orig_jobstart = vim.fn.jobstart
        orig_exepath = vim.fn.exepath
        orig_notify = vim.notify
        started = {}
        vim.notify = function() end
        vim.fn.exepath = function() return "/usr/bin/hdc-on-path" end
    end)

    after_each(function()
        vim.fn.jobstart = orig_jobstart
        vim.fn.exepath = orig_exepath
        vim.notify = orig_notify
    end)

    local function stub_jobstart(stdout, code)
        vim.fn.jobstart = function(argv, opts)
            started[#started + 1] = argv
            opts.on_stdout(1, stdout)
            opts.on_exit(1, code or 0)
            return 1
        end
    end

    it("runs the SDK hdc with `list targets -v` and parses via the runner", function()
        stub_jobstart({ "S1\tUSB\tConnected\tlocalhost\r", "S2\tTCP\tOffline\tlocalhost", "" })
        local got
        harmony.list_devices({ hdc = "/sdk/toolchains/hdc" }, function(d) got = d end)
        assert.same({ { "/sdk/toolchains/hdc", "list", "targets", "-v" } }, started)
        assert.equals(2, #got)
        assert.equals("S1", got[1].serial)
        assert.equals("online", got[1].state)
        assert.equals("offline", got[2].state)
    end)

    it("reports no devices for [Empty]", function()
        stub_jobstart({ "[Empty]", "" })
        local got
        harmony.list_devices({ hdc = "/sdk/toolchains/hdc" }, function(d) got = d end)
        assert.same({}, got)
    end)

    it("has no PATH fallback without an SDK hdc", function()
        stub_jobstart({ "S1" })
        local got
        harmony.list_devices({}, function(d) got = d end)
        assert.same({}, got)
        assert.equals(0, #started, "hdc from PATH must not be run")
        harmony.list_devices(nil, function(d) got = d end)
        assert.equals(0, #started)
    end)
end)
