local M = {}

--- Root directory of this plugin (the repo checkout).
function M.plugin_root()
  if M.root_override then return M.root_override end -- tests
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

-- ───────────────────────────── building ─────────────────────────────

M.log = {}          -- every output line of the last build
M.building = false
local logbuf, pid, waiting = nil, nil, {}

local function strip(line)
  return (vim.trim((line:gsub("\27%[[%d;]*[A-Za-z]", ""))))
end

--- Turn one line of `make` / cmake / ninja output into progress: percent, message.
--- Phases are announced by the Makefile (`==> [1/3] configuring`, `[2/3] compiling`, `[3/3] installing`);
--- `[n/m]` is only compile progress in phase 2 (CMake's download sub-builds print the same pattern).
---@param st table  parser state, start with { phase = 1, pct = 0, msg = "" }
---@return boolean changed
function M._parse_line(st, line)
  line = strip(line)
  if line == "" then return false end
  local pct, msg = st.pct, st.msg
  if line:find("==> [2/3]", 1, true) then
    st.phase, pct, msg = 2, math.max(pct, 30), "compiling"
  elseif line:find("==> [3/3]", 1, true) then
    st.phase, pct, msg = 3, 97, "installing"
  elseif line:sub(1, 3) == "==>" then
    return false -- other Makefile banner text (it mentions the same keywords as the real output)
  elseif st.phase == 1 then
    local ident = line:match("The CXX compiler identification is (.+)$")
    if line:find("detecting the C and C++ compiler", 1, true) then pct, msg = 3, "detecting the C++ compiler …"
    elseif ident then pct, msg = 6, "C++ compiler: " .. ident
    elseif line:find("Detecting CXX compiler ABI", 1, true) then pct, msg = 8, "checking the C++ compiler …"
    elseif line:find("using C++ compiler", 1, true) then pct, msg = 10, line:match("gitcppdiff: (.+)$") or msg
    elseif line:find("downloading tree-sitter-cpp", 1, true) then pct, msg = 20, "downloading tree-sitter-cpp from GitHub …"
    elseif line:find("downloading tree-sitter ", 1, true) then pct, msg = 12, "downloading tree-sitter from GitHub …"
    elseif line:find("Cloning into", 1, true) then msg = "cloning " .. (line:match("'(.-)'") or "…")
    elseif line:find("dependencies ready", 1, true) then pct, msg = 28, "dependencies ready"
    end
  elseif st.phase == 2 then
    local n, m = line:match("^%[(%d+)/(%d+)%]")
    if n then
      pct, msg = 30 + math.floor(65 * tonumber(n) / tonumber(m)), ("compiling %d/%d"):format(n, m)
    else
      local p = line:match("^%[%s*(%d+)%%%]")
      if p then pct, msg = 30 + math.floor(0.65 * tonumber(p)), ("compiling %s%%"):format(p) end
    end
  end
  local changed = pct ~= st.pct or msg ~= st.msg
  st.pct, st.msg = pct, msg
  return changed
end

local function echo(msg, status, percent, history)
  local ok, id = pcall(vim.api.nvim_echo, { { msg } }, history or false, {
    kind = "progress", source = "gitcppdiff", title = "gitcppdiff build",
    status = status, percent = percent, id = pid,
  })
  if ok then pid = id end
  return ok
end

--- Open the output of the last build in a split.
function M.show_log()
  if #M.log == 0 then
    vim.notify("gitcppdiff: no build output yet (run :CppDiffBuild)", vim.log.levels.INFO)
    return
  end
  if logbuf and vim.api.nvim_buf_is_valid(logbuf) and #vim.fn.win_findbuf(logbuf) > 0 then
    vim.api.nvim_set_current_win(vim.fn.win_findbuf(logbuf)[1])
    return
  end
  vim.cmd("botright 16new")
  logbuf = vim.api.nvim_get_current_buf()
  vim.bo[logbuf].buftype, vim.bo[logbuf].bufhidden, vim.bo[logbuf].swapfile = "nofile", "wipe", false
  vim.api.nvim_buf_set_name(logbuf, "gitcppdiff://build-log")
  vim.api.nvim_buf_set_lines(logbuf, 0, -1, false, M.log)
  vim.bo[logbuf].modifiable = false
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = logbuf, silent = true, desc = "close build log" })
  vim.cmd("normal! G")
end

