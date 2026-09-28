--- Fake `hdc` for the device end-to-end test (tests/ohos_device_e2e_spec.lua).
---
--- Built into a standalone executable with `luvi <this dir> -o <sdk>/.../hdc[.exe]`
--- so core spawns it exactly like the real connector (absolute path, argv with
--- no host command interpreter). It emulates ONE attached device on the host:
---
---   FAKE_HDC_ROOT     host directory standing in for the device's "/"
---                     (only /data/... is mapped; forward slashes)
---   FAKE_HDC_SHROOT   the same directory as the POSIX sh sees it
---                     (/c/... under Git Bash; equal to ROOT elsewhere)
---   FAKE_HDC_SH       absolute path of a POSIX sh (the "device shell")
---   FAKE_HDC_SERIAL   the device serial (default FAKE0001)
---   FAKE_HDC_HILOG    file of canned hilog lines; `{PID}` is replaced by
---                     the pid given to `hilog -P`
---   FAKE_HDC_CALLS    file every invocation is appended to (one line, argv
---                     joined with " | ") for assertions
---
--- Commands: `list targets [-v]`, `-t S file send L R`, `-t S file recv R L`,
--- `-t S shell hilog -r`, `-t S shell hilog [-P pid]`, `-t S shell <cmd>`
--- (runs `sh -c <cmd>` with every `/data/` rewritten under the root and the
--- root stripped from output again). Like the real hdc it exits 0 whatever
--- happened, reports failures as `[Fail]...` lines, and ends lines in CRLF.

local uv = require("uv")

local argv = { ... }
local function env(n) local v = os.getenv(n); return (v and v ~= "") and v or nil end
local ROOT = (env("FAKE_HDC_ROOT") or "."):gsub("\\", "/"):gsub("/+$", "")
local SHROOT = (env("FAKE_HDC_SHROOT") or ROOT):gsub("/+$", "")
local SH = env("FAKE_HDC_SH") or "/bin/sh"
local SERIAL = env("FAKE_HDC_SERIAL") or "FAKE0001"

local function out(s) io.stdout:write(s, "\r\n") end

do
    local f = env("FAKE_HDC_CALLS") and io.open(env("FAKE_HDC_CALLS"), "ab")
    if f then f:write(table.concat(argv, " | "), "\n"); f:close() end
end

local function host(remote) return ROOT .. remote end

local function copy(src, dst)
    local i = io.open(src, "rb")
    if not i then return nil, "no such file or directory" end
    local data = i:read("*a"); i:close()
    local o = io.open(dst, "wb")
    if not o then return nil, "cannot open destination" end
    o:write(data); o:close()
    return #data
end

local function escape(s) return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) end

local function run_shell(cmd)
    cmd = cmd:gsub("/data/", SHROOT .. "/data/")
    local so, se = uv.new_pipe(false), uv.new_pipe(false)
    local pending_close = 3
    local buf = ""
    local function emit(chunk)
        buf = buf .. chunk
        while true do
            local nl = buf:find("\n", 1, true)
            if not nl then break end
            local line = buf:sub(1, nl - 1):gsub("\r$", "")
            buf = buf:sub(nl + 1)
            out((line:gsub(escape(SHROOT), "")))
        end
    end
    local function closed()
        pending_close = pending_close - 1
    end
    local handle = uv.spawn(SH, { args = { "-c", cmd }, stdio = { nil, so, se }, hide = true },
        function() closed() end)
    if not handle then out("[Fail]cannot start device shell"); return end
    for _, p in ipairs({ so, se }) do
        p:read_start(function(_, data)
            if data then emit(data) else p:close(); closed() end
        end)
    end
    while pending_close > 0 do uv.run("once") end
    if buf ~= "" then io.stdout:write((buf:gsub(escape(SHROOT), ""))) end
    handle:close()
end

local serial
if argv[1] == "-t" then serial = argv[2]; table.remove(argv, 1); table.remove(argv, 1) end

if argv[1] == "list" and argv[2] == "targets" then
    if argv[3] == "-v" then out(SERIAL .. "\tUSB\tConnected\tlocalhost\thdc") else out(SERIAL) end
    os.exit(0)
end

if serial ~= SERIAL then
    out("[Fail]ExecuteCommand need connect-key? please confirm a device by help info")
    os.exit(0)
end

if argv[1] == "file" and argv[2] == "send" then
    local n, err = copy(argv[3], host(argv[4]))
    if n then out("FileTransfer finish, Size:" .. n .. ", File count = 1, time:1ms rate:1kB/s")
    else out("[Fail]Error opening file: " .. err .. ", path:" .. argv[4]) end
elseif argv[1] == "file" and argv[2] == "recv" then
    local n, err = copy(host(argv[3]), argv[4])
    if n then out("FileTransfer finish, Size:" .. n .. ", File count = 1, time:1ms rate:1kB/s")
    else out("[Fail]Error opening file: " .. err .. ", path:" .. argv[3]) end
elseif argv[1] == "shell" then
    local cmd = argv[2] or ""
    if cmd == "hilog -r" then
        out("Log type core,app,only_prerelease buffer clear successfully")
    elseif cmd == "hilog" or cmd:match("^hilog %-P %d+$") then
        local pid = cmd:match("^hilog %-P (%d+)$") or "0"
        local f = env("FAKE_HDC_HILOG") and io.open(env("FAKE_HDC_HILOG"), "rb")
        if f then
            for line in f:lines() do out((line:gsub("{PID}", pid))) end
            f:close()
        end
    else
        run_shell(cmd)
    end
else
    out("[Fail]unknown command " .. tostring(argv[1]))
end
os.exit(0)
