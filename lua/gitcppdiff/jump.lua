-- Opening a change location: the real file when the worktree matches the revision shown,
-- otherwise a read-only scratch buffer with the file as of that revision.
local api = vim.api
local preview = require("gitcppdiff.preview")

local M = {}

--- Does the file in the worktree equal the version the diff talks about?
function M.worktree_matches(d, file)
  if d.head_kind == "worktree" then return true end
  local args = { "git", "-C", d.root, "diff", "--quiet" }
  if d.head_kind == "rev" then args[#args + 1] = d.head_rev end
  vim.list_extend(args, { "--", file })
  return vim.system(args):wait().code == 0
end

--- t = { side = "old"|"new", file = , line = }
function M.open(d, t)
  if t.side == "new" and M.worktree_matches(d, t.file) then
    vim.cmd("edit " .. vim.fn.fnameescape(d.root .. "/" .. t.file))
  else
    local spec, label
    if t.side == "old" then spec, label = d.base_rev .. ":" .. t.file, d.base_rev
    elseif d.head_kind == "index" then spec, label = ":" .. t.file, "index"
    else spec, label = d.head_rev .. ":" .. t.file, d.head_rev end
    local out = preview.git(d.root, { "show", spec })
    if not out then
      vim.notify("gitcppdiff: cannot read " .. spec, vim.log.levels.ERROR)
      return
    end
    local name = "gitcppdiff://" .. label .. "/" .. t.file
    local old = vim.fn.bufnr(name)
    if old ~= -1 then api.nvim_buf_delete(old, { force = true }) end
    local buf = api.nvim_create_buf(false, true)
    api.nvim_buf_set_name(buf, name)
    local lines = vim.split(out, "\n", { plain = true })
    if lines[#lines] == "" then table.remove(lines) end
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = "cpp"
    api.nvim_set_current_buf(buf)
  end
  pcall(api.nvim_win_set_cursor, 0, { t.line, 0 })
  vim.cmd("normal! zz")
end

return M
