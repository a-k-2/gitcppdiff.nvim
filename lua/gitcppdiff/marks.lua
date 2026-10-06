-- Persistent accept / bad marks, keyed by the change id the executable emits
-- (it hashes symbol key + old/new signature + old/new body, so a mark is dropped
-- automatically as soon as the reviewed code changes again).
local M = {}

local function file_for(root)
  local dir = vim.fs.joinpath(vim.fn.stdpath("state"), "gitcppdiff")
  return dir, vim.fs.joinpath(dir, vim.fn.sha256(root):sub(1, 16) .. ".json")
end

---@return table<string,string>
function M.load(root)
  local _, f = file_for(root)
  local fh = io.open(f, "r")
  if not fh then return {} end
  local s = fh:read("*a")
  fh:close()
  local ok, t = pcall(vim.json.decode, s)
  return (ok and type(t) == "table") and t or {}
end

function M.save(root, marks)
  local dir, f = file_for(root)
  vim.fn.mkdir(dir, "p")
  local fh = io.open(f, "w")
  if not fh then return false end
  fh:write(vim.json.encode(marks))
  fh:close()
  return true
end

function M.clear(root)
  local _, f = file_for(root)
  os.remove(f)
end

return M
