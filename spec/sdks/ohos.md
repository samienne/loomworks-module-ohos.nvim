# OpenHarmony / HarmonyOS SDK provider

Implements the core SDK provider contract (`specification.md` §10)
for the OpenHarmony / HarmonyOS toolchain shipped inside DevEco
Studio. Lives at `lua/loomworks/sdks/ohos.lua`. Section numbers in
this file are local.

## 1. Provider id

`P.id = "ohos"`. `P.display_name = "DevEco Studio"`.

## 2. Detection (`detect_all`)

Scans common DevEco Studio installation locations on the host:

- Windows: `C:\Program Files\Huawei\DevEco Studio*`,
  `C:\DevEco Studio*`
- macOS: `/Applications/DevEco-Studio.app`,
  `~/Applications/DevEco-Studio.app`
- Linux: `/opt/deveco-studio*`, `~/deveco-studio*`

Plus user-provided override path. Each candidate is realpath'd and
deduplicated case-insensitively.

For each candidate it reads `product-info.json` for the IDE version,
falling back to
`sdk/default/openharmony/oh-uni-package.json` for the SDK version.

Returns `{ path, version }[]` entries.

## 3. Validation (`validate`)

A path is valid when both the SDK root and the OpenHarmony tooling
shape exist:

- `<path>/sdk/default/openharmony/native/` — toolchain bundle
- One of `ohos.toolchain.cmake` or `hmos.toolchain.cmake` under the
  expected prefix

Validation does not require all tools to resolve — missing tools are
reported as `nil` capability fields rather than rejecting the SDK.

## 4. Capability query (`query_capabilities`)

`module_id == nil` returns the supported module ids:
`{ "cmake", "harmony" }`.

### 4.1 harmony module capabilities

```lua
{
    deveco_home  = path,
    node         = .../tools/node/node,
    hvigorw_js   = .../tools/hvigor/bin/hvigorw.js,
    ohpm         = .../tools/ohpm/bin/ohpm,
    hdc          = .../sdk/default/openharmony/toolchains/hdc,
    java         = .../jbr/bin/java,
}
```

The harmony module uses these to invoke hvigor, push/inspect
artifacts via hdc, and run scripts under the SDK's bundled Node.

### 4.2 cmake module capabilities

Offers one platform entry per available toolchain (HarmonyOS,
OpenHarmony, or both):

```lua
{
    platforms = { {
        name = "HarmonyOS",        -- or "OpenHarmony"
        toolchain_file = "...",
        archs = { "arm64-v8a", "armeabi-v7a" },
        arch_args = {
            ["arm64-v8a"] = { "-DOHOS_ARCH=...", "-DOHOS_SDK_NATIVE=...", ... },
            ...
        },
        target_platform = { ["arm64-v8a"] = "ohos-aarch64", ["armeabi-v7a"] = "ohos-arm" },
    }, ... },
    cmake_path = .../native/build-tools/cmake/bin/cmake,
    clangd_path = .../native/llvm/bin/clangd,
    clangd_required = true,
    sdk_display = "DevEco Studio <version>",
}
```

When the SDK's bundled ninja exists (`.../native/build-tools/cmake/bin/ninja`,
next to the bundled cmake), every `arch_args` list also carries
`-DCMAKE_MAKE_PROGRAM=<abs path to it>` so configure uses the SDK's
cmake+ninja pairing rather than the first ninja on PATH. Core's cmake
kits have no dedicated make-program field, so it rides in the extra args;
core appends user configuration options after kit args, so a user-set
`CMAKE_MAKE_PROGRAM` still wins. Without a bundled ninja no pin is emitted.

Each platform entry also carries `target_platform`, a per-arch table of
target-platform tokens (core §10.7; cmake module spec §15.1):
`arm64-v8a` → `"ohos-aarch64"`, `armeabi-v7a` → `"ohos-arm"` (both
HarmonyOS and OpenHarmony). The cmake module copies the token onto each
kit; core routes a foreign build to this provider's device runner (§8) by
comparing it with the runner's `platforms`. The tokens are this
provider's own vocabulary and are not part of kit identity. The table is
`P.PLATFORM_TOKENS`.

`clangd_required = true` because the SDK-bundled clangd knows
platform headers that stock PATH-clangd cannot locate. Falling back
would silently produce wrong index data.

### 4.3 No capability for unknown modules

