-- Cache management for zotero-md
local M = {}

-- Cache state
local cache = {
  references = nil,
  last_update = 0,
  loading = false,
}

-- Read cache from file
function M.read(cache_file)
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
function M.write(cache_file, data)
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

-- Get cached references
function M.get_references()
  return cache.references
end

-- Set cached references
function M.set_references(references)
  cache.references = references
  cache.last_update = os.time()
end

-- Get cache age in seconds
function M.get_age()
  return os.time() - cache.last_update
end

-- Check if cache is valid
function M.is_valid(expiration)
  return cache.references ~= nil and M.get_age() < expiration
end

-- Get loading state
function M.is_loading()
  return cache.loading
end

-- Set loading state
function M.set_loading(loading)
  cache.loading = loading
end

return M
