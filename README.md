# loomworks-module-ohos.nvim

OpenHarmony / HarmonyOS support for [loomworks] (`lw` 0.2 or later).

Ships:

- `harmony` project module — DevEco / OpenHarmony SDK detection, hvigor
  build pipeline, product×target×ABI configurations, external build
  dirs, SDK clangd routing via `lsp_configs`, `cmake_env` passthrough,
  device deployment via `hdc`, and the `hilog` log stream view.
- `ohos` SDK provider — locates the OpenHarmony SDK and exposes its
  kits (sysroot, ndk, toolchain) to both the harmony module and
  cmake projects that want to cross-compile against the same SDK.
  Also supplies the **device runner** loomworks uses to run native
  executables from those cmake kits on an attached device (`lw run` /
  `lw test` on a foreign build): staging over `hdc`, exit status,
  crash-report collection and a filtered hilog stream. The connector is
  always the SDK's own `hdc` (never one found on `PATH`). A program left
  running by a run that was killed without cleaning up is stopped by the
  next run on that device (after checking the process is still that
  program), together with the run's leftover wrapper shell.
- `hvigor` build progress parser — recognises hvigor's progress lines
  and feeds them into the loomworks progress aggregator.

## Install

Requires the standalone `lw` 0.2 or later (see [loomworks]). The module
runs inside `lw`, so it serves the CLI and loomworks.nvim alike; nothing
is installed into Neovim.

```sh
lw module install harmony    # download, verify (SHA-256 from the index), install
lw module list               # available and installed modules, with versions
lw module update harmony     # to the version the index records (or --all)
lw module remove harmony     # uninstall
```

`lw module install` fetches the version recorded in loomworks' curated
module index and checks it is compatible with the running `lw`.

The Neovim-side `:LoomworksDeviceLogLevel` command and the
`device_log_level` / `device_log_strict_pid` setup options are not
available with `lw` 0.2; set the hilog level per run with the `--log`
options below.

## How it integrates

The module ships its Lua files at the import paths `lw` uses for module,
SDK and progress-parser lookups (`lua/loomworks/modules/harmony.lua`,
`lua/loomworks/sdks/ohos.lua`, `lua/loomworks/progress/hvigor.lua`).
Once installed, `"harmony"` projects (`lw project add` detects them by
`build-profile.json5`) and `ohos` SDK entries (`lw sdk detect` /
`lw sdk add ohos`) resolve automatically.

## Spec

- [`spec/modules/harmony.md`](spec/modules/harmony.md) — full module
  contract (detection, configurations, build pipeline, device
  deployment, hilog streaming).
- [`spec/sdks/ohos.md`](spec/sdks/ohos.md) — SDK provider contract
  (detection paths, kit shape and target-platform tokens, cmake &
  harmony integration, the device runner and its hilog log session).

## Device log options

Runs on a device accept hilog options, from a launch configuration's
`device_log` table or `lw … --log key=value`:
`show` (`stdout` | `hilog` | `both`), `prefilter` (`pid` | `strict` |
`app-related` | `all`), `level` (`D`…`F`), `tag`, `proc`, `grep`,
`exclude` (Lua patterns), `tail`. For a native executable the default is
program output live and hilog — selected by the program's pid
(`prefilter=pid`), level `W`, last 30 lines — printed only when the run
fails; e.g. `lw run P Runner --log show=both --log level=D`. See
[`spec/modules/harmony.md`](spec/modules/harmony.md) §6.5.

[loomworks]: https://github.com/samienne/loomworks
