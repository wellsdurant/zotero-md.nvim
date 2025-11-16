-- Configuration management for zotero-md
local M = {}

-- Default configuration
M.defaults = {
  zotero_db_path = vim.fn.expand("~/Zotero/zotero.sqlite"),
  cache_file = vim.fn.expand("~/.local/share/nvim/zotero-md-cache.json"),
  cache_expiration = 3600, -- 1 hour in seconds
  citation_format = "{title} ({year})",
  preview_format = "{title}, {year}, {authors}, {publication}, {abstract}",
  preload = true,
  preload_delay = 1000, -- milliseconds
  auto_update = true,
  auto_update_interval = 300, -- 5 minutes in seconds
  telescope_opts = {
    prompt_title = "Zotero References",
    layout_strategy = "horizontal",
    layout_config = {
      width = 0.8,
      height = 0.8,
      preview_width = 0.6,
    },
  },
  keymaps = {
    insert_mode = "<C-z>",
  },
}

-- Current configuration (merged with user config)
M.current = {}

-- Merge user configuration with defaults
function M.setup(user_config)
  M.current = vim.tbl_deep_extend("force", M.defaults, user_config or {})
  return M.current
end

-- Get configuration value
function M.get(key)
  return M.current[key]
end

return M
