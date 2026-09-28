--- Tests for the shared hdc helper (spec/sdks/ohos.md §8.1): device-shell
--- quoting, argv building, local path rendering, [Fail] detection, and
--- `list targets` / digest parsing. Pure functions — no process spawned.

local hdc = require("loomworks-module-ohos.hdc")

--- Run `sh -c <script>` on the host (POSIX sh from Git Bash on Windows)
--- and return stdout lines — used to prove quoted words round-trip
--- byte-for-byte through a real POSIX shell. Skipped when no sh exists.
local function sh_available()
    return vim.fn.executable("sh") == 1
end

local function run_sh(script)
    local out = vim.fn.systemlist({ "sh", "-c", script })
    for i, l in ipairs(out) do out[i] = l:gsub("\r$", "") end
    return out, vim.v.shell_error
end

describe("hdc.quote", function()
    it("leaves safe words bare", function()
        assert.equals("hilog", hdc.quote("hilog"))
        assert.equals("-P", hdc.quote("-P"))
        assert.equals("/data/local/tmp/a.b_c-1", hdc.quote("/data/local/tmp/a.b_c-1"))
        assert.equals("1234", hdc.quote(1234))
    end)

    it("quotes the empty string", function()
        assert.equals("''", hdc.quote(""))
    end)

    it("quotes words with spaces", function()
        assert.equals("'one arg'", hdc.quote("one arg"))
    end)

    it("renders embedded single quotes as '\\''", function()
        assert.equals("'it'\\''s'", hdc.quote("it's"))
        assert.equals("''\\'''", hdc.quote("'"))
    end)

    it("never leaves shell metacharacters bare", function()
        for _, s in ipairs({ "a;b", "$(x)", "`x`", "a|b", "a&b", "*", "a>b",
            "a\"b", "a\\b", "~", "A=B", "a b", "#x", "!x", "{x}", "(x)", "a\tb" }) do
            local q = hdc.quote(s)
            assert.equals("'", q:sub(1, 1), "quoted: " .. s)
        end
    end)

    it("refuses NUL and line breaks", function()
        assert.has_error(function() hdc.quote("a\nb") end)
        assert.has_error(function() hdc.quote("a\rb") end)
        assert.has_error(function() hdc.quote("a\0b") end)
    end)

    it("round-trips hostile arguments through a real POSIX sh", function()
        if not sh_available() then
            pending("no sh on PATH")
            return
        end
        local cases = {
            "plain", "one arg", "it's", "'", "''", "\"double\"", "mixed 'single' and \"double\"",
            "$HOME", "$(echo pwned)", "`echo pwned`", "back\\slash", "trailing\\",
            "a;b", "a && b", "*", "~", "A=B", "", "  spaced  ", "tab\there", "%PATH%",
            "!bang", "#hash", "{a,b}", "[ab]", "é ü 中",
        }
        local words = { "printf", "[%s]\\n" }
        vim.list_extend(words, cases)
        -- `printf '[%s]\n' <args...>` prints each argument on its own line.
        local out, rc = run_sh(hdc.join(words))
        assert.equals(0, rc)
        assert.equals(#cases, #out)
        for i, c in ipairs(cases) do
            assert.equals("[" .. c .. "]", out[i], "case " .. i)
        end
    end)
end)

describe("hdc.argv", function()
    it("prefixes -t <serial>", function()
        assert.same({ "-t", "S1", "file", "send", "a", "b" },
            hdc.argv("S1", "file", "send", "a", "b"))
    end)

    it("omits -t for a nil serial", function()
        assert.same({ "list", "targets" }, hdc.argv(nil, "list", "targets"))
    end)

    it("shell_words renders the device command as ONE element", function()
        local args = hdc.shell_words("S1", { "ls", "-1", "/data/x y" })
        assert.same({ "-t", "S1", "shell", "ls -1 '/data/x y'" }, args)
    end)
end)

describe("hdc.local_path", function()
    it("uses backslashes on Windows", function()
        assert.equals("C:\\b\\x.so", hdc.local_path("C:/b/x.so", true))
    end)

    it("leaves POSIX hosts unchanged", function()
        assert.equals("/b/x.so", hdc.local_path("/b/x.so", false))
    end)
end)

describe("hdc.check_output", function()
    it("is nil on success output", function()
        assert.is_nil(hdc.check_output({ "FileTransfer finish, Size:10, File count = 1, time:3ms rate:3.3kB/s" }))
        assert.is_nil(hdc.check_output({}))
        assert.is_nil(hdc.check_output(nil))
    end)

    it("detects [Fail] with exit 0", function()
        local err = hdc.check_output({ "[Fail]Error opening file: no such file or directory, path:C:\\x" })
        assert.is_truthy(err and err:find("Error opening file", 1, true))
    end)

    it("detects [Fail] with CRLF endings", function()
        assert.is_not_nil(hdc.check_output({ "[Fail]ExecuteCommand need connect-key?\r" }))
    end)

    it("aggregates code:/error: continuation lines", function()
        local err = hdc.check_output({
            "[INFO]App install path:/x.hap msg:error: failed to install bundle.",
            "code:9568320",
            "error: no signature file.",
        })
        assert.equals("error: failed to install bundle. code:9568320 error: no signature file.", err)
    end)
end)

describe("hdc.check_output / check_connector_output: real hdc shapes", function()
    local REAL = {
        "[Fail]Error opening file: no such file or directory, path:/data/local/tmp/missing.xml",
        "[Fail]Not match target founded, check connect-key please",
        "[Fail]ExecuteCommand need connect-key? please confirm a device by help info",
    }

    it("both checks catch every shape, with or without CR", function()
        for _, l in ipairs(REAL) do
            assert.equals((l:gsub("^%[Fail%]", "")), hdc.check_output({ l }))
            assert.equals((l:gsub("^%[Fail%]", "")), hdc.check_output({ "FileTransfer start", l .. "\r" }))
            assert.equals((l:gsub("^%[Fail%]", "")), hdc.check_connector_output({ l .. "\r" }))
            assert.equals((l:gsub("^%[Fail%]", "")), hdc.check_connector_output({ "some device text", l }))
        end
    end)

    it("the connector check ignores device-side error text", function()
        assert.is_nil(hdc.check_connector_output({ "error: bad input", "Segmentation fault", "" }))
        assert.is_nil(hdc.check_connector_output(nil))
        assert.equals("x", hdc.check_connector_output({ "[F]x" }))
    end)
end)

describe("hdc.parse_targets", function()
    it("ignores [Empty] and blank lines", function()
        assert.same({}, hdc.parse_targets({ "[Empty]", "", "\r" }))
    end)

    it("parses plain one-serial-per-line output", function()
        local d = hdc.parse_targets({ "FMR0223C13000649\r", "127.0.0.1:5555" })
        assert.equals(2, #d)
        assert.equals("FMR0223C13000649", d[1].serial)
        assert.equals("online", d[1].state)
        assert.equals("127.0.0.1:5555", d[2].serial)
    end)

    it("parses verbose output with connection state", function()
        local d = hdc.parse_targets({
            "FMR0223C13000649\t\tUSB\tConnected\tlocalhost\thdc",
            "ABC\tTCP\tOffline\tlocalhost",
        })
        assert.equals(2, #d)
        assert.equals("online", d[1].state)
        assert.equals("USB", d[1].properties.connection)
        assert.equals("offline", d[2].state)
    end)

    it("keeps the first of duplicate serials", function()
        assert.equals(1, #hdc.parse_targets({ "S", "S" }))
    end)
end)

describe("hdc.parse_digest", function()
    it("parses sha256sum and md5sum output and skips errors", function()
        local sha = string.rep("a", 64)
        local md5 = string.rep("B", 32)
        local d = hdc.parse_digest({
            sha .. "  /data/local/tmp/x/a b.so\r",
            md5 .. " */data/local/tmp/x/c",
            "sha256sum: /data/local/tmp/x/missing: No such file or directory",
        })
        assert.equals(sha, d["/data/local/tmp/x/a b.so"])
        assert.equals(string.rep("b", 32), d["/data/local/tmp/x/c"])
        assert.is_nil(d["/data/local/tmp/x/missing"])
    end)
end)