Returns `nil` when queried with a `module_id` this provider doesn't
support. Core treats `nil` as "this SDK has nothing to offer this
module" and falls through to host-tool detection (or marks the
profile incomplete if no host tool selection exists).

## 5. Tool key derivation

When a profile selects this SDK, the cmake module derives keyed tools
from the `platforms` list: each `(platform, arch)` pair becomes a
distinct tool with key `"<platform>-<arch>"` (lower-cased, e.g.
`"harmonyos-arm64-v8a"`). Tool labels read `"<sdk_display> /
<platform> / <arch>"`.

## 6. SDK identity persistence

When the user pins this SDK to a profile, the profile stores
`sdk_key` in user.json. On reload, the SDK is resolved by `key`
against the workspace's known providers. If the SDK provider is no
longer detectable (DevEco moved, uninstalled), the profile renders as
incomplete with a rebase action.

## 7. Future direction

Profile-level SDK selection is documented as design-ready in
BACKLOG.md. The current shape resolves SDK-supplied tools lazily via
`Profile:tool_for(module)` rather than persisting them in the
profile's `tools` dict. That keeps SDK refresh cheap (re-query on
load) at the cost of slightly more code in the access path.

## 8. Device runner (`device_runner`)

Implements core §18.2 (remote execution on devices) for DevEco Studio
installations: plain native executables built by this provider's cmake
kits (§4.2) run on an attached HarmonyOS/OpenHarmony device through
`hdc`. The runner only builds command specs and parses output — core
spawns every process and owns timeouts, cancellation, line-ending
normalization and the device lock. Code:
`lua/loomworks-module-ohos/runner.lua`, returned by
`P.device_runner(sdk)`.

`device_runner(sdk)` returns `nil` when the installation has no hdc
(`<deveco>/sdk/default/openharmony/toolchains/hdc[.exe]`). The hdc path
comes only from the SDK installation — never from `PATH`, never from
cached tool data (core §17.7). The harmony module follows the same rule
(harmony.md §6.1).

### 8.1 hdc helper

All hdc knowledge lives in `lua/loomworks-module-ohos/hdc.lua`, shared by
the runner and the harmony module:

- **argv** — `-t <serial> <subcommand…>`; every device command is
  `-t <serial> shell <command>` with `<command>` as **one** argv element.
  Verified on a device: everything after `shell` passed as one element
  reaches the device `sh` intact.
- **Quoting** — every device-side word is POSIX single-quoted (`'` →
  `'\''`); words made only of `[A-Za-z0-9-._/:,+@%]` are left bare. `=` and
  `~` are never bare (assignment / tilde expansion). NUL and line breaks
  are refused.
- **Local paths** — rendered with backslashes on Windows (hdc treats a
  forward-slash host path as relative there). Device paths stay POSIX.
- **Failure detection** — hdc exits 0 on failure. Two checks, both CRLF
  tolerant, both returning the message without its leading marker:
  - `check_output` — `[Fail]`/`[F]` markers and `error:` lines
    (harmony.md §6.2). Used by `push` / `pull` and the harmony module,
    whose output is hdc's own.
  - `check_connector_output` — `[Fail]`/`[F]` markers **only**. Used
    wherever the inspected lines can contain device-side text (`exec`,
    `crash_snapshot`, `describe_device`): a program or utility printing
    `error: …` is not a connector failure.

  Real shapes (device-verified, host exit code 0 in all):
  `[Fail]Error opening file: no such file or directory, path:<p>`
  (recv of a missing file); `[Fail]Not match target founded, check
  connect-key please` and `[Fail]ExecuteCommand need connect-key? please
  confirm a device by help info` (unknown serial). `hdc shell false` also
  exits 0 — a device status comes only from the exec sentinel.
  **Ordering caveat:** `hdc shell` merges device stderr into stdout
  without preserving order; stderr may arrive before earlier stdout
  lines. Nothing may be inferred from the relative order of lines (this
  is why `exec` uses the connector-only check: out-of-order program
  stderr can land before the pid line or after the sentinel).
- **`list targets [-v]` parsing** — `[Empty]` and blank lines are not
  devices; verbose lines `<serial> <conn> <state> <host>` give
  `state = online` iff `Connected` and `properties.connection`; plain
  lines (bare serial) are `online`.
- **Digest parsing** — `<hex>  <path>` / `<hex> *<path>` lines
  (sha256sum / md5sum format); error lines are skipped.
