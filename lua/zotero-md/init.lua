local M = {}

-- Default configuration
local default_config = {
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
  -- Prioritize creator types: author, artist, performer, director, etc.
  local authors_query = [[
    SELECT items.itemID, creators.lastName, creators.firstName, creatorTypes.creatorType,
      CASE creatorTypes.creatorType
        WHEN 'author' THEN 1
        WHEN 'artist' THEN 2
        WHEN 'performer' THEN 3
        WHEN 'director' THEN 4
        WHEN 'composer' THEN 5
        WHEN 'sponsor' THEN 6
        WHEN 'contributor' THEN 7
        WHEN 'interviewee' THEN 8
        WHEN 'cartographer' THEN 9
        WHEN 'inventor' THEN 10
        WHEN 'podcaster' THEN 11
        WHEN 'presenter' THEN 12
        WHEN 'programmer' THEN 13
        WHEN 'recipient' THEN 14
        WHEN 'editor' THEN 15
        WHEN 'seriesEditor' THEN 16
        WHEN 'translator' THEN 17
        ELSE 99
      END as priority
    FROM items, itemCreators, creators, creatorTypes
    WHERE items.itemID = itemCreators.itemID
      AND itemCreators.creatorID = creators.creatorID
      AND itemCreators.creatorTypeID = creatorTypes.creatorTypeID
      AND items.itemID NOT IN (SELECT itemID FROM deletedItems)
    ORDER BY items.itemID, priority, itemCreators.orderIndex
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
        -- row[4] = creatorType, row[5] = priority (not needed in processing)

        if last_name ~= "" then
          if not authors_map[item_id] then
            authors_map[item_id] = {}
          end
          -- Only keep first 3 authors (already sorted by priority)
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
      items.dateModified,
      GROUP_CONCAT(CASE WHEN fields.fieldName = 'title' THEN itemDataValues.value END) as title,
      GROUP_CONCAT(CASE WHEN fields.fieldName = 'date' THEN itemDataValues.value END) as date,
      COALESCE(
        GROUP_CONCAT(CASE WHEN fields.fieldName = 'publicationTitle' THEN itemDataValues.value END),
        GROUP_CONCAT(CASE WHEN fields.fieldName = 'bookTitle' THEN itemDataValues.value END),
        GROUP_CONCAT(CASE WHEN fields.fieldName = 'publisher' THEN itemDataValues.value END),
        GROUP_CONCAT(CASE WHEN fields.fieldName = 'proceedingsTitle' THEN itemDataValues.value END),
        GROUP_CONCAT(CASE WHEN fields.fieldName = 'conferenceName' THEN itemDataValues.value END),
        GROUP_CONCAT(CASE WHEN fields.fieldName = 'programTitle' THEN itemDataValues.value END),
        GROUP_CONCAT(CASE WHEN fields.fieldName = 'blogTitle' THEN itemDataValues.value END),
        GROUP_CONCAT(CASE WHEN fields.fieldName = 'code' THEN itemDataValues.value END),
        GROUP_CONCAT(CASE WHEN fields.fieldName = 'dictionaryTitle' THEN itemDataValues.value END),
        GROUP_CONCAT(CASE WHEN fields.fieldName = 'encyclopediaTitle' THEN itemDataValues.value END),
        GROUP_CONCAT(CASE WHEN fields.fieldName = 'forumTitle' THEN itemDataValues.value END),
        GROUP_CONCAT(CASE WHEN fields.fieldName = 'websiteTitle' THEN itemDataValues.value END),
        GROUP_CONCAT(CASE WHEN fields.fieldName = 'seriesTitle' THEN itemDataValues.value END)
      ) as publication,
      GROUP_CONCAT(CASE WHEN fields.fieldName = 'url' THEN itemDataValues.value END) as url,
      GROUP_CONCAT(CASE WHEN fields.fieldName = 'extra' THEN itemDataValues.value END) as extra,
      GROUP_CONCAT(CASE WHEN fields.fieldName = 'abstractNote' THEN itemDataValues.value END) as abstract
    FROM items
    LEFT JOIN itemTypes ON items.itemTypeID = itemTypes.itemTypeID
    LEFT JOIN itemData ON items.itemID = itemData.itemID
    LEFT JOIN fields ON itemData.fieldID = fields.fieldID
    LEFT JOIN itemDataValues ON itemData.valueID = itemDataValues.valueID
    WHERE items.itemID NOT IN (SELECT itemID FROM deletedItems)
      AND itemTypes.typeName NOT IN ('attachment', 'note', 'annotation')
    GROUP BY items.itemID
    ORDER BY items.dateModified DESC
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
      local date_modified = row[4] or ""
      local title = row[5]
      -- Handle both nil and empty string
      if not title or title == "" then
        title = "Untitled"
      end
      local date = row[6] or ""
      local publication = row[7] or ""
      local url = row[8] or ""
      local extra = row[9] or ""
      local abstract = row[10] or ""

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
    :gsub("{key}", reference.itemKey or "")

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
        local preview_text = format
        local markers_to_replace = {}  -- Track markers that need to be replaced with values
        for _, ph in ipairs(placeholder_values) do
          if ph.value ~= "" then
            preview_text = preview_text:gsub(vim.pesc(ph.pattern), ph.marker)
            markers_to_replace[ph.marker] = { value = ph.value, group = ph.group }
          else
            -- Remove empty placeholders
            preview_text = preview_text:gsub(vim.pesc(ph.pattern), "")
          end
        end

        -- Second pass: cleanup formatting (markers preserve positions)
        preview_text = preview_text
          :gsub("%s+", " ")  -- Collapse multiple spaces
          :gsub("^%s+", "")  -- Trim leading space
          :gsub("%s*%(%s*%)", "")  -- Remove empty parentheses with optional spaces
          :gsub("%s*%[%s*%]", "")  -- Remove empty brackets with optional spaces
          :gsub("%s*{%s*}", "")  -- Remove empty braces with optional spaces
          :gsub(",%s*,", ",")  -- Remove double commas
          :gsub("^%s*,", "")  -- Remove leading comma
          :gsub(",%s*$", "")  -- Remove trailing comma
          :gsub("%s+", " ")  -- Collapse spaces again after cleanup

        -- Third pass: replace markers with values and track highlight positions
        -- Process in order of appearance in format string
        local highlights = {}
        for _, ph in ipairs(placeholder_values) do
          if markers_to_replace[ph.marker] then
            local data = markers_to_replace[ph.marker]
            local start_idx = 1
            while true do
              local found_start, found_end = preview_text:find(vim.pesc(ph.marker), start_idx, true)
              if not found_start then
                break
              end
              -- Replace marker with actual value
              preview_text = preview_text:sub(1, found_start - 1) .. data.value .. preview_text:sub(found_end + 1)
              -- Record highlight position
              table.insert(highlights, {
                group = data.group,
                start_pos = found_start - 1,  -- 0-indexed
                end_pos = found_start - 1 + #data.value,  -- 0-indexed, exclusive
              })
              -- Update search position (account for length difference)
              start_idx = found_start + #data.value
            end
          end
        end

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
function M.debug_db(key)
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

    -- If a specific key is provided, show only that item
    if key and key ~= "" then
      print("\nSearching for item with key: " .. key)
      local found = false
      for _, r in ipairs(refs) do
        if r.itemKey == key then
          found = true
          print(string.format("\nTitle: %s", r.title))
          print(string.format("Key: %s", r.itemKey))
          print(string.format("Authors: %s", r.authors))
          print(string.format("Year: %s", r.year))
          print(string.format("Type: %s", r.type))
          print(string.format("Publication: %s", r.publication or "(empty)"))
          print(string.format("Abstract: %s", r.abstract and r.abstract:sub(1, 100) .. "..." or "(empty)"))
          print(string.format("URL: %s", r.url or "(empty)"))
          if r.extra_fields and next(r.extra_fields) then
            print("Extra fields parsed:")
            for k, v in pairs(r.extra_fields) do
              print(string.format("  %s: %s", k, v))
            end
          end

          -- Add raw SQL debug for this specific item
          print("\n--- Raw SQL Debug ---")
          local raw_query = string.format([[
            SELECT fields.fieldName, itemDataValues.value
            FROM items
            JOIN itemData ON items.itemID = itemData.itemID
            JOIN fields ON itemData.fieldID = fields.fieldID
            JOIN itemDataValues ON itemData.valueID = itemDataValues.valueID
            WHERE items.key = '%s'
            ORDER BY fields.fieldName
          ]], key)
          local raw_result, raw_err = execute_sqlite_query(db_path, raw_query)
          if raw_result then
            local raw_rows = parse_sqlite_result(raw_result)
            print("All fields from database:")
            for _, row in ipairs(raw_rows) do
              print(string.format("  %s = %s", row[1] or "", row[2] or ""))
            end
          else
            print("Error querying raw data: " .. (raw_err or "unknown"))
          end

          -- Test the actual SELECT query for this specific item
          print("\n--- Main Query Result ---")
          local test_query = string.format([[
            SELECT
              items.key,
              GROUP_CONCAT(CASE WHEN fields.fieldName = 'title' THEN itemDataValues.value END) as title,
              GROUP_CONCAT(CASE WHEN fields.fieldName = 'date' THEN itemDataValues.value END) as date,
              COALESCE(
                GROUP_CONCAT(CASE WHEN fields.fieldName = 'publicationTitle' THEN itemDataValues.value END),
                GROUP_CONCAT(CASE WHEN fields.fieldName = 'bookTitle' THEN itemDataValues.value END),
                GROUP_CONCAT(CASE WHEN fields.fieldName = 'publisher' THEN itemDataValues.value END)
              ) as publication
            FROM items
            LEFT JOIN itemTypes ON items.itemTypeID = itemTypes.itemTypeID
            LEFT JOIN itemData ON items.itemID = itemData.itemID
            LEFT JOIN fields ON itemData.fieldID = fields.fieldID
            LEFT JOIN itemDataValues ON itemData.valueID = itemDataValues.valueID
            WHERE items.key = '%s'
            GROUP BY items.itemID
          ]], key)
          local test_result, test_err = execute_sqlite_query(db_path, test_query)
          if test_result then
            local test_rows = parse_sqlite_result(test_result)
            if #test_rows > 0 then
              print(string.format("  key = %s", test_rows[1][1] or "(null)"))
              print(string.format("  title = %s", test_rows[1][2] or "(null)"))
              print(string.format("  date = %s", test_rows[1][3] or "(null)"))
              print(string.format("  publication = %s", test_rows[1][4] or "(null)"))
            end
          else
            print("Error running main query: " .. (test_err or "unknown"))
          end

          break
        end
      end
      if not found then
        print("ERROR: Item with key '" .. key .. "' not found")
      end
      return
    end

    -- Count untitled entries and their types
    local untitled_count = 0
    local untitled_types = {}
    for _, r in ipairs(refs) do
      if r.title == "Untitled" then
        untitled_count = untitled_count + 1
        untitled_types[r.type] = (untitled_types[r.type] or 0) + 1
      end
    end
    print("Untitled entries: " .. untitled_count)

    if untitled_count > 0 then
      print("\nUntitled entries by type:")
      for item_type, count in pairs(untitled_types) do
        print(string.format("  %s: %d", item_type, count))
      end
    end

    if #refs > 0 then
      print("\nFirst 5 references:")
      for i = 1, math.min(5, #refs) do
        local r = refs[i]
        print(string.format("%d. Title: %s | Authors: %s | Year: %s | Type: %s | Key: %s",
          i, r.title, r.authors, r.year, r.type, r.itemKey))
        print(string.format("   Publication: %s", r.publication or "(empty)"))
        if r.extra_fields and next(r.extra_fields) then
          print("   Extra fields parsed:")
          for k, v in pairs(r.extra_fields) do
            print(string.format("     %s: %s", k, v))
          end
        end
      end
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
