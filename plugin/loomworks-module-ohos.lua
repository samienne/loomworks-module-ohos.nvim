-- loomworks-module-ohos.nvim — auto-loaded entry point.
-- Registers user-facing commands for the harmony module.

if vim.g.loaded_loomworks_module_ohos then return end
vim.g.loaded_loomworks_module_ohos = true

vim.api.nvim_create_user_command("LoomworksDeviceLogLevel", function(cmd)
    local harmony = require("loomworks.modules.harmony")
    local arg = cmd.args
    if not arg or arg == "" then
        vim.notify("loomworks(harmony): device log level is "
            .. harmony.get_device_log_level(), vim.log.levels.INFO)
        return
    end
    arg = arg:upper()
    local ok, err = harmony.set_device_log_level(arg)
    if not ok then
        vim.notify("loomworks(harmony): " .. (err or "unknown error"),
            vim.log.levels.ERROR)
        return
    end
    vim.notify("loomworks(harmony): device log level set to " .. arg,
        vim.log.levels.INFO)
end, {
    nargs = "?",
    complete = function() return { "D", "I", "W", "E", "F" } end,
    desc = "loomworks: get/set on-device hilog level (D|I|W|E|F)",
    force = true,
})
