local M = {}

-- Default configuration
local default_config = {
  zotero_db_path = vim.fn.expand("~/Zotero/zotero.sqlite"),
  cache_file = vim.fn.expand("~/.local/share/nvim/zotero-md-cache.json"),
  cache_expiration = 3600, -- 1 hour in seconds
  citation_format = "{title} ({year})",
  preview_format = "({abbreviation}) {title}, {year}, {authors}, ({organization}), {publication} ({eventshort})\n\n{abstract}",
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

-- Current configuration
local config = {}

-- Cache variables
local cache = {
  references = nil,
  last_update = 0,
  loading = false,
}

-- Check if file is markdown
local function is_markdown_file()
  local filetype = vim.bo.filetype
  return filetype == "markdown" or filetype == "md"
end

-- Read cache from file
local function read_cache()
  local cache_file = config.cache_file
  local file = io.open(cache_file, "r")
  if not file then
    return nil
  end

  local content = file:read("*all")
  file:close()

  local ok, decoded = pcall(vim.json.decode, content)
  if not ok then
    return nil
  end

  return decoded
end

-- Write cache to file
local function write_cache(data)
  local cache_file = config.cache_file
  local dir = vim.fn.fnamemodify(cache_file, ":h")
  vim.fn.mkdir(dir, "p")

  local file = io.open(cache_file, "w")
  if not file then
    vim.notify("Failed to write cache file: " .. cache_file, vim.log.levels.ERROR)
    return false
  end

  local encoded = vim.json.encode(data)
  file:write(encoded)
  file:close()

  return true
end

-- Copy database to temp location to avoid locks
local temp_db_path = nil
local temp_db_mtime = 0

local function get_temp_db()
  local db_path = config.zotero_db_path

  -- Get modification time of original database
  local mtime = vim.fn.getftime(db_path)

  -- Create temp path
  local temp_dir = vim.fn.stdpath("cache")
  local temp_path = temp_dir .. "/zotero-md-temp.sqlite"

  -- Check if we need to update the temp copy
  if temp_db_path ~= temp_path or mtime > temp_db_mtime then
    -- Copy database file
    local copy_success = vim.fn.system(string.format('cp "%s" "%s"', db_path, temp_path))
    if vim.v.shell_error == 0 then
      temp_db_path = temp_path
      temp_db_mtime = mtime
    else
      return nil, "Failed to copy database to temp location"
    end
  end

  return temp_db_path, nil
end

-- Execute SQLite query
local function execute_sqlite_query(db_path, query)
  -- Use a temporary copy of the database to avoid lock issues
  local actual_db_path, err = get_temp_db()
  if not actual_db_path then
    return nil, err or "Failed to access database"
  end

  local cmd = string.format('sqlite3 "%s" "%s" 2>&1', actual_db_path, query)
  local handle = io.popen(cmd)
  if not handle then
    return nil, "Failed to execute query"
  end

  local result = handle:read("*all")
  local success = handle:close()

  -- Check for errors in output
  if result and result:match("Error:") then
    return nil, result
  end

  return result, nil
end

-- Parse SQLite result (simple CSV-like parser)
local function parse_sqlite_result(result, separator)
  separator = separator or "|"
  local rows = {}
  for line in result:gmatch("[^\r\n]+") do
    local row = {}
    for value in line:gmatch("[^" .. separator .. "]+") do
      table.insert(row, value)
    end
    if #row > 0 then
      table.insert(rows, row)
    end
  end
  return rows
end

-- Parse extra field for custom fields (e.g., "Abbreviation: GPT2 (2019)\nOrganization: OpenAI")
local function parse_extra_field(extra)
  local fields = {}
  if not extra or extra == "" then
    return fields
  end

  -- Parse line by line
  for line in extra:gmatch("[^\r\n]+") do
    -- Match "Key: Value" format
    local key, value = line:match("^([^:]+):%s*(.+)$")
    if key and value then
      -- Store with lowercase key for case-insensitive matching
      fields[key:lower():gsub("%s+", "")] = value
    end
  end

  return fields
end

-- Load references from Zotero database (using zotcite approach)
local function load_references_from_db()
  local db_path = config.zotero_db_path

  -- Check if database exists
  if vim.fn.filereadable(db_path) ~= 1 then
    vim.notify("Zotero database not found at: " .. db_path, vim.log.levels.ERROR)
    return nil
  end

  -- Query 1: Get ALL authors at once (zotcite approach)
  local authors_query = [[
    SELECT items.itemID, creators.lastName, creators.firstName
    FROM items, itemCreators, creators
    WHERE items.itemID = itemCreators.itemID
      AND itemCreators.creatorID = creators.creatorID
      AND items.itemID NOT IN (SELECT itemID FROM deletedItems)
    ORDER BY items.itemID, itemCreators.orderIndex
  ]]

  local authors_result, err = execute_sqlite_query(db_path, authors_query)
  if not authors_result then
    vim.notify("Failed to query authors: " .. (err or "unknown error"), vim.log.levels.WARN)
  end

  -- Build a map of itemID -> authors
  local authors_map = {}
  if authors_result then
    local authors_rows = parse_sqlite_result(authors_result)
    for _, row in ipairs(authors_rows) do
      if #row >= 2 then
        local item_id = row[1]
        local last_name = row[2] or ""
        local first_name = row[3] or ""

        if last_name ~= "" then
          if not authors_map[item_id] then
            authors_map[item_id] = {}
          end
          -- Only keep first 3 authors
          if #authors_map[item_id] < 3 then
            table.insert(authors_map[item_id], { lastName = last_name, firstName = first_name })
          end
        end
      end
    end
  end

  -- Query 2: Get all item data (simplified from zotcite approach)
  local query = [[
    SELECT
      items.itemID,
      items.key,
      itemTypes.typeName,
      GROUP_CONCAT(CASE WHEN fields.fieldName = 'title' THEN itemDataValues.value END) as title,
      GROUP_CONCAT(CASE WHEN fields.fieldName = 'date' THEN itemDataValues.value END) as date,
      GROUP_CONCAT(CASE WHEN fields.fieldName = 'publicationTitle' THEN itemDataValues.value END) as publication,
      GROUP_CONCAT(CASE WHEN fields.fieldName = 'url' THEN itemDataValues.value END) as url,
      GROUP_CONCAT(CASE WHEN fields.fieldName = 'extra' THEN itemDataValues.value END) as extra,
      GROUP_CONCAT(CASE WHEN fields.fieldName = 'abstractNote' THEN itemDataValues.value END) as abstract
    FROM items
    LEFT JOIN itemTypes ON items.itemTypeID = itemTypes.itemTypeID
    LEFT JOIN itemData ON items.itemID = itemData.itemID
    LEFT JOIN fields ON itemData.fieldID = fields.fieldID
    LEFT JOIN itemDataValues ON itemData.valueID = itemDataValues.valueID
    WHERE items.itemID NOT IN (SELECT itemID FROM deletedItems)
      AND itemTypes.typeName NOT IN ('attachment', 'note')
    GROUP BY items.itemID
    LIMIT 1000
  ]]

  local result, err = execute_sqlite_query(db_path, query)
  if not result then
    vim.notify("Failed to query Zotero database: " .. (err or "unknown error"), vim.log.levels.ERROR)
    return nil
  end

  local rows = parse_sqlite_result(result)
  local references = {}

  if #rows == 0 then
    vim.notify("No items found in Zotero database. Make sure Zotero has references.", vim.log.levels.WARN)
    return {}
  end

  for _, row in ipairs(rows) do
    if #row >= 3 then
      local item_id = row[1]
      local item_key = row[2]
      local item_type = row[3]
      local title = row[4] or "Untitled"
      local date = row[5] or ""
      local publication = row[6] or ""
      local url = row[7] or ""
      local extra = row[8] or ""
      local abstract = row[9] or ""

      -- Extract year from date
      local year = date:match("(%d%d%d%d)") or ""

      -- Get authors from pre-built map (no additional query!)
      local authors = authors_map[item_id] or {}

      -- Format authors string
      local authors_str = ""
      if #authors > 0 then
        if #authors == 1 then
          authors_str = authors[1].lastName
        elseif #authors == 2 then
          authors_str = authors[1].lastName .. " & " .. authors[2].lastName
        else
          authors_str = authors[1].lastName .. " et al."
        end
      end

      -- Parse extra field for custom fields
      local extra_fields = parse_extra_field(extra)

      table.insert(references, {
        itemID = item_id,
        itemKey = item_key,
        title = title,
        year = year,
        date = date,
        authors = authors_str,
        publication = publication,
        url = url,
        type = item_type,
        zotero_uri = "zotero://select/library/items/" .. item_key,
        abbreviation = extra_fields["abbreviation"] or "",
        organization = extra_fields["organization"] or "",
        eventshort = extra_fields["eventshort"] or "",
        abstract = abstract,
        extra_fields = extra_fields, -- Store all parsed fields
      })
    end
  end

  return references
end

-- Load references (from cache or database)
local function load_references(force_refresh)
  force_refresh = force_refresh or false

  -- Check if cache is valid
  if not force_refresh and cache.references then
    local age = os.time() - cache.last_update
    if age < config.cache_expiration then
      return cache.references
    end
  end

  -- Try to load from cache file if not forcing refresh
  if not force_refresh then
    local cached_data = read_cache()
    if cached_data and cached_data.timestamp then
      local age = os.time() - cached_data.timestamp
      if age < config.cache_expiration then
        cache.references = cached_data.references
        cache.last_update = cached_data.timestamp
        return cache.references
      end
    end
  end

  -- Load from database
  local references = load_references_from_db()
  if references then
    cache.references = references
    cache.last_update = os.time()

    -- Write to cache file
    write_cache({
      timestamp = cache.last_update,
      references = references,
    })
  end

  return references
end

-- Refresh references in background (internal function)
local function refresh_references(callback)
  if cache.loading then
    if callback then
      callback(false, "Already loading")
    end
    return
  end

  cache.loading = true

  vim.schedule(function()
    local references = load_references(true)
    cache.loading = false

    if references then
      if callback then
        callback(true)
      end
    else
      if callback then
        callback(false, "Failed to load references")
      end
    end
  end)
end

-- Format citation string
local function format_citation(reference)
  local format = config.citation_format
  local citation = format
    :gsub("{title}", reference.title or "")
    :gsub("{year}", reference.year or "")
    :gsub("{authors}", reference.authors or "")
    :gsub("{publication}", reference.publication or "")
    :gsub("{type}", reference.type or "")
    :gsub("{abbreviation}", reference.abbreviation or "")
    :gsub("{organization}", reference.organization or "")
    :gsub("{eventshort}", reference.eventshort or "")
    :gsub("{abstract}", reference.abstract or "")

  -- Fallback to default format if citation is empty or only whitespace
  if citation:match("^%s*$") then
    local title = reference.title or "Untitled"
    local year = reference.year or ""
    citation = year ~= "" and (title .. " (" .. year .. ")") or title
  end

  return string.format("[%s](%s)", citation, reference.zotero_uri)
end

-- Insert reference at cursor
local function insert_reference(reference)
  local citation = format_citation(reference)
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local new_line = line:sub(1, col) .. citation .. line:sub(col + 1)
  vim.api.nvim_set_current_line(new_line)

  -- Move cursor after inserted text
  vim.api.nvim_win_set_cursor(0, { row, col + #citation })
end

-- Show reference picker
function M.pick_reference()
  -- Check if we're in a markdown file
  if not is_markdown_file() then
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
  local previewers = require("telescope.previewers")
  local entry_display = require("telescope.pickers.entry_display")

  -- Load references
  local references = load_references()
  if not references or #references == 0 then
    vim.notify("No Zotero references found", vim.log.levels.WARN)
    return
  end

  -- Calculate dynamic column widths (zotcite approach)
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

  -- Create picker with zotcite-style UI
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
          ordinal = (entry.abbreviation and entry.abbreviation ~= "" and "(" .. entry.abbreviation .. ") " or "")
            .. (entry.title or "")
            .. " "
            .. (entry.authors or "")
            .. " "
            .. (entry.year or ""),
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = previewers.new_buffer_previewer({
      define_preview = function(self, entry)
        local ref = entry.value

        -- Build preview using configurable format
        local format = config.preview_format
        local highlights = {}
        local pos = 0
        local parts = {}

        -- Process format character by character, tracking positions
        local i = 1
        while i <= #format do
          local found_placeholder = false

          -- Check for placeholders
          local placeholders = {
            { pattern = "{abbreviation}", value = ref.abbreviation or "", group = "String" },
            { pattern = "{title}", value = ref.title or "", group = "Title" },
            { pattern = "{year}", value = ref.year or "", group = "Number" },
            { pattern = "{authors}", value = ref.authors or "", group = "Identifier" },
            { pattern = "{organization}", value = ref.organization or "", group = "Comment" },
            { pattern = "{publication}", value = ref.publication or "", group = "Include" },
            { pattern = "{eventshort}", value = ref.eventshort or "", group = "Include" },
            { pattern = "{type}", value = ref.type or "", group = "Comment" },
            { pattern = "{url}", value = ref.url or "", group = "Underlined" },
            { pattern = "{abstract}", value = ref.abstract or "", group = "Comment" },
          }

          for _, ph in ipairs(placeholders) do
            if format:sub(i, i + #ph.pattern - 1) == ph.pattern then
              if ph.value ~= "" then
                table.insert(parts, ph.value)
                table.insert(highlights, {
                  group = ph.group,
                  start_pos = pos,
                  end_pos = pos + #ph.value,
                })
                pos = pos + #ph.value
              end
              i = i + #ph.pattern
              found_placeholder = true
              break
            end
          end

          -- If no placeholder found, copy the character
          if not found_placeholder then
            local char = format:sub(i, i)
            table.insert(parts, char)
            pos = pos + #char
            i = i + 1
          end
        end

        -- Build final text (minimal cleanup to preserve highlight positions)
        local preview_text = table.concat(parts)
          :gsub("%s+", " ")  -- Collapse multiple spaces
          :gsub("^%s+", "")  -- Trim leading space

        -- Note: We don't remove empty parentheses/brackets to preserve highlight positions
        -- Users should design their preview_format to avoid this issue

        local bufnr = self.state.bufnr
        local winid = self.state.winid

        -- Set buffer content (just show the formatted preview)
        local lines = {}
        for line in preview_text:gmatch("[^\n]+") do
          table.insert(lines, line)
        end
        if #lines == 0 then
          lines = { preview_text }
        end
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

        -- Enable text wrapping (window-local options)
        if winid and vim.api.nvim_win_is_valid(winid) then
          vim.api.nvim_set_option_value("wrap", true, { win = winid })
          vim.api.nvim_set_option_value("linebreak", true, { win = winid })
          vim.api.nvim_set_option_value("breakindent", true, { win = winid })
        end

        -- Apply syntax highlighting
        local ns = vim.api.nvim_create_namespace("zotero_md_preview")

        for _, hl in ipairs(highlights) do
          -- Use version-aware highlighting
          if vim.fn.has("nvim-0.11") == 1 then
            vim.hl.range(bufnr, ns, hl.group, { 0, hl.start_pos }, { 0, hl.end_pos }, {})
          else
            vim.api.nvim_buf_add_highlight(bufnr, ns, hl.group, 0, hl.start_pos, hl.end_pos)
          end
        end
      end,
    }),
    attach_mappings = function(prompt_bufnr, map)
      map({ "i", "n" }, "<CR>", function()
        local selection = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if selection then
          insert_reference(selection.value)
        end
      end)
      return true
    end,
  }

  pickers.new(opts, {}):find()
end

-- Setup autocmd for auto-update
local function setup_auto_update()
  if not config.auto_update then
    return
  end

  local last_auto_update = 0

  vim.api.nvim_create_autocmd({ "BufEnter" }, {
    pattern = { "*.md", "*.markdown" },
    callback = function()
      if is_markdown_file() then
        local now = os.time()
        if now - last_auto_update >= config.auto_update_interval then
          last_auto_update = now
          refresh_references()
        end
      end
    end,
  })
end

-- Debug function to test database connection
function M.debug_db()
  local db_path = config.zotero_db_path or default_config.zotero_db_path

  print("Zotero Database Path: " .. db_path)
  print("Database exists: " .. tostring(vim.fn.filereadable(db_path) == 1))

  if vim.fn.filereadable(db_path) ~= 1 then
    print("ERROR: Database file not found!")
    return
  end

  -- Test simple query
  local test_query = "SELECT COUNT(*) FROM items WHERE itemID NOT IN (SELECT itemID FROM deletedItems);"
  local result, err = execute_sqlite_query(db_path, test_query)

  if err then
    print("ERROR: " .. err)
    return
  end

  print("Total items in database: " .. (result or "unknown"))
  print("\nTrying to load references...")

  local refs = load_references_from_db()
  if refs then
    print("Successfully loaded " .. #refs .. " references")
    if #refs > 0 then
      print("\nFirst reference:")
      local r = refs[1]
      print("  Title: " .. r.title)
      print("  Authors: " .. r.authors)
      print("  Year: " .. r.year)
    end
  else
    print("Failed to load references")
  end
end

-- Setup keymaps
local function setup_keymaps()
  if not config.keymaps or config.keymaps == false then
    return
  end

  if config.keymaps.insert_mode then
    vim.keymap.set("i", config.keymaps.insert_mode, function()
      if is_markdown_file() then
        M.pick_reference()
      end
    end, { desc = "Pick Zotero reference" })
  end
end

-- Setup function
function M.setup(user_config)
  -- Merge user config with defaults
  config = vim.tbl_deep_extend("force", default_config, user_config or {})

  -- Setup keymaps
  setup_keymaps()

  -- Preload references
  if config.preload then
    vim.defer_fn(function()
      refresh_references()
    end, config.preload_delay)
  end

  -- Setup auto-update
  setup_auto_update()
end

return M
