-- zotero-md.nvim - Insert Zotero references into markdown files
local config = require("zotero-md.config")
local cache = require("zotero-md.cache")
local database = require("zotero-md.database")
local parser = require("zotero-md.parser")
local ui = require("zotero-md.ui")
local utils = require("zotero-md.utils")

local M = {}

-- Load references (from cache or database)
local function load_references(force_refresh)
  force_refresh = force_refresh or false

  -- Check if cache is valid
  if not force_refresh and cache.is_valid(config.get("cache_expiration")) then
    return cache.get_references()
  end

  -- Try to load from cache file if not forcing refresh
  if not force_refresh then
    local cached_data = cache.read(config.get("cache_file"))
    if cached_data and cached_data.timestamp then
      local age = os.time() - cached_data.timestamp
      if age < config.get("cache_expiration") then
        cache.set_references(cached_data.references)
        return cached_data.references
      end
    end
  end

  -- Load from database
  local references = database.load_references(config.get("zotero_db_path"))
  if references then
    cache.set_references(references)

    -- Write to cache file
    cache.write(config.get("cache_file"), {
      timestamp = os.time(),
      references = references,
    })
  end

  return references
end

-- Refresh references in background
local function refresh_references(callback)
  if cache.is_loading() then
    if callback then
      callback(false, "Already loading")
    end
    return
  end

  cache.set_loading(true)

  vim.schedule(function()
    local references = load_references(true)
    cache.set_loading(false)

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

-- Insert reference at cursor
local function insert_reference(reference)
  local citation = parser.format_citation(reference, config.get("citation_format"))
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local line = vim.api.nvim_get_current_line()
  local new_line = line:sub(1, col) .. citation .. line:sub(col + 1)
  vim.api.nvim_set_current_line(new_line)

  -- Move cursor after inserted text
  vim.api.nvim_win_set_cursor(0, { row, col + #citation })
end

-- Show reference picker
function M.pick_reference()
  -- Load references
  local references = load_references()
  if not references or #references == 0 then
    vim.notify("No Zotero references found", vim.log.levels.WARN)
    return
  end

  -- Show picker
  ui.show_picker(references, config.current, insert_reference)
end

-- Show info for reference under cursor
function M.show_reference_info()
  -- Check if we're in a markdown file
  if not utils.is_markdown_file() then
    vim.notify("ZoteroInfo only works in markdown files", vim.log.levels.WARN)
    return
  end

  -- Find link under cursor
  local key = ui.find_link_under_cursor()
  if not key then
    vim.notify("No Zotero reference link found under cursor", vim.log.levels.WARN)
    return
  end

  -- Load references
  local references = load_references()
  if not references or #references == 0 then
    vim.notify("No Zotero references loaded", vim.log.levels.WARN)
    return
  end

  -- Find the reference
  local ref = nil
  for _, r in ipairs(references) do
    if r.itemKey == key then
      ref = r
      break
    end
  end

  if not ref then
    vim.notify("Reference not found: " .. key, vim.log.levels.WARN)
    return
  end

  -- Show info window
  ui.show_reference_info(ref)
end

-- Debug function to test database connection
function M.debug_db(key)
  local db_path = config.get("zotero_db_path")

  print("Zotero Database Path: " .. db_path)
  print("Database exists: " .. tostring(vim.fn.filereadable(db_path) == 1))

  if vim.fn.filereadable(db_path) ~= 1 then
    print("ERROR: Database file not found!")
    return
  end

  -- Test simple query
  local test_query = "SELECT COUNT(*) FROM items WHERE itemID NOT IN (SELECT itemID FROM deletedItems);"
  local result, err = database.execute_query(db_path, test_query)

  if err then
    print("ERROR: " .. err)
    return
  end

  print("Total items in database: " .. (result or "unknown"))
  print("\nTrying to load references...")

  local refs = database.load_references(db_path)
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

          -- Show raw extra field from query
          local extra_query = string.format([[
            SELECT itemDataValues.value
            FROM items
            JOIN itemData ON items.itemID = itemData.itemID
            JOIN fields ON itemData.fieldID = fields.fieldID
            JOIN itemDataValues ON itemData.valueID = itemDataValues.valueID
            WHERE items.key = '%s' AND fields.fieldName = 'extra'
          ]], key)
          local extra_result, extra_err = database.execute_query(db_path, extra_query)
          if extra_result and extra_result ~= "" then
            print("\nRaw Extra field from database:")
            print("---START---")
            print(extra_result)
            print("---END---")
          end

          if r.extra_fields and next(r.extra_fields) then
            print("\nExtra fields parsed:")
            for k, v in pairs(r.extra_fields) do
              print(string.format("  %s: %s", k, v))
            end
          else
            print("\nExtra fields parsed: (none)")
          end

          -- Add raw SQL debug for this specific item
          print("\n--- Raw SQL Debug ---")
          local raw_query = string.format([[
            SELECT fields.fieldName, itemDataValues.value, itemData.itemID, itemData.fieldID, itemData.valueID
            FROM items
            JOIN itemData ON items.itemID = itemData.itemID
            JOIN fields ON itemData.fieldID = fields.fieldID
            JOIN itemDataValues ON itemData.valueID = itemDataValues.valueID
            WHERE items.key = '%s'
            ORDER BY itemData.itemID, itemData.fieldID
          ]], key)
          local raw_result, raw_err = database.execute_query(db_path, raw_query)
          if raw_result then
            local raw_rows = utils.parse_sqlite_result(raw_result)
            print("All itemData rows (fieldName | value | itemID | fieldID | valueID):")
            for _, row in ipairs(raw_rows) do
              print(string.format("  %s | %s | %s | %s | %s",
                row[1] or "(null)", row[2] or "(null)", row[3] or "(null)", row[4] or "(null)", row[5] or "(null)"))
            end
          else
            print("Error querying raw data: " .. (raw_err or "unknown"))
          end

          -- Test the actual SELECT query for this specific item
          print("\n--- Main Query Result ---")
          local test_query = string.format([[
            SELECT
              items.key,
              MAX(CASE WHEN fields.fieldName = 'title' THEN itemDataValues.value END) as title,
              MAX(CASE WHEN fields.fieldName = 'date' THEN itemDataValues.value END) as date,
              COALESCE(
                MAX(CASE WHEN fields.fieldName = 'publicationTitle' THEN itemDataValues.value END),
                MAX(CASE WHEN fields.fieldName = 'bookTitle' THEN itemDataValues.value END),
                MAX(CASE WHEN fields.fieldName = 'publisher' THEN itemDataValues.value END)
              ) as publication
            FROM items
            LEFT JOIN itemTypes ON items.itemTypeID = itemTypes.itemTypeID
            LEFT JOIN itemData ON items.itemID = itemData.itemID
            LEFT JOIN fields ON itemData.fieldID = fields.fieldID
            LEFT JOIN itemDataValues ON itemData.valueID = itemDataValues.valueID
            WHERE items.key = '%s'
            GROUP BY items.itemID
          ]], key)
          local test_result, test_err = database.execute_query(db_path, test_query)
          if test_result then
            local test_rows = utils.parse_sqlite_result(test_result)
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

-- Setup autocmd for auto-update
local function setup_auto_update()
  if not config.get("auto_update") then
    return
  end

  local last_auto_update = 0

  vim.api.nvim_create_autocmd({ "BufEnter" }, {
    pattern = { "*.md", "*.markdown" },
    callback = function()
      if utils.is_markdown_file() then
        local now = os.time()
        if now - last_auto_update >= config.get("auto_update_interval") then
          last_auto_update = now
          refresh_references()
        end
      end
    end,
  })
end

-- Setup keymaps
local function setup_keymaps()
  local keymaps = config.get("keymaps")
  if not keymaps or keymaps == false then
    return
  end

  if keymaps.insert_mode then
    vim.keymap.set("i", keymaps.insert_mode, function()
      if utils.is_markdown_file() then
        M.pick_reference()
      end
    end, { desc = "Pick Zotero reference" })
  end

  -- Add <leader>zi keymap for showing reference info
  vim.keymap.set("n", "<leader>zi", function()
    M.show_reference_info()
  end, { desc = "Show Zotero reference info" })
end

-- Setup function
function M.setup(user_config)
  -- Merge user config with defaults
  config.setup(user_config)

  -- Setup keymaps
  setup_keymaps()

  -- Preload references
  if config.get("preload") then
    vim.defer_fn(function()
      refresh_references()
    end, config.get("preload_delay"))
  end

  -- Setup auto-update
  setup_auto_update()
end

return M
