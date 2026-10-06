local M = {}

function M.check()
  local h = vim.health
  h.start("gitcppdiff")

  if vim.fn.has("nvim-0.12") == 1 then
    h.ok("Neovim >= 0.12")
  else
    h.error("Neovim >= 0.12 is required")
  end

  local bin = require("gitcppdiff.bin")
  local exe = bin.find()
  if exe then
    local r = vim.system({ exe, "--help" }, { text = true }):wait()
    if r.code == 0 then h.ok("executable: " .. exe) else h.error("executable does not run: " .. exe) end
  else
    h.error("gitcppdiff executable not found", { "Run :CppDiffBuild (needs make, cmake, a C++20 compiler, git, network)",
      "or set `bin = '/path/to/gitcppdiff'` in require('gitcppdiff').setup()" })
  end

  if vim.fn.executable("git") == 1 then h.ok("git found") else h.error("git not found") end
  if vim.fn.executable("make") == 1 and vim.fn.executable("cmake") == 1 then
    h.ok("make + cmake found (for :CppDiffBuild)")
  else
    h.info("make / cmake not found (only needed to build the executable)")
  end

  local ok = pcall(vim.treesitter.language.add, "cpp")
  if ok then
    h.ok("treesitter `cpp` parser found (preview highlighting)")
  else
    h.warn("treesitter `cpp` parser not found; the preview falls back to regex syntax highlighting")
  end
  local cl = require("gitcppdiff.config").options.callers
  if cl.enabled then
    if vim.fn.executable("clangd") == 1 then
      local n = #vim.lsp.get_clients({ name = cl.client })
      h.ok("clangd found" .. (n > 0 and (" (" .. n .. " client running)") or " (starts on demand if LSP is enabled for C++)"))
    else
      h.warn("clangd not found: caller counts for API changes are disabled (removed symbols still use git grep)")
    end
  end
  if require("gitcppdiff.config").options.icons then
    h.info("icons = true needs a Nerd Font; set icons = false for ASCII")
  end
end

return M
