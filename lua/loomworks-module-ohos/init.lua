--- loomworks-module-ohos — OpenHarmony / HarmonyOS module for loomworks.nvim.
---
--- Ships the `harmony` module (Lua: `loomworks.modules.harmony`), the
--- `ohos` SDK provider (`loomworks.sdks.ohos`), and the hvigor build
--- progress parser (`loomworks.progress.hvigor`) at the same Lua
--- module paths that loomworks core uses for its built-in modules.
--- loomworks core's discovery walks the runtime path, so plain `dev =
--- true` (lazy.nvim) or any other rtp-prepend is enough to register
--- these — no explicit setup() call is required for the module to
--- appear in `loomworks.json` projects of type `"harmony"`.
---
--- This wrapper's `setup({...})` exposes the bits that are tunable at
--- the user level:
---
---   * `device_log_level`      — D | I | W | E | F (default I)
---   * `device_log_strict_pid` — boolean (default true)
---
--- Both forward into the harmony module's own state.

local M = {}

--- Configure the harmony module.
--- @param opts? { device_log_level?: "D"|"I"|"W"|"E"|"F", device_log_strict_pid?: boolean }
function M.setup(opts)
    local harmony = require("loomworks.modules.harmony")
    harmony.setup(opts)
end

return M
