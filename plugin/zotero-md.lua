-- zotero-md.nvim plugin entry point

-- Prevent loading the plugin twice
if vim.g.loaded_zotero_md then
  return
end
vim.g.loaded_zotero_md = true

-- Create user command
vim.api.nvim_create_user_command("ZoteroPick", function()
  local zotero = require("zotero-md")
  zotero.pick_reference()
end, {
  desc = "Pick a Zotero reference and insert into markdown",
})
