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
  (detection paths, kit shape, cmake & harmony integration).

## Commands

- `:LoomworksDeviceLogLevel [D|I|W|E|F]` — show or set the on-device
  soft-filter level for the hilog stream view.

[loomworks.nvim]: https://gitcode.com/samienne/loomworks.nvim
[lazy.nvim]: https://github.com/folke/lazy.nvim
