--- loomworks-module-ohos/hdc.lua — everything this plugin knows about
--- driving `hdc`, the HarmonyOS/OpenHarmony device connector.
---
--- Pure helpers only: argv construction, path rendering, device-shell
--- quoting, and output parsing. Nothing here spawns a process — callers
--- (core, via command specs) execute. Shared by the ohos SDK provider's
--- device runner (spec/sdks/ohos.md §8) and the harmony module's device
--- interface (spec/modules/harmony.md §6).
---
--- Connector facts this file encodes (verified on a device unless noted):
---
---   * `hdc -t <serial> shell <cmd>` — everything after `shell` passed as
---     ONE argv element reaches the device `sh` intact, so a device
---     command is rendered as one element with POSIX single-quote
---     quoting of every device-side word (`M.quote` / `M.join`).
---   * hdc exits 0 whatever happened on the device (failed transfer,
---     rejected install, remote non-zero status) — failures are detected
---     from output (`M.check_output`).
---   * On Windows hdc treats forward-slash LOCAL paths as relative
---     (producing doubled paths) — local paths are rendered with
---     backslashes (`M.local_path`). Device-side paths are POSIX.
---   * `hdc shell` output lines end in CRLF. Core normalizes line endings
---     of every spec it runs; the parsers here still strip a trailing CR
---     so they are correct on raw output too (`M.normalize_line`).
---   * `hdc list targets` prints `[Empty]` when no device is attached.

local M = {}

local is_win = vim.fn.has("win32") == 1

-- ---------------------------------------------------------------------------
-- Lines and paths
-- ---------------------------------------------------------------------------

--- Strip trailing CR / LF from one output line.
--- @param line string
--- @return string
function M.normalize_line(line)
    if type(line) ~= "string" then return "" end
    return (line:gsub("[\r\n]+$", ""))
end

--- Render a host-side path the way hdc needs it: backslashes on Windows
--- (hdc treats a forward-slash path as relative there), unchanged elsewhere.
--- @param path string absolute host path
--- @param win? boolean override host detection (tests)
--- @return string
function M.local_path(path, win)
    if win == nil then win = is_win end
    if win then return (path:gsub("/", "\\")) end
    return path
end

-- ---------------------------------------------------------------------------
-- Device-shell quoting
-- ---------------------------------------------------------------------------

--- Characters that never need quoting in a POSIX sh word. Deliberately
--- excludes `=` (an unquoted leading `A=B` word is an assignment), `~`
--- (tilde expansion), glob characters and every shell metacharacter.
local SAFE_WORD = "^[%w%-%._/:,+@%%]+$"

