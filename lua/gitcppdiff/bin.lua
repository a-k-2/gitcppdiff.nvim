local M = {}

--- Root directory of this plugin (the repo checkout).
function M.plugin_root()
  local src = debug.getinfo(1, "S").source:sub(2)
  return vim.fs.dirname(vim.fs.dirname(vim.fs.dirname(src)))
end

--- Locate the gitcppdiff executable. Returns path or nil.
function M.find()
  local cfg = require("gitcppdiff.config").options
  local root = M.plugin_root()
  local cands = {}
  if cfg.bin then cands[#cands + 1] = vim.fn.expand(cfg.bin) end
  cands[#cands + 1] = root .. "/bin/gitcppdiff"
  cands[#cands + 1] = root .. "/build/gitcppdiff"
  for _, c in ipairs(cands) do
    if vim.fn.executable(c) == 1 then return c end
  end
  local e = vim.fn.exepath("gitcppdiff")
  return e ~= "" and e or nil
end

--- Build the executable with `make` (needs cmake, a C++20 compiler, git, network on first run).
---@param cb? fun(ok: boolean)
function M.build(cb)
  local root = M.plugin_root()
  if vim.fn.executable("make") == 0 or vim.fn.executable("cmake") == 0 then
    vim.notify("gitcppdiff: building needs `make` and `cmake` on $PATH", vim.log.levels.ERROR)
    if cb then cb(false) end
    return
  end
  vim.notify("gitcppdiff: building executable …")
  vim.system({ "make", "-C", root }, { text = true }, vim.schedule_wrap(function(res)
    if res.code == 0 then
      vim.notify("gitcppdiff: build finished")
    else
      vim.notify("gitcppdiff: build failed\n" .. (res.stderr or ""):sub(-1500), vim.log.levels.ERROR)
    end
    if cb then cb(res.code == 0) end
  end))
end

return M
