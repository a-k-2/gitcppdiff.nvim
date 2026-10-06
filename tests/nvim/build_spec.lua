-- Build output: progress parsing (against real captured make output) and the streaming build.
vim.opt.rtp:prepend(assert(vim.env.GITCPPDIFF_PLUGIN))
vim.cmd("runtime plugin/gitcppdiff.lua")
local bin = require("gitcppdiff.bin")
local api = vim.api

local failures = 0
local function check(name, cond, extra)
  if cond then io.stdout:write("ok   " .. name .. "\n")
  else failures = failures + 1; io.stdout:write("FAIL " .. name .. (extra and ("  -> " .. tostring(extra)) or "") .. "\n") end
end

-- ── 1. parser against the real output of `make` on a clean checkout ──
local st = { phase = 1, pct = 0, msg = "" }
local seen, last_pct, monotonic, max_pct_phase1 = {}, 0, true, 0
for line in io.lines(vim.env.GITCPPDIFF_PLUGIN .. "/tests/nvim/fixtures/make_output.txt") do
  if bin._parse_line(st, line) then
    seen[#seen + 1] = st.msg
    if st.pct < last_pct then monotonic = false end
    last_pct = st.pct
  end
  if st.phase == 1 then max_pct_phase1 = math.max(max_pct_phase1, st.pct) end
end
local joined = table.concat(seen, "\n")
check("parser: announces compiler detection", joined:find("detecting the C++ compiler", 1, true) ~= nil, joined)
check("parser: reports the compiler found", joined:find("C++ compiler: GNU", 1, true) ~= nil)
check("parser: reports both dependency downloads", joined:find("downloading tree-sitter from GitHub", 1, true) and joined:find("downloading tree-sitter-cpp from GitHub", 1, true))
check("parser: shows what is being cloned", joined:find("cloning tree_sitter-src", 1, true) and joined:find("cloning tree_sitter_cpp-src", 1, true))
check("parser: percent never goes backwards", monotonic)
check("parser: CMake's [n/9] download sub-builds are not compile progress", max_pct_phase1 < 30, max_pct_phase1)
check("parser: compile progress parsed", joined:find("compiling 14/25", 1, true) ~= nil and joined:find("compiling 25/25", 1, true) ~= nil)
check("parser: ends in install phase", st.phase == 3 and st.pct >= 97, vim.inspect(st))
local st2 = { phase = 2, pct = 30, msg = "" }
bin._parse_line(st2, "[ 50%] Building CXX object x.o")
check("parser: Makefile-generator percent format", st2.pct == 30 + math.floor(0.65 * 50), st2.pct)
local st3 = { phase = 1, pct = 0, msg = "" }
bin._parse_line(st3, "\27[32m-- The CXX compiler identification is Clang 18.1.3\27[0m")
check("parser: strips ANSI colour codes", st3.msg == "C++ compiler: Clang 18.1.3", st3.msg)

-- ── 2. streaming build with a fake `make` ──
local function fake_root(makefile_body)
  local d = vim.fn.tempname()
  vim.fn.mkdir(d, "p")
  local f = io.open(d .. "/Makefile", "w")
  f:write("all:\n" .. makefile_body)
  f:close()
  return d
end
local echoes, notes = {}, {}
local orig_echo, orig_notify = api.nvim_echo, vim.notify
api.nvim_echo = function(chunks, hist, opts)
  if opts and opts.kind == "progress" then
    echoes[#echoes + 1] = { msg = chunks[1][1], status = opts.status, percent = opts.percent }
  end
  return orig_echo(chunks, hist, opts)
end
vim.notify = function(msg, lvl) notes[#notes + 1] = { msg = msg, lvl = lvl } end
local function reset() echoes, notes = {}, {} end
local function wait_build(root, expect_cb_calls)
  local results = {}
  bin.root_override = root
  bin.build(function(ok) results[#results + 1] = ok end)
  return results
end

local ok_root = fake_root([[
	@echo "==> [1/3] configuring: detecting the C/C++ compiler, downloading tree-sitter + tree-sitter-cpp"
	@echo "-- gitcppdiff: detecting the C and C++ compiler ..."
	@sleep 0.15
	@echo "-- The CXX compiler identification is GNU 13.3.0"
	@sleep 0.15
	@echo "-- gitcppdiff: downloading tree-sitter (github.com/x) ..."
	@sleep 0.15
	@echo "Cloning into 'tree_sitter-src'..."
	@sleep 0.15
	@echo "==> [2/3] compiling"
	@echo "[1/4] Building C object a.o"
	@sleep 0.15
	@echo "[2/4] Building C object b.o"
	@sleep 0.15
	@echo "[3/4] Building C object c.o"
	@sleep 0.15
	@echo "[4/4] Linking CXX executable gitcppdiff"
	@echo "==> [3/3] installing"
	@echo "==> done"
]])
reset()
local res = wait_build(ok_root)
check("build: reports itself as running", bin.building == true)
-- a second call while running is queued, not started twice
local res2 = {}
bin.build(function(ok) res2[#res2 + 1] = ok end)
vim.wait(15000, function() return #res > 0 end, 25)
check("build: finishes successfully", res[1] == true and bin.building == false, vim.inspect(res))
check("build: overlapping call is coalesced and gets the result", res2[1] == true and #res == 1 and #res2 == 1)
check("build: notified about the overlapping call", (function() for _, n in ipairs(notes) do if n.msg:find("already running", 1, true) then return true end end end)())
local msgs = {}
for _, e in ipairs(echoes) do msgs[#msgs + 1] = e.msg end
local all = table.concat(msgs, "\n")
check("build: first message says it is detecting the compiler", echoes[1] and echoes[1].msg:find("detecting the C++ compiler", 1, true) and echoes[1].status == "running", vim.inspect(echoes[1]))
check("build: shows the compiler found", all:find("C++ compiler: GNU 13.3.0", 1, true) ~= nil, all)
check("build: shows the download step", all:find("downloading tree-sitter from GitHub", 1, true) ~= nil and all:find("cloning tree_sitter-src", 1, true) ~= nil)
check("build: shows compile progress", all:find("compiling 2/4", 1, true) ~= nil and all:find("compiling 3/4", 1, true) ~= nil, all)
local mono, lp = true, 0
for _, e in ipairs(echoes) do if e.percent then if e.percent < lp then mono = false end lp = e.percent end end
check("build: progress percentages are monotonic", mono)
local fin = echoes[#echoes]
check("build: ends with a success message at 100%", fin and fin.status == "success" and fin.percent == 100 and fin.msg == "build finished", vim.inspect(fin))
check("build: full output kept in the log", #bin.log > 10 and table.concat(bin.log, "\n"):find("Cloning into", 1, true) ~= nil and bin.log[1]:find("compiler:", 1, true) ~= nil)

bin.show_log()
local logwin = api.nvim_get_current_win()
local lb = api.nvim_win_get_buf(logwin)
check(":CppDiffBuildLog shows the output", api.nvim_buf_get_name(lb):find("build-log", 1, true) ~= nil and #api.nvim_buf_get_lines(lb, 0, -1, false) == #bin.log)
vim.cmd("close")

-- ── 2b. a burst of lines followed by silence still ends up showing the last state ──
local burst_root = fake_root([[
	@echo "-- gitcppdiff: downloading tree-sitter (github.com/x) ..."
	@echo "Cloning into 'tree_sitter-src'..."
	@echo "-- gitcppdiff: downloading tree-sitter-cpp (github.com/y) ..."
	@sleep 2.6
]])
reset()
local bres = wait_build(burst_root)
vim.wait(2300, function() return false end)  -- still silent / running here
local shown_during_silence = {}
for _, e in ipairs(echoes) do if e.status == "running" then shown_during_silence[#shown_during_silence + 1] = e.msg end end
check("burst then silence: latest state is flushed while still running", shown_during_silence[#shown_during_silence]:find("downloading tree-sitter-cpp", 1, true) ~= nil and bin.building,
  vim.inspect(shown_during_silence))
check("silent step: heartbeat shows elapsed seconds so it does not look frozen",
  (function() for _, m in ipairs(shown_during_silence) do if m:find("downloading tree-sitter-cpp", 1, true) and m:find("%[%d+s%]") then return true end end end)(),
  vim.inspect(shown_during_silence))
vim.wait(5000, function() return #bres > 0 end, 25)

-- ── 3. failure: error with the tail of the output, log opens by itself ──
local bad_root = fake_root([[
	@echo "==> [1/3] configuring"
	@echo "-- The CXX compiler identification is GNU 13.3.0"
	@echo "CMake Error: could not clone tree-sitter (no network?)"
	@exit 2
]])
reset()
local fres = wait_build(bad_root)
vim.wait(15000, function() return #fres > 0 end, 25)
check("failure: callback gets false", fres[1] == false and bin.building == false)
local err = (function() for _, n in ipairs(notes) do if n.lvl == vim.log.levels.ERROR then return n.msg end end end)()
check("failure: error notification contains the tool's last lines", err and err:find("build failed", 1, true) and err:find("could not clone tree-sitter", 1, true), err)
check("failure: progress message marked failed", echoes[#echoes].status == "failed" and echoes[#echoes].msg:find("exit code 2", 1, true), vim.inspect(echoes[#echoes]))
local log_open = false
for _, w in ipairs(api.nvim_list_wins()) do
  if api.nvim_buf_get_name(api.nvim_win_get_buf(w)):find("build-log", 1, true) then log_open = true end
end
check("failure: log window opened automatically", log_open)
vim.cmd("silent! only")

-- ── 4. missing tools are named before anything starts ──
reset()
local saved_path = vim.env.PATH
vim.env.PATH = "/nonexistent"
local mres = wait_build(ok_root)
vim.env.PATH = saved_path
check("missing tools: build refused, callback false", mres[1] == false and bin.building == false)
local merr = notes[1] and notes[1].msg or ""
check("missing tools: message names make, cmake, git and the compiler", merr:find("make", 1, true) and merr:find("cmake", 1, true) and merr:find("git", 1, true) and merr:find("C++ compiler", 1, true), merr)

bin.root_override = nil
api.nvim_echo, vim.notify = orig_echo, orig_notify
io.stdout:write(failures == 0 and "\nall good\n" or ("\n" .. failures .. " FAILURE(S)\n"))
if failures > 0 then vim.cmd("cquit 1") end
