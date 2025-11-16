-- Parser for extra fields and citation formatting
local M = {}

-- Parse extra field for custom fields (e.g., "Abbreviation: GPT2 (2019)\nOrganization: OpenAI")
function M.parse_extra_field(extra)
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

-- Format citation string
function M.format_citation(reference, citation_format)
  local citation = citation_format
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

return M
