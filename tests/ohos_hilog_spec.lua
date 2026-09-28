--- Tests for hilog.lua (spec/modules/harmony.md §6.5) and the runner's
--- log session (spec/sdks/ohos.md §8.5; core §18.13). Pure — no device.

local hilog = require("loomworks-module-ohos.hilog")
local runner_mod = require("loomworks-module-ohos.runner")

local L3 = "09-28 10:11:12.345  4242  4250 W A03D00/LumeSceneAPITestRunner/Scene: loaded 3 plugins"
local L2 = "09-28 10:11:12.346  4242  4251 E C01406/render: GPU lost"
local OTHER = "09-28 10:11:12.347  1111  1111 I A00000/com.other/Other: noise"

describe("hilog.sanitize", function()
    it("strips BOM, ANSI, CSI remnants, controls and CR", function()
        assert.equals("hello [a92ab178] x", hilog.sanitize("\xEF\xBB\xBF\27[31mhello\27[0m [a92ab178] [41;155Hx\7\r"))
    end)
end)

describe("hilog.parse_line", function()
    it("parses the DOMAIN/PROC/TAG form", function()
        local r = hilog.parse_line(L3 .. "\r")
        assert.same({
            time = "09-28 10:11:12.345", pid = 4242, tid = 4250, level = "W",
            domain = "A03D00", proc = "LumeSceneAPITestRunner", tag = "Scene",
            msg = "loaded 3 plugins",
        }, r)
    end)

    it("parses the DOMAIN/TAG form with proc = nil", function()
        local r = hilog.parse_line(L2)
        assert.equals("C01406", r.domain)
        assert.is_nil(r.proc)
        assert.equals("render", r.tag)
        assert.equals("GPU lost", r.msg)
        assert.equals("E", r.level)
    end)

    it("keeps colons in the message", function()
        local r = hilog.parse_line("09-28 10:11:12.345 1 2 I D/p/T: a: b: c")
        assert.equals("a: b: c", r.msg)
    end)

    it("a proc-less line whose message holds slashes stays DOMAIN/TAG", function()
        local r = hilog.parse_line("09-28 10:11:12.345  4242  4242 I C03F00/MUSL-LDSO: load /system/lib/x.so: ok")
        assert.is_nil(r.proc)
        assert.equals("MUSL-LDSO", r.tag)
        assert.equals("load /system/lib/x.so: ok", r.msg)
        local r2 = hilog.parse_line("09-28 10:11:12.345  4242  4242 I A03D00/api_unit_te/LumeTag: path /a/b: c")
        assert.equals("api_unit_te", r2.proc)
        assert.equals("LumeTag", r2.tag)
        assert.equals("path /a/b: c", r2.msg)
    end)

    it("returns nil + cleaned text for unparseable lines", function()
        local r, clean = hilog.parse_line("[Fail]ExecuteCommand need connect-key?\r")
        assert.is_nil(r)
        assert.equals("[Fail]ExecuteCommand need connect-key?", clean)
    end)
end)

describe("hilog.proc_matches", function()
    it("matches exact, sub-process and left-truncated proc", function()
        assert.is_true(hilog.proc_matches("com.example.app", "com.example.app"))
        assert.is_true(hilog.proc_matches("com.example.app:render", "com.example.app"))
        assert.is_true(hilog.proc_matches("com.example.app.worker", "com.example.app"))
        assert.is_true(hilog.proc_matches("ceneAPITestRunner", "LumeSceneAPITestRunner"))
        assert.is_false(hilog.proc_matches("com.example.apple", "com.example.app"))
        assert.is_false(hilog.proc_matches(nil, "x"))
        assert.is_false(hilog.proc_matches("x", ""))
    end)

    it("matches a right-truncated proc column and path names (device-seen)", function()
        assert.is_true(hilog.proc_matches("api_unit_te", "api_unit_tests"))
        assert.is_true(hilog.proc_matches("api_unit_te", "/data/local/tmp/.device-staging/w/u/api_unit_tests"))
        assert.is_true(hilog.proc_matches("api_unit_tests", "/d/api_unit_tests"))
        assert.is_false(hilog.proc_matches("api_u", "api_unit_tests"), "too short to trust")
        assert.is_false(hilog.proc_matches("api_unit_tf", "api_unit_tests"))
        assert.is_false(hilog.proc_matches("api_unit_tests_x", "api_unit_tests"))
    end)
end)

