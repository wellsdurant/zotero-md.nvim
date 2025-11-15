local M = {}

-- Default configuration
local default_config = {
  zotero_db_path = vim.fn.expand("~/Zotero/zotero.sqlite"),
  cache_file = vim.fn.expand("~/.local/share/nvim/zotero-md-cache.json"),
  cache_expiration = 3600, -- 1 hour in seconds
  citation_format = "{title} ({year})",
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

-- Execute SQLite query
local function execute_sqlite_query(db_path, query)
  local handle = io.popen(string.format('sqlite3 "%s" "%s"', db_path, query))
  if not handle then
    return nil
  end

  local result = handle:read("*all")
  handle:close()

  return result
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

-- Load references from Zotero database
local function load_references_from_db()
  local db_path = config.zotero_db_path

  -- Check if database exists
  if vim.fn.filereadable(db_path) ~= 1 then
    vim.notify("Zotero database not found at: " .. db_path, vim.log.levels.ERROR)
    return nil
  end

  -- Query for main item data
  local query = [[
    SELECT
      items.itemID,
      items.key,
      itemTypes.typeName,
      GROUP_CONCAT(CASE WHEN fields.fieldName = 'title' THEN itemDataValues.value END) as title,
      GROUP_CONCAT(CASE WHEN fields.fieldName = 'date' THEN itemDataValues.value END) as date,
      GROUP_CONCAT(CASE WHEN fields.fieldName = 'publicationTitle' THEN itemDataValues.value END) as publication,
      GROUP_CONCAT(CASE WHEN fields.fieldName = 'url' THEN itemDataValues.value END) as url
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

  local result = execute_sqlite_query(db_path, query)
  if not result then
    vim.notify("Failed to query Zotero database", vim.log.levels.ERROR)
    return nil
  end

  local rows = parse_sqlite_result(result)
  local references = {}

  for _, row in ipairs(rows) do
    if #row >= 3 then
      local item_id = row[1]
      local item_key = row[2]
      local item_type = row[3]
      local title = row[4] or "Untitled"
      local date = row[5] or ""
      local publication = row[6] or ""
      local url = row[7] or ""

      -- Extract year from date
      local year = date:match("(%d%d%d%d)") or ""

      -- Query for authors
      local authors_query = string.format(
        [[
          SELECT creators.lastName, creators.firstName
          FROM itemCreators
          LEFT JOIN creators ON itemCreators.creatorID = creators.creatorID
          WHERE itemCreators.itemID = %s
          ORDER BY itemCreators.orderIndex
          LIMIT 3
        ]],
        item_id
      )

      local authors_result = execute_sqlite_query(db_path, authors_query)
      local authors_rows = parse_sqlite_result(authors_result)
      local authors = {}

      for _, author_row in ipairs(authors_rows) do
        if #author_row >= 1 then
          local last_name = author_row[1] or ""
          local first_name = author_row[2] or ""
          if last_name ~= "" then
            table.insert(authors, { lastName = last_name, firstName = first_name })
          end
        end
      end

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

  -- Load references
  local references = load_references()
  if not references or #references == 0 then
    vim.notify("No Zotero references found", vim.log.levels.WARN)
    return
  end

  -- Create picker
  local opts = vim.tbl_deep_extend("force", config.telescope_opts, {
    finder = finders.new_table({
      results = references,
      entry_maker = function(entry)
        local display = string.format("%s (%s) - %s", entry.title, entry.year, entry.authors)
        return {
          value = entry,
          display = display,
          ordinal = entry.title .. " " .. entry.authors .. " " .. entry.year,
        }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = previewers.new_buffer_previewer({
      define_preview = function(self, entry)
        local ref = entry.value
        local lines = {
          "Title: " .. ref.title,
          "Authors: " .. ref.authors,
          "Year: " .. ref.year,
          "Type: " .. ref.type,
          "Publication: " .. ref.publication,
          "URL: " .. ref.url,
          "",
          "Zotero URI: " .. ref.zotero_uri,
          "",
          "Citation preview:",
          format_citation(ref),
        }
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, lines)
      end,
    }),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        actions.close(prompt_bufnr)
        local selection = action_state.get_selected_entry()
        if selection then
          insert_reference(selection.value)
        end
      end)
      return true
    end,
  })

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

-- Setup function
function M.setup(user_config)
  -- Merge user config with defaults
  config = vim.tbl_deep_extend("force", default_config, user_config or {})

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