- **Line endings** — `hdc shell` output ends in CRLF. Core normalizes;
  every parser here still strips a trailing CR.

### 8.2 Identity and capabilities

| Field | Value |
|-------|-------|
| `id` | `"ohos"` |
| `platforms` | `{ "ohos-aarch64", "ohos-arm" }` — the tokens of §4.2 |
| `staging_base` | `/data/local/tmp/.device-staging` |
| `archive` | `true` (device `tar -xf`, toybox) |
| `digest` | `{ "sha256sum" }` — see §8.6 |
| `combined_output` | `true` — `hdc shell` delivers the program's stderr merged into stdout (verified) |
| `timeouts` | not overridden (core defaults) |

### 8.3 Builders

| Builder | argv after `hdc` | Parsing / checks |
|---------|------------------|------------------|
| `list_devices()` | `list targets -v` | `parse_devices` = the §8.1 parser |
| `push(s, l, r)` | `-t s file send <l> <r>` | `<l>` rendered per §8.1; `check_output` |
| `pull(s, r, l)` | `-t s file recv <r> <l>` | same |
| `exec(s, req)` | `-t s shell <script>` (one element) | §8.4; `check_connector_output` |
| `parse_exit(line, n)` | — | `__LW_EXIT_<n>=<status>` at the **end** of the line (after CR strip). Returns the status and, as a second value, any program text that preceded the sentinel on the same line (a last output line without a newline) |
| `parse_pid(line, n)` | — | whole line `__LW_PID_<n>=<pid>` |
| `terminate(s, n, pid)` | `-t s shell "kill <pid> 2>/dev/null; sleep 1; kill -9 <pid> 2>/dev/null"` | only a positive integer pid (from `parse_pid`); without one it returns `nil` (nothing sent) |
| `reap(s, leftover)` | `-t s shell <reap script>` (one element, §8.9) | core §18.7: stop a program an interrupted run left. Returns the spec (`check_connector_output`) and `parse(lines)` → `"stopped"` \| `"gone"` \| `nil` from the whole line `__LW_REAP_<n>=<verdict>` for the leftover's nonce (`unknown` → `nil`). Raises — nothing sent — unless `pid` is an integer ≥ 2, the nonce alphanumeric and `program` an absolute path without NUL or line breaks |
| `crash_snapshot(s)` | `-t s shell 'for f in /data/log/faultlog/faultlogger/cppcrash-* /data/log/faultlog/temp/cppcrash-*; do [ -e "$f" ] && echo "$f"; done'` | returns the spec (`check_connector_output`) and `parse(lines)` → set of **full paths** of `cppcrash-*` files directly in either directory (§8.7); other lines are ignored |
| `crash_collect(b, a, ctx?)` | — | sorted paths in `a` not in `b`: every new faultlogger report, and new temp dumps — only `cppcrash-<pid>-…` when `ctx.pid` is given, all of them otherwise (§8.7) |
| `describe_device(s)` | `-t s shell 'for k in const.product.marketname const.product.model const.product.name; do echo "$k=$(param get $k 2>/dev/null)"; done'` | *(optional, §8.8)* returns the spec (`check_connector_output`) and `parse(lines)` → `{ display_name?, properties }` or `nil` |
| `runtime_files(tool)` | — | `{ local = <sdk>/sdk/default/openharmony/native/llvm/lib/<triple>/libc++_shared.so, relative = "libc++_shared.so" }` for the tool's `arch` (`arm64-v8a` → `aarch64-linux-ohos`, `armeabi-v7a` → `arm-linux-ohos`, `x86_64` → `x86_64-linux-ohos`), **always** staged (harmless for a static-STL program; the runner sees only the tool, not the configuration's `OHOS_STL`). Empty when the arch is unknown or the file is absent. Accepts a Tool (`tool.data`) or raw tool data |
| `log_session(s, opts, program)` | — | §8.5 |

Directory sends (`hdc file send <dir>`) are never used.

### 8.4 The exec script

Built from the structured request `{ argv, cwd, env, library_dirs, nonce }`
and joined with `; ` into the single `shell` argument:

