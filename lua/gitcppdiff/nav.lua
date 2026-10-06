-- :CppDiffNext / :CppDiffPrev — step through the changes of the last run from any buffer.
local api = vim.api
local model_m = require("gitcppdiff.model")
local marks_m = require("gitcppdiff.marks")
local preview = require("gitcppdiff.preview")
local jump = require("gitcppdiff.jump")
local cfgm = require("gitcppdiff.config")

local M = {}

---@type table|nil { data, marks, args, expand }
M.last = nil

function M.remember(data, marks, args, expand)
  M.last = { data = data, marks = marks, args = args or {}, expand = expand }
end

local STATUS_LABEL = {
  added = "added", removed = "removed", modified = "modified", ["api-change"] = "API change", renamed = "renamed",
}
local STATUS_HL = {
  added = "GitCppDiffAdded", removed = "GitCppDiffRemoved", modified = "GitCppDiffModified",
  ["api-change"] = "GitCppDiffApi", renamed = "GitCppDiffRenamed",
}

--- Visible changes (same rules as the window: filter + collapsed members), ordered file/line.
local function items(filter)
  local last = M.last
  local marks = cfgm.options.persist and marks_m.load(last.data.root) or last.marks
  local model = model_m.build(last.data, { expand = last.expand })
  local rows = model_m.flatten(model, marks, filter, {})
  local out = {}
  for _, r in ipairs(rows) do
    if r.node.change and r.show_own then out[#out + 1] = r.node.change end
  end
  table.sort(out, function(a, b)
    if a.file ~= b.file then return a.file < b.file end
    return a.line < b.line
  end)
  return out
end

local function cur_pos(root)
  local name = api.nvim_buf_get_name(0)
  local rel
  if name:find("^gitcppdiff://") then
    rel = name:match("^gitcppdiff://[^/]+/(.*)$")
  elseif name ~= "" then
    rel = vim.fs.relpath(root, vim.fs.normalize(name))
  end
  return rel or "", api.nvim_win_get_cursor(0)[1]
end

local function before(a_file, a_line, b_file, b_line)
  if a_file ~= b_file then return a_file < b_file end
  return a_line < b_line
end

local function go(filter, dir, count)
  local list = items(filter)
  if #list == 0 then
    vim.notify("gitcppdiff: nothing to visit (all changes hidden or reviewed)", vim.log.levels.INFO)
    return
  end
  local file, line = cur_pos(M.last.data.root)
  local idx
  if dir > 0 then
    for i, c in ipairs(list) do
      if before(file, line, c.file, c.line) then idx = i break end
    end
    idx = idx or 1
  else
    for i = #list, 1, -1 do
      if before(list[i].file, list[i].line, file, line) then idx = i break end
    end
    idx = idx or #list
  end
  local wrapped = false
  for _ = 2, count do
    idx = idx + dir
    if idx > #list then idx, wrapped = 1, true elseif idx < 1 then idx, wrapped = #list, true end
  end
  local c = list[idx]
  jump.open(M.last.data, preview.target(c))
  api.nvim_echo({
    { string.format("gitcppdiff %d/%d ", idx, #list), "GitCppDiffTitle" },
    { "[" .. (STATUS_LABEL[c.status] or c.status) .. "] ", STATUS_HL[c.status] or "Normal" },
    { c.qualified_name .. (wrapped and "  (wrapped)" or ""), "Normal" },
  }, false, {})
end

--- dir = 1 / -1. With the window open this moves the cursor in the list instead.
function M.step(dir, count)
  count = math.max(1, count or 1)
  local ui = require("gitcppdiff.ui")
  if ui.is_open() then return ui.step(dir, count) end
  if not M.last then
    ui.load({}, function(data)
      ui.remember(data, {})
      go(ui.get_filter(), dir, count)
    end)
    return
  end
  go(ui.get_filter(), dir, count)
end

return M