describe("hilog.make_prefilter", function()
    local mine = hilog.parse_line(L3)          -- pid 4242, proc matches
    local mine_noproc = hilog.parse_line(L2)   -- pid 4242, no proc
    local other = hilog.parse_line(OTHER)
    local helper = hilog.parse_line("09-28 10:11:12.3 5000 5000 I D/LumeSceneAPITestRunner/T: helper")
    local raw = { raw = "garbage" }
    local name = "LumeSceneAPITestRunner"

    it("strict: pid AND proc", function()
        local f = hilog.make_prefilter({ mode = "strict", pid = 4242, name = name })
        assert.is_true(f(mine))
        assert.is_false(f(mine_noproc))
        assert.is_false(f(helper))
        assert.is_false(f(other))
        assert.is_true(f(raw))
    end)

    it("strict degrades to whichever criterion is known", function()
        assert.is_true(hilog.make_prefilter({ mode = "strict", pid = 4242 })(mine_noproc))
        assert.is_true(hilog.make_prefilter({ mode = "strict", name = name })(helper))
        assert.is_false(hilog.make_prefilter({ mode = "strict" })(mine))
    end)

    it("app-related: pid OR proc", function()
        local f = hilog.make_prefilter({ mode = "app-related", pid = 4242, name = name })
        assert.is_true(f(mine))
        assert.is_true(f(mine_noproc))
        assert.is_true(f(helper))
        assert.is_false(f(other))
    end)

    it("pid: pid only; degrades to proc without a pid", function()
        local f = hilog.make_prefilter({ mode = "pid", pid = 4242, name = name })
        assert.is_true(f(mine))
        assert.is_true(f(mine_noproc))
        assert.is_false(f(helper))
        assert.is_false(f(other))
        assert.is_true(f(raw))
        assert.is_true(hilog.make_prefilter({ mode = "pid", name = name })(helper))
        assert.is_false(hilog.make_prefilter({ mode = "pid" })(mine))
    end)

    it("real native-program shapes: truncated proc and proc-less system domains", function()
        local lines = {
            "09-28 14:02:11.101  8811  8811 I C03F00/MUSL-LDSO: dlopen libfoo.so",
            "09-28 14:02:11.102  8811  8813 I C01300/PARAM_WATCHER: watcher started",
            "09-28 14:02:11.200  8811  8811 E A03D00/api_unit_te/LumeScene: assertion failed",
            "09-28 14:02:11.300  1234  1234 I A03D00/com.other.app/X: noise",
        }
        local rec = {}
        for i, l in ipairs(lines) do rec[i] = assert(hilog.parse_line(l)) end
        local prog = "/data/local/tmp/.device-staging/ws/u/test/unittest/api_unit_tests"
        for _, mode in ipairs({ "pid", "app-related" }) do
            local f = hilog.make_prefilter({ mode = mode, pid = 8811, name = prog })
            assert.is_true(f(rec[1]), mode)
            assert.is_true(f(rec[2]), mode)
            assert.is_true(f(rec[3]), mode)
            assert.is_false(f(rec[4]), mode)
        end
        -- Name-only (no pid known): the truncated proc still matches.
        assert.is_true(hilog.make_prefilter({ mode = "app-related", name = prog })(rec[3]))
        assert.is_true(hilog.make_prefilter({ mode = "strict", pid = 8811, name = prog })(rec[3]))
        -- Soft filter: a full program name matches the truncated column.
        assert.is_true(hilog.match_filter({ proc = "api_unit_tests" }, rec[3]))
        assert.is_true(hilog.match_filter({ proc = "unit" }, rec[3]))
        assert.is_false(hilog.match_filter({ proc = "api_unit_tests" }, rec[4]))
    end)

    it("all: everything", function()
        assert.is_true(hilog.make_prefilter({ mode = "all" })(other))
    end)

    it("accepts bundle as an alias of name", function()
        assert.is_true(hilog.make_prefilter({ mode = "strict", bundle = name })(helper))
    end)
end)