```sh
cd '<cwd>' || { echo __LW_EXIT_<n>=126; exit 126; }
K='V' … LOOMWORKS_RUN_NONCE=<n> LD_LIBRARY_PATH='<d1>:<d2>'"${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" sh -c 'echo __LW_PID_<n>=$$; exec "$0" "$@"' '<prog>' '<argv2>' …
echo __LW_EXIT_<n>=$?
```

- `<prog>` is `./<basename>` when `argv[1]` is an absolute path whose
  directory equals `cwd` (trailing slashes ignored); otherwise `argv[1]`
  unchanged (bare utility names, relative paths, programs elsewhere).
  Reason (device-verified): faultloggerd records the crashing process
  name from its exec path truncated to 128 bytes, and for a program
  exec'd by its long absolute staging path hiview published **no**
  faultlogger report; exec'd as `./<name>` from its directory it did.
  `exec "$0" "$@"` and the pid announcement are unchanged.
- `LOOMWORKS_RUN_NONCE=<n>` is the run token (core §18.2): it reaches the
  program's environment so `reap` (§8.9) can identify the process even when
  its executable path is no longer resolvable. It is added to every exec
  (housekeeping included, harmless there) and never replaces a
  `LOOMWORKS_RUN_NONCE` the request sets itself.
- The `cd` line is omitted when the request has no `cwd` (nil or empty);
  `env` and `library_dirs` may be absent or empty. Core's staging
  housekeeping (`mkdir -p`, `chmod 755`, `rm`, `tar -xf`, `sha256sum`)
  uses utility names as `argv[1]`; `exec "$0"` resolves them through the
  device shell's `PATH`.
- The parsers escape the nonce with a local helper, not `vim.pesc`: the
  runner also runs under the standalone `lw` host's `vim` shim.
- Env names are emitted unquoted (a quoted name is not an assignment) and
  must be portable identifiers; values are single-quoted. Assignments are
  sorted by name. An `LD_LIBRARY_PATH` entry in `env` is ignored: the
  loader path comes only from `library_dirs` (core §18.9), whose entries
  may not contain `:`; the device's existing value is appended.
- The inner `sh -c … exec` makes the announced pid the program's own (exec
  keeps the pid), needed by `hilog -P` and `terminate`; the outer shell
  survives to print the exit sentinel.
- The nonce must be alphanumeric, so sentinel lines need no quoting.
- hdc exits 0 whatever the device status, so the sentinel is the only
  source of the exit status.

### 8.5 Log session (core §18.13)

`log_session(serial, options, program)` validates `options` against the
hilog option vocabulary (harmony.md §6.5) with the **native executable**
defaults and returns `nil, err` for an unknown key or bad value.
Otherwise it returns:

| Member | Value |
|--------|-------|
| `clear` | `-t s shell "hilog -r"` |
| `stream(pid)` | `-t s shell "hilog -P <pid>"` — only `-P`: no `-L` (suppresses some native log paths), no `-t`/`-T` (native `OH_LOG_Print` lands on type `core`; tags are filtered client-side). Without a valid pid: `hilog`. Also fixes the pid the prefilter uses |
| `receive(line)` | sanitize → parse → session prefilter (`prefilter` mode — default `pid` for native programs, harmony.md §6.5 — the streamed pid, `program.name` as proc). Unparseable lines are kept raw. Returns the sanitized line or `nil` |
| `display(line)` | parse → soft filter (`level`, `tag`, `proc`, `grep`, `exclude`; AND) → compact rendering (`HH:MM:SS.mmm PID L [PROC/]TAG: msg`); raw lines shown as-is unless a pattern hides them; `nil` when filtered out |
| `show` | `stdout` → `{ program = live, log = on_failure, tail }`; `hilog` → `{ program = off, log = live, tail }`; `both` → `{ program = live, log = live, tail }` |
| `options` | the resolved options (diagnostic; not part of the core contract) |

Option values are data: none is ever interpolated into a device command
(only the integer pid is).

### 8.6 Device facts (first real run) and what stays unverified

Verified on a Mate 60 Pro (HarmonyOS, toybox 0.8.12): `hdc shell` runs as
root (uid 0, `u:r:su:s0`); `sha256sum`, `md5sum` and `tar` are present;
a pax archive unpacks; `LD_LIBRARY_PATH` is honoured; `faultlogger/` and
`faultlog/temp/` are readable; an argument holding
``it's "quoted" $HOME `id` ;|&*`` arrives byte for byte. hilog's proc
column is **truncated** for a native program (`api_unit_te/<tag>`) and
**absent** for system domains (`MUSL-LDSO`, `PARAM_WATCHER`), while
`hilog -P <pid>` selects the program's records — hence the `pid`
prefilter default and truncation-tolerant proc matching (harmony.md §6.5).

