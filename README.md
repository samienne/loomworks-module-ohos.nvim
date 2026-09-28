# loomworks-module-ohos.nvim

OpenHarmony / HarmonyOS support for [loomworks.nvim].

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
  always the SDK's own `hdc` (never one found on `PATH`).
- `hvigor` build progress parser — recognises hvigor's progress lines
  and feeds them into the loomworks progress aggregator.

## Install

Requires [loomworks.nvim].

With [lazy.nvim]:

```lua
{
    url = "https://gitcode.com/samienne/loomworks-module-ohos.nvim",
    dependencies = { "samienne/loomworks.nvim" },
    config = function()
        require("loomworks-module-ohos").setup({
            -- Defaults below — both optional.
            device_log_level = "I",         -- D | I | W | E | F
            device_log_strict_pid = true,
        })
    end,
}
```

Lazy.nvim's `dev = true` shorthand also works when a local checkout is
present under your dev root.

## How it integrates

The module ships its Lua files at the same import path that loomworks
core uses for its built-in modules (`lua/loomworks/modules/harmony.lua`,
`lua/loomworks/sdks/ohos.lua`, `lua/loomworks/progress/hvigor.lua`).
Loomworks' module + SDK + progress registries walk the runtime path,
so as long as this plugin is on rtp, both `"harmony"` projects in
`loomworks.json` and `"ohos"` entries in `user.json`'s `sdks` block
resolve automatically. No core changes required.

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

## Commands

- `:LoomworksDeviceLogLevel [D|I|W|E|F]` — show or set the on-device
  soft-filter level for the hilog stream view.

[loomworks.nvim]: https://gitcode.com/samienne/loomworks.nvim
[lazy.nvim]: https://github.com/folke/lazy.nvim