describe("hilog.match_filter", function()
    local w = hilog.parse_line(L3)
    local e = hilog.parse_line(L2)
    local rw = hilog.render(w)

    it("renders compactly", function()
        assert.equals("10:11:12.345 4242 W LumeSceneAPITestRunner/Scene: loaded 3 plugins", rw)
        assert.equals("10:11:12.346 4242 E render: GPU lost", hilog.render(e))
        assert.equals("[UNPARSED] x", hilog.render({ raw = "x" }))
    end)

    it("filters by minimum level", function()
        assert.is_true(hilog.match_filter({ level = "W" }, w, rw))
        assert.is_false(hilog.match_filter({ level = "E" }, w, rw))
        assert.is_true(hilog.match_filter({ level = "E" }, e))
    end)

    it("filters by tag, proc and pid (substring / exact)", function()
        assert.is_true(hilog.match_filter({ tag = "Sce" }, w))
        assert.is_false(hilog.match_filter({ tag = "Net" }, w))
        assert.is_true(hilog.match_filter({ proc = "APITest" }, w))
        assert.is_false(hilog.match_filter({ proc = "APITest" }, e), "no proc column")
        assert.is_false(hilog.match_filter({ pid = 1 }, w))
    end)

    it("grep and exclude match the rendered line; AND over all fields", function()
        assert.is_true(hilog.match_filter({ grep = "plugins$" }, w, rw))
        assert.is_false(hilog.match_filter({ grep = "FAILED" }, w, rw))
        assert.is_false(hilog.match_filter({ exclude = "Scene:" }, w, rw))
        assert.is_false(hilog.match_filter({ level = "W", tag = "Scene", grep = "nope" }, w, rw))
        assert.is_true(hilog.match_filter({ level = "W", tag = "Scene", grep = "loaded" }, w, rw))
    end)

    it("hides raw records only by a pattern", function()
        local raw = { raw = "hdc: something odd" }
        assert.is_true(hilog.match_filter({ level = "F", tag = "x" }, raw))
        assert.is_false(hilog.match_filter({ grep = "FAILED" }, raw))
        assert.is_false(hilog.match_filter({ exclude = "odd" }, raw))
    end)
end)

describe("hilog.resolve_options", function()
    it("native defaults: stdout live, hilog on failure, pid prefilter, level W, tail 30", function()
        local o = assert(hilog.resolve_options(nil, "native"))
        assert.equals("stdout", o.show)
        assert.equals("pid", o.prefilter)
        assert.equals("W", o.level)
        assert.equals(30, o.tail)
        assert.same({ program = "live", log = "on_failure", tail = 30 }, o.show_policy)
    end)

    it("native: show=hilog / both switch policy and default level to I", function()
        local h = assert(hilog.resolve_options({ show = "hilog" }, "native"))
        assert.same({ program = "off", log = "live", tail = 30 }, h.show_policy)
        assert.equals("I", h.level)
        local b = assert(hilog.resolve_options({ show = "both" }, "native"))
        assert.same({ program = "live", log = "live", tail = 30 }, b.show_policy)
        assert.equals("I", b.level)
    end)

    it("explicit level wins and is case-insensitive", function()
        assert.equals("D", assert(hilog.resolve_options({ level = "d" }, "native")).level)
        assert.equals("E", assert(hilog.resolve_options({ show = "both", level = "E" }, "native")).level)
    end)

    it("hap defaults: hilog live, strict, level I", function()
        local o = assert(hilog.resolve_options({}, "hap"))
        assert.equals("hilog", o.show)
        assert.equals("strict", o.prefilter)
        assert.equals("I", o.level)
        assert.same({ program = "off", log = "live", tail = 30 }, o.show_policy)
    end)

    it("accepts prefilter = pid for either target type", function()
        assert.equals("pid", assert(hilog.resolve_options({ prefilter = "pid" }, "native")).prefilter)
        assert.equals("pid", assert(hilog.resolve_options({ prefilter = "pid" }, "hap")).prefilter)
        local _, err = hilog.resolve_options({ prefilter = "loose" }, "native")
        assert.is_truthy(err:find("one of pid, strict, app-related, all", 1, true), err)
    end)

    it("hap rejects show values other than hilog", function()
        local o, err = hilog.resolve_options({ show = "stdout" }, "hap")
        assert.is_nil(o)
        assert.is_truthy(err:find("show", 1, true))
    end)

    it("accepts CLI strings for every key", function()
        local o = assert(hilog.resolve_options({
            show = "both", prefilter = "strict", level = "I", tag = "Scene",
            proc = "Lume", grep = "FAIL", exclude = "^%s*$", tail = "50",
        }, "native"))
        assert.equals(50, o.tail)
        assert.equals("Scene", o.tag)
        assert.equals("FAIL", o.grep)
        assert.same({ level = "I", tag = "Scene", proc = "Lume", grep = "FAIL", exclude = "^%s*$" },
            hilog.filter_from_options(o))
    end)

    it("rejects unknown keys, listing the known ones", function()
        local o, err = hilog.resolve_options({ lvl = "W" }, "native")
        assert.is_nil(o)
        assert.equals("device_log: unknown option 'lvl' (known: show, prefilter, level, tag, proc, grep, exclude, tail)", err)
    end)

    it("rejects bad values, naming the option", function()
        local cases = {
            { show = "all" }, { prefilter = "loose" }, { level = "X" }, { level = 3 },
            { tail = "-1" }, { tail = "ten" }, { tail = 1.5 }, { grep = "[" }, { exclude = "%" },
            { tag = {} },
        }
        for _, c in ipairs(cases) do
            local key = next(c)
            local o, err = hilog.resolve_options(c, "native")
            assert.is_nil(o, vim.inspect(c))
            assert.is_truthy(err:find("'" .. key .. "'", 1, true), err)
        end
    end)

    it("treats empty tag/proc/grep as unset", function()
        local o = assert(hilog.resolve_options({ tag = "", proc = "", grep = "" }, "native"))
        assert.is_nil(o.tag)
        assert.is_nil(o.proc)
        assert.is_nil(o.grep)
    end)
end)

