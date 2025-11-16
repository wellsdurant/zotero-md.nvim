-- zotero-md.nvim plugin entry point

-- Prevent loading the plugin twice
if vim.g.loaded_zotero_md then
  return
end
vim.g.loaded_zotero_md = true

-- Create user commands
vim.api.nvim_create_user_command("ZoteroPick", function()
  local zotero = require("zotero-md")
  zotero.pick_reference()
end, {
  desc = "Pick a Zotero reference and insert into markdown",
})

vim.api.nvim_create_user_command("ZoteroDebug", function(opts)
  local zotero = require("zotero-md")
  zotero.debug_db(opts.args)
end, {
  desc = "Debug Zotero database connection",
  nargs = "?",  -- Accept 0 or 1 arguments
})

vim.api.nvim_create_user_command("ZoteroInfo", function()
  local zotero = require("zotero-md")
  zotero.show_reference_info()
end, {
  desc = "Show Zotero reference info for link under cursor",
})