--- Quote one device-side word for POSIX `sh` so it reaches the program
--- as exactly one argument, byte for byte. Safe words are left bare for
--- readability; everything else is wrapped in single quotes with each
--- embedded `'` rendered as `'\''`. The empty string becomes `''`.
--- Inside single quotes nothing is special — `"`, `$`, `` ` ``, `\`,
--- `;`, `*`, spaces all stay literal.
--- NUL and line breaks are refused by core before any spec is built
--- (core §18.2); they are rejected here too, as a backstop.
--- @param s string
--- @return string
function M.quote(s)
    s = tostring(s)
    if s:find("[%z\r\n]") then
        error("hdc.quote: argument contains NUL or a line break", 2)
    end
    if s:match(SAFE_WORD) then return s end
    return "'" .. s:gsub("'", "'\\''") .. "'"
end

--- Quote each word and join with spaces — one device command line.
--- @param words string[]
--- @return string
function M.join(words)
    local out = {}
    for i, w in ipairs(words) do out[i] = M.quote(w) end
    return table.concat(out, " ")
end

-- ---------------------------------------------------------------------------
-- argv construction
-- ---------------------------------------------------------------------------

--- hdc argv with the device selector: `-t <serial> <rest...>`. A nil
--- serial omits `-t` (hdc then uses its only / default target).
--- @param serial string|nil
--- @param ... string
--- @return string[]
function M.argv(serial, ...)
    local args = {}
    if serial then
        args[1] = "-t"
        args[2] = serial
    end
    for _, a in ipairs({ ... }) do args[#args + 1] = a end
    return args
end

--- hdc argv running one device command: `-t <serial> shell <command>`,
--- where `command` is ONE argv element (already quoted device text).
--- @param serial string
--- @param command string device-side sh command text
--- @return string[]
function M.shell_argv(serial, command)
    return M.argv(serial, "shell", command)
end

--- Convenience: shell argv from a word list (each word quoted).
--- @param serial string
--- @param words string[]
--- @return string[]
function M.shell_words(serial, words)
    return M.shell_argv(serial, M.join(words))
end

-- ---------------------------------------------------------------------------
-- Failure detection (hdc exits 0 on failure)
-- ---------------------------------------------------------------------------

--- Detect an hdc failure from output lines. Failure shapes seen in the
--- wild:
---   * Legacy `[Fail]` / `[F]` markers — hdc prints `[Fail]...` and
---     still exits 0 (file send/recv, shell to a vanished device).
---   * `[INFO]App install path:... msg:error: failed to install
---     bundle. code:9568320 error: no signature file.` — `hdc install`
---     wraps the bundle-manager rejection in its [INFO]-tagged
---     `key:value` log format; the reason lives in the `msg:` field.
---   * Plain `error: ...` lines.
---
--- Each line is `clean()`ed first — a leading log tag like `[INFO]` is
--- stripped and, if a `msg:` field is present, only its value is kept.
--- Failure is a legacy marker on the raw line, or `^error:` on the
--- cleaned line. Adjacent `code:<N>` / `error:` continuation lines are
--- aggregated so the surfaced error reads like DevEco's full reason.
--- (Moved from the harmony module; spec/modules/harmony.md §6.2.)
--- @param lines string[]
--- @return string|nil error message if failure detected
function M.check_output(lines)
    local function clean(line)
        local s = vim.trim(M.normalize_line(line))
        s = s:gsub("^%[%w%w%w+%]%s*", "")
        local idx = s:lower():find("msg:", 1, true)
        if idx then return s:sub(idx + 4) end
        return s
    end

    local function is_failure(raw, cleaned)
        if raw:match("%[Fail%]") or raw:match("^%[F%]") then return true end
        if cleaned:lower():match("^error:") then return true end
        return false
    end

    local function is_continuation(cleaned)
        local lower = cleaned:lower()
        return lower:match("^code:%d") ~= nil or lower:match("^error:") ~= nil
    end

    lines = lines or {}
    local hits = {}
    for i, line in ipairs(lines) do
        local trimmed = vim.trim(M.normalize_line(line))
        if trimmed ~= "" then
            local cleaned = clean(line)
            if is_failure(trimmed, cleaned) then
                hits[#hits + 1] = cleaned
                local j = i + 1
                while j <= #lines do
                    if vim.trim(M.normalize_line(lines[j])) == "" then break end
                    local next_cleaned = clean(lines[j])
                    if not is_continuation(next_cleaned) then break end
                    hits[#hits + 1] = next_cleaned
                    j = j + 1
                end
                break
            end
        end
    end

    if #hits == 0 then return nil end
    return table.concat(hits, " ")
end

-- ---------------------------------------------------------------------------
-- Output parsers
-- ---------------------------------------------------------------------------

--- Parse `hdc list targets [-v]` output into devices.
---
--- Accepts both shapes:
---   * plain:   one serial per line                → state `online`
---   * verbose: `<serial> <conn> <state> <host> ...` (tab/space
---     separated)                                  → `online` iff state
---     is `Connected`; `properties.connection` = conn
--- `[Empty]` (no device) and blank lines are not devices. Duplicate
--- serials keep the first occurrence.
--- @param lines string[]
--- @return { serial: string, display_name: string, state: string, properties: table }[]
function M.parse_targets(lines)
    local devices, seen = {}, {}
    for _, raw in ipairs(lines or {}) do
        local line = vim.trim(M.normalize_line(raw))
        if line ~= "" and not line:match("^%[Empty%]") then
            local fields = vim.split(line, "%s+", { trimempty = true })
            local serial = fields[1]
            if serial and not seen[serial] then
                seen[serial] = true
                local state, props = "online", {}
                if #fields >= 3 then
                    props.connection = fields[2]
                    props.connect_state = fields[3]
                    if fields[4] then props.host = fields[4] end
                    state = (fields[3] == "Connected") and "online" or "offline"
                end
                devices[#devices + 1] = {
                    serial = serial,
                    display_name = serial,
                    state = state,
                    properties = props,
                }
            end
        end
    end
    return devices
end

--- Parse digest output (`sha256sum` / `md5sum` format, GNU or toybox):
--- `<hex>  <path>` or `<hex> *<path>` per line. Lines that don't look
--- like a digest (errors such as `sha256sum: x: No such file`) are
--- skipped, so a missing file is simply absent from the result.
--- @param lines string[]
--- @return table<string, string> path → lowercase hex digest
function M.parse_digest(lines)
    local out = {}
    for _, raw in ipairs(lines or {}) do
        local line = M.normalize_line(raw)
        local hex, path = line:match("^(%x+) [ *](.+)$")
        if hex and (#hex == 64 or #hex == 32 or #hex == 40) then
            out[path] = hex:lower()
        end
    end
    return out
end

return M