describe("ohos runner log_session", function()
    local HDC = "/sdk/hdc"
    local r = runner_mod.new({ hdc = HDC, platforms = { "ohos-aarch64" } })
    local program = { path = "/data/local/tmp/.device-staging/w/u/LumeSceneAPITestRunner", name = "LumeSceneAPITestRunner" }

    it("returns nil, err for invalid options", function()
        local s, err = r.log_session("S1", { bogus = "1" }, program)
        assert.is_nil(s)
        assert.is_truthy(err:find("unknown option 'bogus'", 1, true))
    end)

    it("has the §18.13 Session shape", function()
        local s = assert(r.log_session("S1", nil, program))
        assert.same({ cmd = HDC, args = { "-t", "S1", "shell", "hilog -r" } },
            { cmd = s.clear.cmd, args = s.clear.args })
        assert.is_function(s.stream)
        assert.is_function(s.receive)
        assert.is_function(s.display)
        assert.same({ program = "live", log = "on_failure", tail = 30 }, s.show)
    end)

    it("streams with -P only (no -L, -t or -T)", function()
        local s = assert(r.log_session("S1", { level = "D", tag = "Scene" }, program))
        assert.same({ "-t", "S1", "shell", "hilog -P 4242" }, s.stream(4242).args)
        assert.same({ "-t", "S1", "shell", "hilog" }, s.stream(nil).args)
        assert.same({ "-t", "S1", "shell", "hilog" }, s.stream("1; reboot").args)
    end)

    it("receive applies the prefilter with the streamed pid, keeps raw lines", function()
        local s = assert(r.log_session("S1", {}, program))   -- pid
        s.stream(4242)
        assert.equals(L3, s.receive(L3 .. "\r"))
        assert.equals(L2, s.receive(L2))                    -- pid match, no proc
        assert.is_nil(s.receive(OTHER))
        assert.equals("hdc: device offline", s.receive("\27[0mhdc: device offline\r"))
        assert.is_nil(s.receive("\r"))
    end)

    it("strict prefilter drops pid-only matches", function()
        local s = assert(r.log_session("S1", { prefilter = "strict" }, program))
        s.stream(4242)
        assert.equals(L3, s.receive(L3))
        assert.is_nil(s.receive(L2))
    end)

    it("display soft-filters and renders compactly", function()
        local s = assert(r.log_session("S1", {}, program))   -- level W
        assert.equals("10:11:12.345 4242 W LumeSceneAPITestRunner/Scene: loaded 3 plugins", s.display(L3))
        assert.is_nil(s.display("09-28 10:11:12.345 4242 4250 I A/LumeSceneAPITestRunner/Scene: info"))
        assert.equals("raw text", s.display("raw text"))
        local g = assert(r.log_session("S1", { level = "D", grep = "GPU" }, program))
        assert.is_nil(g.display(L3))
        assert.equals("10:11:12.346 4242 E render: GPU lost", g.display(L2))
        assert.is_nil(g.display("raw text"))
    end)
end)
