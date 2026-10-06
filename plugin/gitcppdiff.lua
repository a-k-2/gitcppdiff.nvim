if vim.g.loaded_gitcppdiff then return end
vim.g.loaded_gitcppdiff = 1

if vim.fn.has("nvim-0.12") == 0 then
  vim.notify("gitcppdiff requires Neovim >= 0.12", vim.log.levels.ERROR)
  return
end

local cmd = vim.api.nvim_create_user_command

cmd("CppDiff", function(o) require("gitcppdiff").open(o.fargs) end, {
  nargs = "*",
  complete = function(lead) return require("gitcppdiff").complete(lead) end,
  desc = "Semantic C++ diff overview: [<rev> | <rev>..<rev> | <rev>...<rev> | --staged] [-- <path>...]",
})
cmd("CppDiffBuild", function() require("gitcppdiff").build() end, { desc = "Build the gitcppdiff executable" })
cmd("CppDiffClose", function() require("gitcppdiff").close() end, { desc = "Close the gitcppdiff window" })
cmd("CppDiffClearMarks", function() require("gitcppdiff").clear_marks() end,
  { desc = "Forget accepted / bad marks of this repository" })
cmd("CppDiffNext", function(o) require("gitcppdiff").next(o.count) end,
  { count = 1, desc = "Jump to the next change of the last :CppDiff run" })
cmd("CppDiffPrev", function(o) require("gitcppdiff").prev(o.count) end,
  { count = 1, desc = "Jump to the previous change of the last :CppDiff run" })
