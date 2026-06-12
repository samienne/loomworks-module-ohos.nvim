-- Minimal init for plenary.busted tests.
-- Sets up runtime path so require("loomworks.*") (from the parent
-- loomworks.nvim plugin) and require("loomworks-module-ohos.*")
-- both resolve.

local uv = vim.uv or vim.loop

-- Add this plugin's own directory to rtp.
vim.opt.rtp:prepend(".")

-- Locate loomworks.nvim so tests can require its modules. Tries:
--   1. LOOMWORKS_PATH environment variable (CI / explicit override).
--   2. Sibling directory `../loomworks.nvim` (dev-checkout layout
--      matching c:/src/nvim-plugins/{loomworks.nvim,loomworks-module-ohos.nvim}).
--   3. Standard dev roots (c:/src/nvim-plugins, ~/src/nvim-plugins).
--   4. Lazy.nvim install directory.
local function find_loomworks()
    local env = os.getenv("LOOMWORKS_PATH")
    if env and env ~= "" and uv.fs_stat(env) then return env end

    local cwd = vim.fn.getcwd():gsub("\\", "/")
    local sibling = cwd:gsub("/[^/]+$", "/loomworks.nvim")
    if uv.fs_stat(sibling) then return sibling end

    local candidates
    if jit.os == "Windows" then
        candidates = {
            "C:/src/nvim-plugins/loomworks.nvim",
            "D:/src/nvim-plugins/loomworks.nvim",
        }
    else
        candidates = { vim.fn.expand("~/src/nvim-plugins/loomworks.nvim") }
    end
    for _, c in ipairs(candidates) do
        if uv.fs_stat(c) then return c end
    end

    local lazy = vim.fn.stdpath("data") .. "/lazy/loomworks.nvim"
    if uv.fs_stat(lazy) then return lazy end

    return nil
end

local loomworks_path = find_loomworks()
if loomworks_path then
    vim.opt.rtp:prepend(loomworks_path)
else
    error("loomworks-module-ohos: cannot find loomworks.nvim — "
        .. "set $LOOMWORKS_PATH or check it out under c:/src/nvim-plugins/")
end

-- Add plenary (lazy.nvim install location).
local plenary_path = vim.fn.stdpath("data") .. "/lazy/plenary.nvim"
if vim.fn.isdirectory(plenary_path) == 1 then
    vim.opt.rtp:prepend(plenary_path)
end

vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
