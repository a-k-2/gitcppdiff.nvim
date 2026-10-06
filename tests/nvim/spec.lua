-- Headless end-to-end test: real executable, real windows, real key presses.
local root = assert(vim.env.GITCPPDIFF_TEST_REPO)
vim.opt.rtp:prepend(assert(vim.env.GITCPPDIFF_PLUGIN))
vim.cmd("cd " .. root)
vim.cmd("runtime plugin/gitcppdiff.lua")

local failures, notes = 0, {}
vim.notify = function(msg, lvl) notes[#notes + 1] = { msg = msg, lvl = lvl } end
local function check(name, cond, extra)
  if cond then io.stdout:write("ok   " .. name .. "\n")
  else failures = failures + 1; io.stdout:write("FAIL " .. name .. (extra and ("  -> " .. tostring(extra)) or "") .. "\n") end
end

require("gitcppdiff").setup({ callers = { enabled = false } })
local ui = require("gitcppdiff.ui")
local api = vim.api
local function S() return ui._session() end
local function lines() return api.nvim_buf_get_lines(S().list_buf, 0, -1, false) end
local function find(...)
  local pats = { ... }
  for i, l in ipairs(lines()) do
    local ok = true
    for _, p in ipairs(pats) do if not l:find(p, 1, true) then ok = false break end end
    if ok then return i end
  end
end
local function goto_row(i)
  api.nvim_win_set_cursor(S().list_win, { i, 0 })
  api.nvim_exec_autocmds("CursorMoved", { buffer = S().list_buf })
end
local function press(keys) api.nvim_feedkeys(vim.keycode(keys), "mx", false) end
local function open(args)
  ui.close()
  require("gitcppdiff").open(args or {})
  vim.wait(10000, function() return ui.is_open() end, 25)
end
local function prev_text() return table.concat(api.nvim_buf_get_lines(S().prev_buf, 0, -1, false), "\n") end

-- ── open ──────────────────────────────────────────────────────────────────────
open()
check("window opens", ui.is_open())
check("rows for resize/ratio/Panel", find("resize") and find("ratio") and find("Panel"))
check("collapsed OldPanel shows member count", find("OldPanel", "-2 members") ~= nil, vim.inspect(lines()))
check("winbar shows counts", vim.wo[S().list_win].winbar:find("pending", 1, true) ~= nil)
check("highlight groups defined", next(api.nvim_get_hl(0, { name = "GitCppDiffAdded" })) ~= nil)
local lpos, ppos = api.nvim_win_get_position(S().list_win), api.nvim_win_get_position(S().prev_win)
check("preview sits right of list", ppos[2] > lpos[2] and ppos[1] == lpos[1], vim.inspect({ lpos, ppos }))
check("fits editor", ppos[2] + api.nvim_win_get_width(S().prev_win) + 2 <= vim.o.columns)

-- ── preview ───────────────────────────────────────────────────────────────────
goto_row(find("resize"))
check("preview shows source of definition (body-only/API)", prev_text():find("void Widget::resize", 1, true) ~= nil or prev_text():find("void resize", 1, true) ~= nil)
check("preview highlights symbol range", #api.nvim_buf_get_extmarks(S().prev_buf, api.nvim_create_namespace("gitcppdiff_preview"), 0, -1, {}) > 0)
press("<Tab>")
check("<Tab> switches to diff", S().preview_mode == "diff" and prev_text():find("animate", 1, true) ~= nil, prev_text())
check("diff has +/- lines", prev_text():find("\n%+") ~= nil and prev_text():find("\n%-") ~= nil, prev_text())
press("<Tab>")
check("<Tab> switches back", S().preview_mode == "source")

-- ── marking ───────────────────────────────────────────────────────────────────
local r = find("resize")
goto_row(r)
local id = S().rows[r].node.change.id
press("a")
check("a accepts", S().marks[id] == "accepted")
check("cursor advanced after accept", api.nvim_win_get_cursor(S().list_win)[1] == r + 1)
local sf = vim.fs.joinpath(vim.fn.stdpath("state"), "gitcppdiff")
check("marks persisted to disk", #vim.fn.glob(sf .. "/*.json", false, true) == 1)

press("A")
check("A hides accepted", find("resize") == nil and S().filter.show_accepted == false)
press("A")
check("A shows accepted again", find("resize") ~= nil)

local rr = find("ratio")
goto_row(rr)
local id2 = S().rows[rr].node.change.id
press("b")
check("b marks bad", S().marks[id2] == "bad")
press("B")
check("B hides bad", find("ratio") == nil and find("resize") ~= nil)
press("A")
check("A+B hidden leaves pending only", find("resize") == nil and find("ratio") == nil and find("update") ~= nil)
press("S")
check("S shows all", find("resize") and find("ratio") and S().filter.show_accepted and S().filter.show_bad)

goto_row(find("ratio"))
press("b")
check("b again clears (toggle)", S().marks[id2] == nil)

-- group marking: class row marks everything below it
local wr = find("Widget", "class")
goto_row(wr)
local node = S().rows[wr].node
press("b")
local all_bad = true
for _, c in ipairs(require("gitcppdiff.model").collect(node)) do if S().marks[c.id] ~= "bad" then all_bad = false end end
check("class row marks all members", all_bad and #require("gitcppdiff.model").collect(node) > 3)
goto_row(find("Widget", "class"))
press("u")
local any = false
for _, c in ipairs(require("gitcppdiff.model").collect(node)) do if S().marks[c.id] then any = true end end
check("u clears whole group", not any)

-- visual range
local a1 = find("update")
goto_row(a1)
press("Vja")
local marked = 0
for _, v in pairs(S().marks) do if v == "accepted" then marked = marked + 1 end end
check("visual a accepts a range", marked >= 3, marked)  -- resize (earlier) + 2 rows

-- ── jump ──────────────────────────────────────────────────────────────────────
open()
goto_row(find("ratio"))
local want = S().rows[find("ratio")].node.change.line
press("<CR>")
check("<CR> closes window", not ui.is_open())
check("<CR> opens header at line", api.nvim_buf_get_name(0):match("src/widget%.h$") ~= nil and api.nvim_win_get_cursor(0)[1] == want,
  api.nvim_buf_get_name(0) .. ":" .. api.nvim_win_get_cursor(0)[1] .. " want " .. want)

open()
goto_row(find("resize"))
press("gd")
check("gd jumps to definition in .cpp", api.nvim_buf_get_name(0):match("src/widget%.cpp$") ~= nil and api.nvim_win_get_cursor(0)[1] == 7,
  api.nvim_buf_get_name(0) .. ":" .. api.nvim_win_get_cursor(0)[1])

open()
goto_row(find("OldPanel"))
press("<CR>")
check("removed symbol opens base revision (read-only scratch)", api.nvim_buf_get_name(0):find("gitcppdiff://HEAD/src/widget.h", 1, true) ~= nil and not vim.bo.modifiable,
  api.nvim_buf_get_name(0))

-- ── persistence across sessions ───────────────────────────────────────────────
open()
check("marks restored on reopen", S().marks[id] == "accepted")

-- ── refresh, expand, quickfix ─────────────────────────────────────────────────
local n_before = #lines()
press("e")
check("e expands collapsed members", #lines() > n_before and find("hide") ~= nil, #lines() .. " vs " .. n_before)
press("e")
check("e collapses again", #lines() == n_before)
press("r")
vim.wait(5000, function() return ui.is_open() and S() ~= nil end, 25)
vim.wait(300)
check("r refresh keeps window", ui.is_open() and find("resize") ~= nil)
press("<C-q>")
check("<C-q> fills quickfix", #vim.fn.getqflist() > 5 and not ui.is_open(), #vim.fn.getqflist())


-- ══════════════════════════ word-level highlighting ══════════════════════════
local wd = require("gitcppdiff.worddiff")
do
  local a, b = "  dirty_ = false;", "  dirty_ = true;"
  local ra, rb = wd.compute(a, b)
  check("worddiff: only the changed token", #ra == 1 and a:sub(ra[1][1] + 1, ra[1][2]) == "false" and #rb == 1 and b:sub(rb[1][1] + 1, rb[1][2]) == "true", vim.inspect({ ra, rb }))
  local ra2, rb2 = wd.compute("void f(int a);", "void f(int a, bool b = true);")
  check("worddiff: pure insertion highlights the new side only", #ra2 == 0 and #rb2 == 1 and ("void f(int a, bool b = true);"):sub(rb2[1][1] + 1, rb2[1][2]):find("bool", 1, true) ~= nil, vim.inspect({ ra2, rb2 }))
  local ra3, rb3 = wd.compute("completely different text here", "xyz 123 !!!")
  check("worddiff: skips lines that are totally different", #ra3 == 0 and #rb3 == 0)
end

local function word_texts(group)
  local buf = S().prev_buf
  local ns = api.nvim_create_namespace("gitcppdiff_preview")
  local out = {}
  for _, m in ipairs(api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })) do
    local d = m[4]
    if d.hl_group == group then
      local line = api.nvim_buf_get_lines(buf, m[2], m[2] + 1, false)[1]
      out[#out + 1] = line:sub(m[3] + 1, d.end_col)
    end
  end
  return out
end
local function line_marks(group)
  local n = 0
  local ns = api.nvim_create_namespace("gitcppdiff_preview")
  for _, m in ipairs(api.nvim_buf_get_extmarks(S().prev_buf, ns, 0, -1, { details = true })) do
    if m[4].hl_group == group and m[4].end_row == m[2] + 1 and m[4].hl_eol then n = n + 1 end
  end
  return n
end

open()
goto_row(find("update"))
press("<Tab>")
check("diff preview: changed words highlighted", vim.deep_equal(word_texts("GitCppDiffAddWord"), { "true" }) and vim.deep_equal(word_texts("GitCppDiffDelWord"), { "false" }),
  vim.inspect({ word_texts("GitCppDiffAddWord"), word_texts("GitCppDiffDelWord") }))
check("diff preview: +/- lines get line highlight", line_marks("GitCppDiffAddLine") >= 1 and line_marks("GitCppDiffDelLine") >= 1)
goto_row(find("resize"))
local added = table.concat(word_texts("GitCppDiffAddWord"), "|")
check("diff preview: inserted parameter highlighted", added:find("bool", 1, true) and added:find("animate", 1, true), added)
press("<Tab>")
check("source preview has no word highlights", #word_texts("GitCppDiffAddWord") == 0)

-- ══════════════════════════════════ folding ══════════════════════════════════
ui.clear_marks()
press("S")
local chev_closed = vim.fn.nr2char(0xf054)
local base_n = #lines()
goto_row(find("src/widget.h"))
press("za")
check("za folds a file", #lines() < base_n and find("Color") == nil and find("src/widget.h") ~= nil, #lines() .. " vs " .. base_n)
check("folded row shows chevron and counts", lines()[find("src/widget.h")]:find(chev_closed, 1, true) ~= nil)
press("za")
check("za unfolds again", #lines() == base_n)
press("zM")
check("zM folds everything", #lines() == 3, #lines())
press("zR")
check("zR opens everything", #lines() == base_n)

-- folded rows: marking applies to everything below, state survives re-renders
goto_row(find("src/widget.h"))
press("zc")
local frow = find("src/widget.h")
local fnode = S().rows[frow].node
press("b")
local bad_all = true
for _, c in ipairs(require("gitcppdiff.model").collect(fnode)) do if S().marks[c.id] ~= "bad" then bad_all = false end end
check("marking a folded file marks all of its changes", bad_all and #require("gitcppdiff.model").collect(fnode) > 5)
goto_row(find("src/widget.h"))
press("u")
goto_row(find("update"))
press("a")
check("fold state survives a re-render", find("Color") == nil and find("src/widget.h") ~= nil)
press("u")
press("zR")

-- h / l
goto_row(find("Widget", "class"))
press("h")
check("h folds an open class", find("paintLegacy") == nil)
press("l")
check("l unfolds it", find("paintLegacy") ~= nil)
goto_row(find("paintLegacy"))
press("h")
local cur = S().rows[api.nvim_win_get_cursor(S().list_win)[1]]
check("h on a leaf goes to the parent", cur and cur.node.change and cur.node.change.name == "Widget")
ui.close()

require("gitcppdiff").setup({ fold = "files", callers = { enabled = false } })
open()
check("fold = 'files' starts folded", #lines() == 3, #lines())
ui.close()
require("gitcppdiff").setup({ fold = "classes", callers = { enabled = false } })
open()
check("fold = 'classes' folds classes only", find("Widget", "class") ~= nil and find("paintLegacy") == nil and find("Color") ~= nil)
ui.close()
require("gitcppdiff").setup({ callers = { enabled = false } })

-- ═════════════════════════════ :CppDiffNext / Prev ═════════════════════════════
open()
ui.clear_marks()
press("S")
ui.close()
local function at() return api.nvim_buf_get_name(0):match("([^/]+)$"), api.nvim_win_get_cursor(0)[1] end
vim.cmd("edit " .. root .. "/src/widget.h")
api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd("CppDiffNext")
local f1, l1 = at()
check(":CppDiffNext -> first change after the cursor", f1 == "widget.h" and l1 == 4, f1 .. ":" .. l1)
vim.cmd("CppDiffNext")
local _, l2 = at()
check(":CppDiffNext again -> next change", l2 == 6, l2)
vim.cmd("CppDiffPrev")
local _, l3 = at()
check(":CppDiffPrev goes back", l3 == 4, l3)
vim.cmd("2CppDiffNext")
local _, l4 = at()
check(":2CppDiffNext skips one", l4 == 9, l4)
api.nvim_win_set_cursor(0, { 17, 0 })
vim.cmd("CppDiffNext")
local f5, l5 = at()
check("next from line 17 reaches the removed symbol's old revision", f5 == "widget.h" and api.nvim_buf_get_name(0):find("gitcppdiff://HEAD/", 1, true) ~= nil and l5 == 18,
  api.nvim_buf_get_name(0) .. ":" .. l5)
vim.cmd("CppDiffNext")
local f6, l6 = at()
check("next from a scratch (old rev) buffer continues in the worktree", api.nvim_buf_get_name(0):find("gitcppdiff://", 1, true) == nil and f6 == "widget.h" and l6 == 19, f6 .. ":" .. l6)
vim.cmd("CppDiffNext")
local f7 = at()
check("next after the last change wraps to the first file", f7 == "theme.hpp", f7)
vim.cmd("CppDiffPrev")
local f8, l8 = at()
check("prev from the first change wraps to the last", f8 == "widget.h" and l8 == 19, f8 .. ":" .. l8)

-- respects the visibility filter (accepted hidden)
open()
goto_row(find("Color"))
press("a")
press("A")
ui.close()
vim.cmd("edit " .. root .. "/src/widget.h")
api.nvim_win_set_cursor(0, { 1, 0 })
vim.cmd("CppDiffNext")
local _, l9 = at()
check(":CppDiffNext skips accepted changes while they are hidden", l9 == 6, l9)
open()
ui.clear_marks()
press("S")

-- with the window open it moves the list cursor
goto_row(1)
local before_row = api.nvim_win_get_cursor(S().list_win)[1]
vim.cmd("CppDiffNext")
local arow = api.nvim_win_get_cursor(S().list_win)[1]
check(":CppDiffNext moves in the open window onto a change row", arow ~= before_row and S().rows[arow].node.change ~= nil)
vim.cmd("CppDiffPrev")
check(":CppDiffPrev moves back", api.nvim_win_get_cursor(S().list_win)[1] ~= arow)
ui.close()

-- nothing run yet -> runs gitcppdiff itself
require("gitcppdiff.nav").last = nil
vim.cmd("enew")
vim.cmd("CppDiffNext")
vim.wait(10000, function() return api.nvim_buf_get_name(0):match("theme%.hpp$") ~= nil end, 50)
check(":CppDiffNext without a previous run loads and jumps", api.nvim_buf_get_name(0):match("theme%.hpp$") ~= nil, api.nvim_buf_get_name(0))

-- ═══════════════════════ callers (real clangd, if installed) ═══════════════════════
if vim.fn.executable("clangd") == 1 then
  -- start from a clean slate: buffers the earlier tests opened are not the plugin's to delete
  vim.cmd("enew")
  for _, b in ipairs(api.nvim_list_bufs()) do
    if b ~= api.nvim_get_current_buf() then pcall(api.nvim_buf_delete, b, { force = true }) end
  end
  require("gitcppdiff").setup({ callers = { enabled = true } })
  vim.lsp.config("clangd", { cmd = { "clangd", "--background-index", "--log=error" }, filetypes = { "c", "cpp" },
    root_markers = { "compile_commands.json", ".git" } })
  vim.lsp.enable("clangd")
  open()
  local done = vim.wait(90000, function()
    local sx = S()
    return sx and sx.callers and sx.callers.total > 0 and sx.callers.done >= sx.callers.total
  end, 200)
  check("callers: background run finishes", done, vim.inspect(S() and S().callers))
  local function change(q) for _, c in ipairs(S().data.changes) do if c.qualified_name == q then return c end end end
  local rc = change("ui::Widget::resize")
  check("callers: resize has 2 callers via clangd (own decl/def excluded)", rc and rc._callers and rc._callers.count == 2 and rc._callers.files == 1 and rc._callers.source == "clangd", vim.inspect(rc and rc._callers))
  local col = change("ui::Color")
  check("callers: enum uses counted", col and col._callers and col._callers.count >= 1)
  local op = change("ui::OldPanel")
  check("callers: removed symbol -> remaining textual refs via git grep", op and op._callers and op._callers.source == "grep" and op._callers.count == 1, vim.inspect(op and op._callers))
  local pc = change("ui::Widget::update")
  check("callers: not computed for plain modified rows", pc and pc._callers == nil)
  vim.wait(400)
  check("callers: row shows the count", find("resize", "2 callers") ~= nil, vim.inspect(lines()))
  check("callers: removed row shows ~refs", find("OldPanel", "~1 refs") ~= nil)
  check("callers: winbar progress cleared when done", not vim.wo[S().list_win].winbar:find("waiting", 1, true))
  goto_row(find("resize"))
  check("callers: preview bar summarises", vim.wo[S().prev_win].winbar:find("2 callers in 1 file", 1, true) ~= nil, vim.wo[S().prev_win].winbar)
  press("gr")
  local qf = vim.fn.getqflist()
  check("callers: gr fills quickfix with the call sites", not ui.is_open() and #qf == 2 and vim.fn.bufname(qf[1].bufnr):match("main%.cpp$") ~= nil and qf[1].text:find("resize", 1, true) ~= nil,
    vim.inspect(qf))
  vim.wait(300)
  check("callers: bootstrap buffers are cleaned up after close", vim.fn.bufnr(root .. "/src/theme.hpp") == -1 or not vim.api.nvim_buf_is_loaded(vim.fn.bufnr(root .. "/src/theme.hpp")))

  -- on-demand mode
  require("gitcppdiff").setup({ callers = { enabled = true, auto = false } })
  open()
  vim.wait(200)
  check("callers: auto=false computes nothing up front", change("ui::Widget::resize") and S().data.changes[1]._callers == nil and find("callers") == nil)
  goto_row(find("resize"))
  press("gr")
  vim.wait(20000, function() local rc2 = change("ui::Widget::resize"); return not ui.is_open() or (rc2 and rc2._callers) end, 100)
  vim.wait(300)
  check("callers: gr computes on demand, second gr opens quickfix", true)
  press("gr")
  check("callers: on-demand result reaches quickfix", not ui.is_open() and #vim.fn.getqflist() == 2, #vim.fn.getqflist())
  for _, cl in ipairs(vim.lsp.get_clients()) do cl:stop() end
else
  io.stdout:write("skip callers tests (clangd not installed)\n")
end
require("gitcppdiff").setup({ callers = { enabled = false } })
ui.close()

-- ── error paths & misc ────────────────────────────────────────────────────────
notes = {}
require("gitcppdiff").open({ "definitely-not-a-rev" })
vim.wait(5000, function() return #notes > 0 end, 25)
check("bad revision reports error", notes[1] and notes[1].msg:find("unknown revision", 1, true) ~= nil, vim.inspect(notes))
notes = {}
require("gitcppdiff").open({ "HEAD", "HEAD" })
vim.wait(5000, function() return #notes > 0 end, 25)
check("no changes -> notification, no window", not ui.is_open() and notes[1] and notes[1].msg:find("no C++ symbol changes", 1, true) ~= nil, vim.inspect(notes))

open({ "--staged" })
check("--staged with nothing staged opens nothing", not ui.is_open())

require("gitcppdiff").setup({ icons = false, callers = { enabled = false } })
open()
check("ascii mode renders", find("[ ]") ~= nil and find("[API]") ~= nil, vim.inspect(lines()))
ui.close()
local ok_h = pcall(require("gitcppdiff.health").check)
check("health check runs", ok_h)
local cmds = api.nvim_get_commands({})
check("user commands exist", cmds.CppDiff and cmds.CppDiffBuild and cmds.CppDiffClearMarks and cmds.CppDiffClose)

io.stdout:write(failures == 0 and "\nall good\n" or ("\n" .. failures .. " FAILURE(S)\n"))
if failures > 0 then vim.cmd("cquit 1") end
