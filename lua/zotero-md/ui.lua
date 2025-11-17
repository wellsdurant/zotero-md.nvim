-- UI components for zotero-md (Telescope picker and floating windows)
local parser = require("zotero-md.parser")
local utils = require("zotero-md.utils")

local M = {}

-- Calculate dynamic column widths for Telescope picker
local function calculate_column_widths(references)
  local title_width = 50
  local year_width = 4
  local author_width = 15
  local org_width = 10
  local pub_width = 15

  for _, ref in ipairs(references) do
    local author_len = #(ref.authors or "")
    local org_len = #(ref.organization or "")
    local pub_len = #(ref.publication or "")

    if author_len > author_width then
      author_width = author_len
    end
    if org_len > org_width then
      org_width = org_len
    end
    if pub_len > pub_width then
      pub_width = pub_len
    end
  end

  -- Cap widths at maximums
  if author_width > 30 then
    author_width = 30
  end
  if org_width > 20 then
    org_width = 20
  end
  if pub_width > 30 then
    pub_width = 30
  end

  return title_width, year_width, author_width, org_width, pub_width
end

-- Create Telescope previewer for references
local function create_previewer(preview_format)
  local previewers = require("telescope.previewers")

  return previewers.new_buffer_previewer({
    define_preview = function(self, entry)
      local ref = entry.value

      -- Define placeholders with values and highlight groups
      local placeholder_values = {
        { pattern = "{abbreviation}", value = ref.abbreviation or "", group = "String", marker = "\x01ABR\x01" },
        { pattern = "{title}", value = ref.title or "", group = "Title", marker = "\x01TTL\x01" },
        { pattern = "{year}", value = ref.year or "", group = "Number", marker = "\x01YR\x01" },
        { pattern = "{authors}", value = ref.authors or "", group = "Identifier", marker = "\x01AUT\x01" },
        { pattern = "{organization}", value = ref.organization or "", group = "Comment", marker = "\x01ORG\x01" },
        { pattern = "{publication}", value = ref.publication or "", group = "Include", marker = "\x01PUB\x01" },
        { pattern = "{eventshort}", value = ref.eventshort or "", group = "Include", marker = "\x01EVT\x01" },
        { pattern = "{type}", value = ref.type or "", group = "Comment", marker = "\x01TYP\x01" },
        { pattern = "{url}", value = ref.url or "", group = "Underlined", marker = "\x01URL\x01" },
        { pattern = "{abstract}", value = ref.abstract or "", group = "Comment", marker = "\x01ABS\x01" },
        { pattern = "{key}", value = ref.itemKey or "", group = "Special", marker = "\x01KEY\x01" },
      }

      -- First pass: replace placeholders with unique markers (or remove if empty)
      local preview_text = preview_format
      local markers_to_replace = {}
      for _, ph in ipairs(placeholder_values) do
        if ph.value ~= "" then
          preview_text = preview_text:gsub(vim.pesc(ph.pattern), ph.marker)
          markers_to_replace[ph.marker] = { value = ph.value, group = ph.group }
        else
          preview_text = preview_text:gsub(vim.pesc(ph.pattern), "")
        end
      end

      -- Second pass: cleanup formatting
      preview_text = preview_text
        :gsub("%s+", " ")
        :gsub("^%s+", "")
        :gsub("%s*%(%s*%)", "")
        :gsub("%s*%[%s*%]", "")
        :gsub("%s*{%s*}", "")
        :gsub(",%s*,", ",")
        :gsub("^%s*,", "")
        :gsub(",%s*$", "")
        :gsub("%s+", " ")

      -- Third pass: find all markers and their positions
      local marker_positions = {}
      for _, ph in ipairs(placeholder_values) do
        if markers_to_replace[ph.marker] then
          local pos = 1
          while true do
            local found_start, found_end = preview_text:find(vim.pesc(ph.marker), pos, true)
            if not found_start then
              break
            end
            table.insert(marker_positions, {
              marker = ph.marker,
              start_pos = found_start,
              end_pos = found_end,
              data = markers_to_replace[ph.marker],
            })
            pos = found_end + 1
          end
        end
      end

      -- Sort by position (left to right)
      table.sort(marker_positions, function(a, b)
        return a.start_pos < b.start_pos
      end)

      -- Replace markers and record highlights in left-to-right order
      local highlights = {}
      local offset = 0
      for _, marker_info in ipairs(marker_positions) do
        local adjusted_start = marker_info.start_pos + offset
        local adjusted_end = marker_info.end_pos + offset
        local marker_len = adjusted_end - adjusted_start + 1
        local value_len = #marker_info.data.value

        -- Replace marker with value
        preview_text = preview_text:sub(1, adjusted_start - 1)
          .. marker_info.data.value
          .. preview_text:sub(adjusted_end + 1)

        -- Record highlight position
        table.insert(highlights, {
          group = marker_info.data.group,
          start_pos = adjusted_start - 1,
          end_pos = adjusted_start - 1 + value_len,
        })

        -- Update offset for next replacement
        offset = offset + (value_len - marker_len)
      end

      local bufnr = self.state.bufnr
      local winid = self.state.winid

      -- Set buffer content
      local lines = {}
      for line in preview_text:gmatch("[^\n]+") do
        table.insert(lines, line)
      end
      if #lines == 0 then
        lines = { preview_text }
      end
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

      -- Enable text wrapping
      if winid and vim.api.nvim_win_is_valid(winid) then
        vim.api.nvim_set_option_value("wrap", true, { win = winid })
        vim.api.nvim_set_option_value("linebreak", true, { win = winid })
        vim.api.nvim_set_option_value("breakindent", true, { win = winid })
      end

      -- Apply syntax highlighting
      local ns = vim.api.nvim_create_namespace("zotero_md_preview")
      for _, hl in ipairs(highlights) do
        if vim.fn.has("nvim-0.11") == 1 then
          vim.hl.range(bufnr, ns, hl.group, { 0, hl.start_pos }, { 0, hl.end_pos }, {})
        else
          vim.api.nvim_buf_add_highlight(bufnr, ns, hl.group, 0, hl.start_pos, hl.end_pos)
        end
      end
    end,
  })
