local M = {}

---@param opts? table  see lua/gitcppdiff/config.lua for all options
function M.setup(opts)
  require("gitcppdiff.config").setup(opts)
end

--- Open the overview. `args` are passed to the executable, e.g. { "main...HEAD" } or { "--staged" }.
---@param args? string[]
function M.open(args)
  require("gitcppdiff.ui").open(args)
end

--- Jump to the next / previous change of the last run (or move in the open window).
function M.next(count) require("gitcppdiff.nav").step(1, count) end
function M.prev(count) require("gitcppdiff.nav").step(-1, count) end

function M.close() require("gitcppdiff.ui").close() end
function M.refresh() require("gitcppdiff.ui").refresh() end
function M.build(cb) require("gitcppdiff.bin").build(cb) end
function M.clear_marks() require("gitcppdiff.ui").clear_marks() end

local FLAGS = { "--staged", "--api-only", "--all-api", "--expand", "--only=", "--macro", "--" }

--- :CppDiff command-line completion: flags and git refs.
function M.complete(arglead)
  local items = {}
  if arglead:sub(1, 1) == "-" then
    items = vim.deepcopy(FLAGS)
  else
    local out = vim.fn.systemlist({ "git", "for-each-ref", "--format=%(refname:short)",
      "refs/heads", "refs/tags", "refs/remotes" })
    if vim.v.shell_error == 0 then items = out end
    items[#items + 1] = "HEAD"
  end
  return vim.tbl_filter(function(s) return vim.startswith(s, arglead) end, items)
end

return M
