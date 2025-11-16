-- Database operations for zotero-md
local utils = require("zotero-md.utils")
local parser = require("zotero-md.parser")

local M = {}

-- Temporary database state
local temp_db_path = nil
local temp_db_mtime = 0

-- Copy database to temp location to avoid locks
local function get_temp_db(db_path)
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
function M.execute_query(db_path, query)
  -- Use a temporary copy of the database to avoid lock issues
  local actual_db_path, err = get_temp_db(db_path)
  if not actual_db_path then
    return nil, err or "Failed to access database"
  end

  -- Use ASCII record separator (0x1E) and field separator (0x1F) to avoid conflicts with data
  local cmd = string.format('sqlite3 -cmd ".separator \x1F \x1E" "%s" "%s" 2>&1', actual_db_path, query)
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

-- Load references from Zotero database
function M.load_references(db_path)
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

  local authors_result, err = M.execute_query(db_path, authors_query)
  if not authors_result then
    vim.notify("Failed to query authors: " .. (err or "unknown error"), vim.log.levels.WARN)
  end

  -- Build a map of itemID -> authors
  local authors_map = {}
  if authors_result then
    local authors_rows = utils.parse_sqlite_result(authors_result)
    for _, row in ipairs(authors_rows) do
      if #row >= 2 then
        local item_id = row[1]
        local last_name = row[2] or ""
        local first_name = row[3] or ""

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

  -- Query 2: Get all item data
  local query = [[
    SELECT
      items.itemID,
      items.key,
      itemTypes.typeName,
      items.dateModified,
      MAX(CASE WHEN fields.fieldName = 'title' THEN itemDataValues.value END) as title,
      MAX(CASE WHEN fields.fieldName = 'date' THEN itemDataValues.value END) as date,
      COALESCE(
        MAX(CASE WHEN fields.fieldName = 'publicationTitle' THEN itemDataValues.value END),
        MAX(CASE WHEN fields.fieldName = 'bookTitle' THEN itemDataValues.value END),
        MAX(CASE WHEN fields.fieldName = 'publisher' THEN itemDataValues.value END),
        MAX(CASE WHEN fields.fieldName = 'proceedingsTitle' THEN itemDataValues.value END),
        MAX(CASE WHEN fields.fieldName = 'conferenceName' THEN itemDataValues.value END),
        MAX(CASE WHEN fields.fieldName = 'programTitle' THEN itemDataValues.value END),
        MAX(CASE WHEN fields.fieldName = 'blogTitle' THEN itemDataValues.value END),
        MAX(CASE WHEN fields.fieldName = 'code' THEN itemDataValues.value END),
        MAX(CASE WHEN fields.fieldName = 'dictionaryTitle' THEN itemDataValues.value END),
        MAX(CASE WHEN fields.fieldName = 'encyclopediaTitle' THEN itemDataValues.value END),
        MAX(CASE WHEN fields.fieldName = 'forumTitle' THEN itemDataValues.value END),
        MAX(CASE WHEN fields.fieldName = 'websiteTitle' THEN itemDataValues.value END),
        MAX(CASE WHEN fields.fieldName = 'seriesTitle' THEN itemDataValues.value END)
      ) as publication,
      MAX(CASE WHEN fields.fieldName = 'url' THEN itemDataValues.value END) as url,
      MAX(CASE WHEN fields.fieldName = 'extra' THEN itemDataValues.value END) as extra,
      MAX(CASE WHEN fields.fieldName = 'abstractNote' THEN itemDataValues.value END) as abstract
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

  local result, err = M.execute_query(db_path, query)
  if not result then
    vim.notify("Failed to query Zotero database: " .. (err or "unknown error"), vim.log.levels.ERROR)
    return nil
  end

  local rows = utils.parse_sqlite_result(result)
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

      -- Get authors from pre-built map
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
      local extra_fields = parser.parse_extra_field(extra)

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
        extra_fields = extra_fields,
      })
    end
  end

  return references
end

return M
