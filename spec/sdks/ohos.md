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
- **Failure detection** — hdc exits 0 on failure; `check_output` detects
  `[Fail]`/`[F]` markers and `error:` lines (harmony.md §6.2), CRLF
  tolerant.
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
| `exec(s, req)` | `-t s shell <script>` (one element) | §8.4; `check_output` |
| `parse_exit(line, n)` | — | `__LW_EXIT_<n>=<status>` at the **end** of the line (after CR strip). Returns the status and, as a second value, any program text that preceded the sentinel on the same line (a last output line without a newline) |
| `parse_pid(line, n)` | — | whole line `__LW_PID_<n>=<pid>` |
| `terminate(s, n, pid)` | `-t s shell "kill <pid> 2>/dev/null; sleep 1; kill -9 <pid> 2>/dev/null"` | only a positive integer pid (from `parse_pid`); without one it returns `nil` (nothing sent) |
| `crash_snapshot(s)` | `-t s shell "ls -1 /data/log/faultlog/faultlogger/"` | returns the spec and `parse(lines)` → set of `cppcrash-*` names (error lines give an empty set) |
| `crash_collect(b, a)` | — | sorted `/data/log/faultlog/faultlogger/<name>` for names in `a` not in `b` |
| `runtime_files(tool)` | — | `{ local = <sdk>/sdk/default/openharmony/native/llvm/lib/<triple>/libc++_shared.so, relative = "libc++_shared.so" }` for the tool's `arch` (`arm64-v8a` → `aarch64-linux-ohos`, `armeabi-v7a` → `arm-linux-ohos`, `x86_64` → `x86_64-linux-ohos`), **always** staged (harmless for a static-STL program; the runner sees only the tool, not the configuration's `OHOS_STL`). Empty when the arch is unknown or the file is absent. Accepts a Tool (`tool.data`) or raw tool data |
| `log_session(s, opts, program)` | — | §8.5 |

Directory sends (`hdc file send <dir>`) are never used.

### 8.4 The exec script

Built from the structured request `{ argv, cwd, env, library_dirs, nonce }`
and joined with `; ` into the single `shell` argument:

```sh
cd '<cwd>' || { echo __LW_EXIT_<n>=126; exit 126; }
K='V' … LD_LIBRARY_PATH='<d1>:<d2>'"${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" sh -c 'echo __LW_PID_<n>=$$; exec "$0" "$@"' '<argv1>' '<argv2>' …
echo __LW_EXIT_<n>=$?
```

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
| `receive(line)` | sanitize → parse → session prefilter (`prefilter` mode, the streamed pid, `program.name` as proc). Unparseable lines are kept raw. Returns the sanitized line or `nil` |
| `display(line)` | parse → soft filter (`level`, `tag`, `proc`, `grep`, `exclude`; AND) → compact rendering (`HH:MM:SS.mmm PID L [PROC/]TAG: msg`); raw lines shown as-is unless a pattern hides them; `nil` when filtered out |
| `show` | `stdout` → `{ program = live, log = on_failure, tail }`; `hilog` → `{ program = off, log = live, tail }`; `both` → `{ program = live, log = live, tail }` |
| `options` | the resolved options (diagnostic; not part of the core contract) |

Option values are data: none is ever interpolated into a device command
(only the integer pid is).

### 8.6 Unverified on a device

- **`sha256sum` on the device** (toybox). If it is missing, the digest
  command fails, no digests come back and core re-stages (correct, only
  slower). `md5sum` is not used as an automatic fallback: the device
  digest must be the algorithm core records on the host.
- **Proc column of a native process** in hilog (full name, truncated or
  absent) — only affects `prefilter = strict`, hence the `app-related`
  default for native runs.
- **Mixed-quote arguments end to end** (`'` and `"` in one argument).
  Covered by unit tests against a host POSIX `sh`; the first device smoke
  test repeats it.
- **Faultlogger readability** for the shell user on user builds.