Still unverified:

- **Faultlogger readability** for a non-root shell user on user builds.

### 8.7 Crash reports

Two device directories are snapshotted before and after the run:

| Directory | Written by | File |
|-----------|-----------|------|
| `/data/log/faultlog/faultlogger/` | hiview (published report) | `cppcrash-*.log` |
| `/data/log/faultlog/temp/` | faultloggerd, at the moment of the crash | `cppcrash-<pid>-<timestamp>.json` (full stack) |

Device-verified: after a SIGSEGV (exit 139) hiview published **no**
faultlogger report (none >90 s later) while faultloggerd wrote the temp
dump — whose `PNAME` was the exec path truncated to 128 bytes. The
`./<basename>` exec (§8.4) and core's shorter staging path address the
missing report; collecting the temp dump makes the crash evidence
independent of hiview either way.

`crash_collect(before, after, ctx?)` returns every new faultlogger report
(its name does not reliably carry the pid) and new temp dumps. With
`ctx = { pid = N }` — the pid `parse_pid` reported for the run — only
temp dumps named `cppcrash-N-…` are returned; without it (core's current
two-argument call) every new temp dump is, the snapshot diff already
confining them to the run's window. A non-integer `pid` is ignored.

### 8.8 Device description (`describe_device`)

Optional builder giving core a human-readable device name (`hdc list
targets -v` has none). One `hdc -t <serial> shell` call per **online**
device prints `<param>=<value>` for `const.product.marketname`,
`const.product.model` and `const.product.name`; `parse(lines)` keeps
non-empty values that are not `param get` error text and returns

```lua
{ display_name = marketname or product_name or model,
  properties = { market_name = …, model = …, product_name = … } }  -- present keys only
```

or `nil` when nothing usable came back (core then keeps the serial).

`param get` of an unset parameter prints error text such as
`get param: const.product.marketname fail! errNum is:106!` (wording
varies). A value containing `fail!` or `errNum` (case-insensitive), or
starting with `get param`, is error text; so is a bare output line with
those markers, which marks every describe parameter it names as absent
even if a value line for it was seen. Absent parameters are omitted from
`properties`.

Device-verified (Mate 60 Pro): `const.product.marketname` is **unset**
(errNum 106), `const.product.name` = `HUAWEI Mate 60 Pro`,
`const.product.model` = `ALN-AL00` — hence product name before model;
the model code is only the last resort.

### 8.9 Reaping a leftover program (`reap`, core §18.7)

A run that loses its cleanup (lw killed with `taskkill /F`, a power loss) or
its connection leaves its program running on the device; the next
acquisition of the device hands `reap` the recorded `{ pid, nonce, program }`
(`program` = the staged device-side path). The script
(`M.render_reap_script`, one line, parts joined with `; `; `@…@` filled in,
paths single-quoted when needed) uses only the toolset of §8.10:

```
p=<pid>; w=<program>; b=<basename>; v=LOOMWORKS_RUN_NONCE=<n>; t=__LW_EXIT""_<n>=; me=$(readlink /proc/$$/exe 2>/dev/null)
z() { xargs -0 -n1 < "$1" 2>/dev/null || strings "$1" 2>/dev/null; }   # a NUL-separated /proc file, one entry per line
isp() { … }   # 0 = this run's program, 1 = another program, 2 = cannot tell
isw() { … }   # is $1 this run's wrapper shell?
ws=; pp=; if [ -r /proc/$p/stat ]; then read -r s1 s2 s3 pp rest < /proc/$p/stat; isw "$pp" && ws=$pp; fi
if ! [ -d /proc/$p ]; then r=gone; else isp; c=$?; if [ $c = 2 ]; then r=unknown; elif [ $c = 1 ]; then r=gone; else kill $p; sleep 1; isp && kill -9 $p; sleep 1; if isp; then r=unknown; else r=stopped; fi; fi; fi
if [ -z "$ws" ] && [ "$r" != unknown ]; then <scan /proc/[0-9]*: shells with this shell's comm (builtin read of stat), isw each>; fi
if [ "$r" != unknown ] && [ -n "$ws" ]; then <kill each isw wrapper>; sleep 1; <kill -9 each still-isw wrapper, echo __LW_REAP_WRAPPER_<n>=<pid>>; fi
echo __LW_REAP_<n>=$r
```