end

-- Build ordinal string from configured search fields
local function build_ordinal(entry, search_fields)
  local parts = {}
  for _, field in ipairs(search_fields) do
    local value = entry[field]
    if value and value ~= "" then
      table.insert(parts, value)
    end
  end
  return table.concat(parts, " ")
end

-- Show Telescope picker for reference selection
function M.show_picker(references, config, on_select)
  -- Check if we're in a markdown file
  if not utils.is_markdown_file() then
    vim.notify("ZoteroPick only works in markdown files", vim.log.levels.WARN)
    return
  end

  -- Load Telescope
  local ok, telescope = pcall(require, "telescope")
  if not ok then
    vim.notify("Telescope.nvim is required", vim.log.levels.ERROR)
    return
  end

  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local entry_display = require("telescope.pickers.entry_display")

  -- Calculate dynamic column widths
  local title_width, year_width, author_width, org_width, pub_width = calculate_column_widths(references)

  -- Create picker
  local opts = {
    prompt_title = "Search pattern",
    results_title = "Zotero references",
    finder = finders.new_table({
      results = references,
      entry_maker = function(entry)
        local displayer = entry_display.create({
          separator = " ",
          items = {
            { width = title_width },
            { width = year_width },
            { width = author_width },
            { width = org_width },
            { remaining = true },
          },
        })

        return {
          value = entry,
          display = function(e)
            -- Build title with abbreviation prefix
            local title_text = e.value.title or ""
            if e.value.abbreviation and e.value.abbreviation ~= "" then
              title_text = "(" .. e.value.abbreviation .. ") " .. title_text
            end

            -- Build publication with event if present
            local pub_text = e.value.publication or ""
            if e.value.eventshort and e.value.eventshort ~= "" then
              pub_text = pub_text .. " (" .. e.value.eventshort .. ")"
            end

            return displayer({
              { title_text, "Title" },
              { e.value.year or "", "Number" },
              { e.value.authors or "", "Identifier" },
              { e.value.organization or "", "Comment" },
              { pub_text, "Include" },
            })
          end,
          ordinal = build_ordinal(entry, config.search_fields or { "title", "year", "authors" }),
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = create_previewer(config.preview_format),
    attach_mappings = function(prompt_bufnr, map)
      -- Setup virtual text placeholder hint
      local ns_id = vim.api.nvim_create_namespace("zotero_placeholder")
      local placeholder_hint = "searches: " .. table.concat(config.search_fields or { "title", "year", "authors" }, ", ")
      local prompt_prefix = conf.prompt_prefix or "> "
      local prefix_width = vim.fn.strdisplaywidth(prompt_prefix)

      local function update_placeholder()
        local current_picker = action_state.get_current_picker(prompt_bufnr)
        if not current_picker then
          return
        end

        local prompt_text = current_picker:_get_prompt()
        vim.api.nvim_buf_clear_namespace(prompt_bufnr, ns_id, 0, -1)

        if prompt_text == "" then
          vim.api.nvim_buf_set_extmark(prompt_bufnr, ns_id, 0, 0, {
            virt_text = { { placeholder_hint, "Comment" } },
            virt_text_win_col = prefix_width,
            priority = 100,
          })
        end
      end

      -- Initial placeholder
      vim.schedule(update_placeholder)

      -- Update on text changes
      vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = prompt_bufnr,
        callback = update_placeholder,
      })

      map({ "i", "n" }, "<CR>", function()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if selection then
          on_select(selection.value)
        end
      end)
      return true
    end,
  }

  pickers.new(opts, {}):find()
end

-- Show reference info in floating window
function M.show_reference_info(reference)
  -- Build info message
  local info = {}
  table.insert(info, "=== Zotero Reference Info ===")
  table.insert(info, "")
  table.insert(info, "Title: " .. (reference.title or ""))
  table.insert(info, "Authors: " .. (reference.authors or ""))
  table.insert(info, "Year: " .. (reference.year or ""))
  table.insert(info, "Type: " .. (reference.type or ""))
  table.insert(info, "Publication: " .. (reference.publication or ""))

  if reference.abbreviation and reference.abbreviation ~= "" then
    table.insert(info, "Abbreviation: " .. reference.abbreviation)
  end
  if reference.organization and reference.organization ~= "" then
    table.insert(info, "Organization: " .. reference.organization)
  end
  if reference.eventshort and reference.eventshort ~= "" then
    table.insert(info, "Event: " .. reference.eventshort)
  end
  if reference.url and reference.url ~= "" then
    table.insert(info, "URL: " .. reference.url)
  end

  table.insert(info, "")
  table.insert(info, "Key: " .. reference.itemKey)
  table.insert(info, "Zotero URI: " .. reference.zotero_uri)

  if reference.abstract and reference.abstract ~= "" then
    table.insert(info, "")
    table.insert(info, "Abstract:")
    -- Wrap abstract text
    local abstract_lines = vim.split(reference.abstract, " ")
    local current_line = ""
    for _, word in ipairs(abstract_lines) do
      if #current_line + #word + 1 > 80 then
        table.insert(info, current_line)
        current_line = word
      else
        if current_line == "" then
          current_line = word
        else
          current_line = current_line .. " " .. word
        end
      end
    end
    if current_line ~= "" then
      table.insert(info, current_line)
    end
  end

  -- Show in floating window
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, info)
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)
  vim.api.nvim_buf_set_option(buf, 'filetype', 'markdown')

  local width = math.min(100, vim.o.columns - 4)
  local height = math.min(#info + 2, vim.o.lines - 4)

  local opts = {
    relative = 'cursor',
    width = width,
    height = height,
    row = 1,
    col = 0,
    style = 'minimal',
    border = 'rounded',
  }

  local win = vim.api.nvim_open_win(buf, true, opts)
  vim.api.nvim_win_set_option(win, 'wrap', true)
  vim.api.nvim_win_set_option(win, 'linebreak', true)

  -- Close on q or Esc
  vim.keymap.set('n', 'q', '<cmd>close<cr>', { buffer = buf, silent = true })
  vim.keymap.set('n', '<Esc>', '<cmd>close<cr>', { buffer = buf, silent = true })
end

-- Find Zotero link under cursor
function M.find_link_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]

  -- Find markdown link with zotero:// URL under cursor
  local search_pos = 1
  while true do
    local link_start, link_end, display_text, item_key = line:find(
      "%[([^%]]+)%]%(zotero://select/library/items/([%w]+)%)",
      search_pos
    )

    if not link_start then
      break
    end

    -- Check if cursor is within this entire markdown link
    if col >= link_start - 1 and col <= link_end then
      return item_key
    end

    search_pos = link_end + 1
  end

  return nil
end

return M