local function log_line(line)
  M.log[#M.log + 1] = line
  if logbuf and vim.api.nvim_buf_is_valid(logbuf) then
    vim.bo[logbuf].modifiable = true
    vim.api.nvim_buf_set_lines(logbuf, -1, -1, false, { line })
    vim.bo[logbuf].modifiable = false
    for _, w in ipairs(vim.fn.win_findbuf(logbuf)) do
      pcall(vim.api.nvim_win_set_cursor, w, { vim.api.nvim_buf_line_count(logbuf), 0 })
    end
  end
end

local function cxx_compiler()
  for _, c in ipairs({ vim.env.CXX or "", "c++", "g++", "clang++" }) do
    if c ~= "" and vim.fn.executable(c) == 1 then return c end
  end
end

--- Build the executable with `make` (needs cmake, a C++20 compiler, git, network on first run).
--- Output streams into a progress message; the full log is available with :CppDiffBuildLog.
---@param cb? fun(ok: boolean)
function M.build(cb)
  local root = M.plugin_root()
  if cb then waiting[#waiting + 1] = cb end
  if M.building then
    vim.notify("gitcppdiff: a build is already running (:CppDiffBuildLog shows its output)", vim.log.levels.INFO)
    return
  end
  local function finish(ok)
    M.building = false
    local list = waiting
    waiting = {}
    for _, f in ipairs(list) do f(ok) end
  end

  -- 1. what is missing?
  local missing = {}
  for _, tool in ipairs({ "make", "cmake", "git" }) do
    if vim.fn.executable(tool) == 0 then missing[#missing + 1] = tool end
  end
  local cxx = cxx_compiler()
  if not cxx then missing[#missing + 1] = "a C++ compiler (g++ / clang++)" end
  if #missing > 0 then
    vim.notify("gitcppdiff: cannot build, missing: " .. table.concat(missing, ", "), vim.log.levels.ERROR)
    return finish(false)
  end

  M.building = true
  M.log = {}
  pid = nil
  local st = { phase = 1, pct = 0, msg = "detecting the C++ compiler …" }
  echo(st.msg, "running", 1)
  local v = vim.system({ cxx, "--version" }, { text = true }):wait()
  log_line("compiler: " .. cxx .. (v.code == 0 and ("  (" .. (vim.split(v.stdout, "\n")[1] or "") .. ")") or ""))

  -- 2. run make, streaming its output
  local bufs, last, dirty, flush_scheduled = { out = "", err = "" }, 0, false, false
  local started = vim.uv.hrtime()
  local function show()
    last = vim.uv.hrtime()
    echo(("%s  [%ds]"):format(st.msg, math.floor((last - started) / 1e9)), "running", st.pct)
  end
  local function flush()
    flush_scheduled = false
    if dirty and M.building then
      dirty = false
      show()
    end
  end
  -- heartbeat: a long silent step (a slow git clone) must not look frozen
  local ticker = vim.uv.new_timer()
  ticker:start(1000, 1000, vim.schedule_wrap(function()
    if M.building then show() end
  end))
  local function feed(key, data)
    bufs[key] = bufs[key] .. data
    while true do
      local i = bufs[key]:find("[\r\n]")
      if not i then break end
      local line = strip(bufs[key]:sub(1, i - 1))
      bufs[key] = bufs[key]:sub(i + 1)
      if line ~= "" then
        log_line(line)
        if M._parse_line(st, line) then
          dirty = true
          if vim.uv.hrtime() - last > 80e6 then -- at most ~12 updates per second ...
            flush()
          elseif not flush_scheduled then       -- ... but the latest state is always shown eventually
            flush_scheduled = true
            vim.defer_fn(flush, 90)
          end
        end
      end
    end
  end
  local function handler(key)
    return function(_, data)
      if data then vim.schedule(function() feed(key, data) end) end
    end
  end

  vim.system({ "make", "-C", root }, { text = true, stdout = handler("out"), stderr = handler("err") },
    vim.schedule_wrap(function(res)
      ticker:stop()
      ticker:close()
      feed("out", "\n")
      feed("err", "\n")
      dirty = false
      if res.code == 0 then
        echo("build finished", "success", 100, true)
        finish(true)
      else
        echo("build failed (exit code " .. res.code .. ")", "failed", st.pct, true)
        local tail = vim.list_slice(M.log, math.max(1, #M.log - 12))
        vim.notify("gitcppdiff: build failed\n" .. table.concat(tail, "\n"), vim.log.levels.ERROR)
        M.show_log()
        finish(false)
      end
    end))
end

return M