- **Reading NUL-separated `/proc` files (`z`).** `environ` and `cmdline`
  are read only as `xargs -0 -n1 < file` (one entry per line), falling back
  to `strings file`. Device fact (toybox 0.8.12, Mate 60 Pro): there is no
  `tr` and no `awk`; `grep` stops at the first NUL of an input (also through
  `cat |`), and `sed 's/\x0/\n/g'` does not split — so `grep` never reads a
  `/proc` file directly. `strings` drops entries shorter than 4 characters,
  which never matters for the run token or the exit tag.
- **Program identity (`isp`).** Yes when `/proc/<pid>/exe` is the staged
  path (or `<path> (deleted)`), **or** when the exe's base name is the
  program's and the environ entries (`z`) hold exactly
  `LOOMWORKS_RUN_NONCE=<nonce>` (`grep -qxF`, whole line) — the run token
  the exec script exports (§8.4). Device fact: once the staging tree is
  removed, the exe link of the still-running program reads back as a
  *relative* `./<name>` (not `(deleted)`), so the path alone can no longer
  identify it. A pid the device has reused for another program fails both:
  `gone`, never signalled. An unreadable exe link, or an unreadable environ
  when the path does not match, is `2`: `unknown`, nothing sent. Every
  signal is re-guarded by `isp`; a zombie has no readable link and counts
  as stopped.
- **The wrapper (`isw`).** hdcd runs the exec script as `sh -c <script>`;
  that shell is the program's parent and prints the exit sentinel. Device
  facts: a wrapper can outlive its program, blocked on its pipe to hdcd
  (wchan `hm_futex_wait_interruptible`), in both the next-run and the
  `lw device clean` paths. A process is this run's wrapper when its exe is
  the same shell as the reap script's own (`/proc/$$/exe`) and its
  command-line entries (`z /proc/<pid>/cmdline`) contain
  `__LW_EXIT_<nonce>=` (`grep -qF`). The reap script assembles that tag
  (`t=__LW_EXIT""_<n>=`) so its own command line never matches, and skips
  itself (`$$`) and pid ≤ 1. The wrapper's pid is the program's ppid, read
  from `/proc/<pid>/stat` with the shell builtin `read -r s1 s2 s3 pp rest`
  **before** the program is signalled (killing the wrapper first reparents
  the program to init). When that does not yield it (the program is gone,
  or was already reparented), `/proc` is scanned; the scan reads each
  `stat` with the builtin `read` and checks only processes whose command
  name equals this shell's, so it costs almost no spawned processes.
  Wrappers are signalled only after the program and never after an
  `unknown` verdict.
- The verdict line `__LW_REAP_<n>=stopped|gone|unknown` is what `parse`
  reads; `__LW_REAP_WRAPPER_<n>=<pid>` lines are informational.
- Beta.3 on the phone (v0.1.3, which used `tr` and `grep` on `/proc`
  files): identity by run token answered `unknown` and the next-run path
  never found the wrapper (its cmdline check could not match). That the
  wrapper was gone after `lw device clean` there was therefore not reap's
  doing; the wrapper apparently ended on its own in that run.

### 8.10 Device toolset

The exec script (§8.4) and the reap script (§8.9) use only shell builtins
(`echo`, `read`, `kill`, `[`, `set`, `case`, functions, `$(…)`,
`${var%…}` / `${var##…}`, globs) and these tools, all proven present and
working on the phone's toybox 0.8.12: `cut`, `grep` (`-q`, `-x`, `-F`;
never on a NUL-separated input), `od`, `readlink`, `sleep` (fractions),
`strings`, `timeout`, `xargs` (`-0 -n1`), `sh`, `kill`, `ls`, `cat`.
Absent there: `tr`, `awk`; not usable: `sed` on NUL bytes.

`tests/ohos_reap_toybox_spec.lua` runs both scripts under the host's
POSIX sh with `PATH` restricted to shims for exactly this set — no `tr`,
no `awk` — where the `grep` shim stops every input at its first NUL like
toybox's, and `strings` is emulated; a second variant also drops `xargs`
to exercise the `strings` fallback. A script change that relies on
anything else fails there, not on the phone.
