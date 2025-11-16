-- Utility functions for zotero-md
local M = {}

-- Check if file is markdown
function M.is_markdown_file()
  local filetype = vim.bo.filetype
  return filetype == "markdown" or filetype == "md"
end

-- Parse SQLite result using ASCII separators
function M.parse_sqlite_result(result, field_sep, record_sep)
  field_sep = field_sep or "\x1F"  -- ASCII Unit Separator
  record_sep = record_sep or "\x1E"  -- ASCII Record Separator

  local rows = {}
  -- Split by record separator
  for record in result:gmatch("[^" .. record_sep .. "]+") do
    local row = {}
    -- Split by field separator
    local start_pos = 1
    while true do
      local sep_pos = record:find(field_sep, start_pos, true)
      if not sep_pos then
        -- Last field
        local field_value = record:sub(start_pos)
        -- Trim trailing newline if present
        field_value = field_value:gsub("\n$", "")
        table.insert(row, field_value)
        break
      end
      table.insert(row, record:sub(start_pos, sep_pos - 1))
      start_pos = sep_pos + #field_sep
    end
    if #row > 0 then
      table.insert(rows, row)
    end
  end
  return rows
end

return M
