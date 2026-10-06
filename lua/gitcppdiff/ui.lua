-- Floating overview: list (left) + live source/diff preview (right).
local api = vim.api
local cfgm = require("gitcppdiff.config")
local model_m = require("gitcppdiff.model")
local marks_m = require("gitcppdiff.marks")
local preview = require("gitcppdiff.preview")
local bin = require("gitcppdiff.bin")
local jumpm = require("gitcppdiff.jump")
local callers = require("gitcppdiff.callers")
local nav = require("gitcppdiff.nav")

local M = {}
local NS = api.nvim_create_namespace("gitcppdiff")
local PNS = api.nvim_create_namespace("gitcppdiff_preview")
local AUG = "GitCppDiffUI"

---@type table|nil  the one open session
local S = nil
---@type table|nil  visibility filter, kept across re-opens in one Neovim session
local filter = nil

local function cfg() return cfgm.options end

-- ───────────────────────────── highlights & glyphs ─────────────────────────────

local LINKS = {
  GitCppDiffTitle = "Title", GitCppDiffAdded = "Added", GitCppDiffRemoved = "Removed",
  GitCppDiffModified = "Changed", GitCppDiffApi = "DiagnosticWarn", GitCppDiffRenamed = "DiagnosticInfo",
  GitCppDiffAccepted = "DiagnosticOk", GitCppDiffBad = "DiagnosticError", GitCppDiffDim = "Comment",
  GitCppDiffGuide = "NonText", GitCppDiffFile = "Directory", GitCppDiffScope = "Comment",
  GitCppDiffRange = "Visual", GitCppDiffKindType = "Type", GitCppDiffKindFunc = "Function",
  GitCppDiffKindField = "Identifier", GitCppDiffKindEnum = "Constant", GitCppDiffKindOp = "Operator",
}

function M.setup_highlights()
  for name, target in pairs(LINKS) do api.nvim_set_hl(0, name, { link = target, default = true }) end
  api.nvim_set_hl(0, "GitCppDiffStrike", { strikethrough = true, default = true })
  api.nvim_set_hl(0, "GitCppDiffItalic", { italic = true, default = true })
  api.nvim_set_hl(0, "GitCppDiffBold", { bold = true, default = true })

  -- diff preview: line level links to the colorscheme's Diff groups, word level is a solid block
  -- in the colour of `Added` / `Removed` (falls back to DiffText when those have no foreground).
  api.nvim_set_hl(0, "GitCppDiffAddLine", { link = "DiffAdd", default = true })
  api.nvim_set_hl(0, "GitCppDiffDelLine", { link = "DiffDelete", default = true })
  api.nvim_set_hl(0, "GitCppDiffHunk", { link = "Comment", default = true })
  local function solid(name, base, fallback)
    local fgc = api.nvim_get_hl(0, { name = base, link = false }).fg
    if not fgc then
      api.nvim_set_hl(0, name, { link = fallback, default = true })
      api.nvim_set_hl(0, name .. "Cap", { link = fallback, default = true })
      return
    end
    local r, g, b = bit.rshift(fgc, 16) % 256, bit.rshift(fgc, 8) % 256, fgc % 256
    local dark = (0.299 * r + 0.587 * g + 0.114 * b) > 140
    api.nvim_set_hl(0, name, { bg = fgc, fg = dark and 0x101010 or 0xf0f0f0, bold = true, default = true })
    api.nvim_set_hl(0, name .. "Cap", { fg = fgc, default = true }) -- the rounded ends: pill colour on the window background
  end
  solid("GitCppDiffAddWord", "Added", "DiffText")
  solid("GitCppDiffDelWord", "Removed", "DiffText")
  -- row badges: solid pill in the colour of DiagnosticWarn / DiagnosticInfo
  solid("GitCppDiffPillApi", "DiagnosticWarn", "WarningMsg")
  solid("GitCppDiffPillRenamed", "DiagnosticInfo", "Title")
end

api.nvim_create_autocmd("ColorScheme", { group = api.nvim_create_augroup("GitCppDiffHl", { clear = true }),
  callback = function() M.setup_highlights() end })

local STATUS_HL = {
  added = "GitCppDiffAdded", removed = "GitCppDiffRemoved", modified = "GitCppDiffModified",
  ["api-change"] = "GitCppDiffApi", renamed = "GitCppDiffRenamed",
}
local MARK_HL = {
  accepted = "GitCppDiffAccepted", bad = "GitCppDiffBad", pending = "GitCppDiffDim", partial = "GitCppDiffModified",
}
local KIND_HL = {
  class = "GitCppDiffKindType", struct = "GitCppDiffKindType", union = "GitCppDiffKindType",
  enum = "GitCppDiffKindEnum", ["function"] = "GitCppDiffKindFunc", method = "GitCppDiffKindFunc",
  constructor = "GitCppDiffKindFunc", destructor = "GitCppDiffKindFunc", operator = "GitCppDiffKindOp",
  field = "GitCppDiffKindField", alias = "GitCppDiffKindType",
}
local STATUS_LABEL = {
  added = "added", removed = "removed", modified = "modified", ["api-change"] = "API change", renamed = "renamed",
}

local function glyphs()
  local c = vim.fn.nr2char
  if cfg().icons then
    return {
      status = { added = c(0xf067), removed = c(0xf068), modified = c(0xf040), ["api-change"] = c(0xf071), renamed = c(0xf0ec) },
      kind = {
        class = c(0xeb5b), struct = c(0xea91), union = c(0xea91), enum = c(0xea95), ["function"] = c(0xf0295),
        method = c(0xea8c), constructor = c(0xea8c), destructor = c(0xea8c), operator = c(0xeb64),
        field = c(0xeb5f), alias = c(0xeb61), namespace = c(0xea8b),
      },
      mark = { accepted = c(0xf00c), bad = c(0xf00d), pending = c(0xf10c), partial = c(0xf068) },
      file_src = c(0xe61d) .. " ", file_hdr = c(0xe61e) .. " ",
      mid = "├─ ", last = "└─ ", cont = "│  ", blank = "   ", arrow = "↳ ",
      fold_open = c(0xf078) .. " ", fold_closed = c(0xf054) .. " ", fold_none = "  ",
      pill_l = c(0xe0b6), pill_r = c(0xe0b4), -- rounded powerline caps
    }
  end
  return {
    status = { added = "+", removed = "-", modified = "~", ["api-change"] = "!", renamed = ">" },
    kind = { class = "C", struct = "C", union = "C", enum = "E", ["function"] = "f", method = "f",
      constructor = "f", destructor = "f", operator = "f", field = "v", alias = "t", namespace = "N" },
    mark = { accepted = "[x]", bad = "[!]", pending = "[ ]", partial = "[-]" },
    file_src = "", file_hdr = "",
    mid = "|- ", last = "`- ", cont = "|  ", blank = "   ", arrow = "-> ",
    fold_open = "v ", fold_closed = "> ", fold_none = "  ",
  }
end

-- ───────────────────────────────── list rendering ─────────────────────────────────

local function is_header_path(p)
  return p:match("%.h$") or p:match("%.hh$") or p:match("%.hpp$") or p:match("%.hxx$")
    or p:match("%.inl$") or p:match("%.ipp$") or p:match("%.tpp$") or p:match("%.h%+%+$")
end

local function render_row(ent, G)
  local node, c = ent.node, ent.node.change
  local L = { text = "", hl = {} }
  local function put(s, hl, hl2)
    if hl then L.hl[#L.hl + 1] = { #L.text, #L.text + #s, hl } end
    if hl2 then L.hl[#L.hl + 1] = { #L.text, #L.text + #s, hl2 } end
    L.text = L.text .. s
  end
  local function counts()
    for _, s in ipairs(model_m.STATUSES) do
      local n = node._cnt[s]
      if n and n > 0 then put(" " .. G.status[s] .. " " .. n, STATUS_HL[s]) end
    end
  end

  local own = c ~= nil and ent.show_own
  local st = own and (S.marks[c.id] or "pending") or model_m.state_of(node, S.marks)
  put(" ")
  put(G.mark[st], MARK_HL[st])
  put(" ")
  local arrow = ent.has_kids and (ent.folded and G.fold_closed or G.fold_open) or G.fold_none

  if node.kind == "file" then
    put(arrow, "GitCppDiffDim")
    put(is_header_path(node.label) and G.file_hdr or G.file_src, "GitCppDiffKindType")
    local dir, name = node.label:match("^(.*/)([^/]*)$")
    if dir then
      put(dir, "GitCppDiffDim")
      put(name, "GitCppDiffFile", "GitCppDiffBold")
    else
      put(node.label, "GitCppDiffFile", "GitCppDiffBold")
    end
    counts()
    return L
  end

  for _, last in ipairs(ent.pstack) do put(last and G.blank or G.cont, "GitCppDiffGuide") end
  put(ent.is_last and G.last or G.mid, "GitCppDiffGuide")
  put(arrow, "GitCppDiffDim")

  if own then
    local name = c.name
    local label = c.label or c.name
    local rest = label:sub(1, #name) == name and label:sub(#name + 1) or ""

    -- tail: tags, member count, counts, line number (always kept visible)
    local tail = {}
    local function tput(t, hl, hl2) tail[#tail + 1] = { t, hl, hl2 } end
    if model_m.TYPE_KINDS[c.kind] then tput("  " .. c.kind, "GitCppDiffDim") end
    tput("  ")
    -- a rounded pill (like the CLI); plain [TEXT] without icons
    local function pill(text, group, fallback)
      if G.pill_l then
        tput(G.pill_l, group .. "Cap")
        tput(" " .. text .. " ", group)
        tput(G.pill_r, group .. "Cap")
        tput(" ")
      else
        tput("[" .. text .. "]", fallback, "GitCppDiffBold")
      end
    end
    if c.status == "api-change" then
      pill("API", "GitCppDiffPillApi", "GitCppDiffApi")
    elseif c.status == "renamed" then
      local moved = c.reasons and c.reasons[1] and c.reasons[1]:sub(1, 5) == "moved"
      pill(moved and "MOVED" or "RENAMED", "GitCppDiffPillRenamed", "GitCppDiffRenamed")
    elseif c.status == "modified" and c.reasons and #c.reasons > 0 then
      local body, sig = false, false
      for _, r in ipairs(c.reasons) do
        if r == "body changed" then body = true else sig = true end
      end
      local t = (body and sig) and "body + signature" or sig and "signature" or "body"
      if #c.reasons == 1 and (c.reasons[1] == "definition added" or c.reasons[1] == "definition removed") then
        t = c.reasons[1]
      end
      tput(t, "GitCppDiffDim")
    elseif c.api then
      tput("api", "GitCppDiffDim")
    end
    if c._hidden and #c._hidden > 0 then
      tput((c.status == "added" and "  +" or "  -") .. #c._hidden .. " members", "GitCppDiffDim")
    end
    local ctext, chl = callers.tag(c)
    if ctext then tput("  " .. ctext, chl) end
    if #node.children > 0 then
      for _, st2 in ipairs(model_m.STATUSES) do
        local n = node._cnt[st2]
        if n and n > 0 then tput(" " .. G.status[st2] .. " " .. n, STATUS_HL[st2]) end
      end
    end
    tput("  :" .. c.line, "GitCppDiffDim")

    put(G.status[c.status] .. " ", STATUS_HL[c.status], "GitCppDiffBold")
    put((G.kind[c.kind] or "?") .. " ", KIND_HL[c.kind])
    local nhl = c.status == "added" and "GitCppDiffAdded" or c.status == "removed" and "GitCppDiffRemoved" or nil
    put(name, nhl, "GitCppDiffBold")
    if c.status == "removed" then L.hl[#L.hl + 1] = { #L.text - #name, #L.text, "GitCppDiffStrike" } end

    local tail_w = 0
    for _, t in ipairs(tail) do tail_w = tail_w + vim.fn.strdisplaywidth(t[1]) end
    local budget = (ent.maxw or 200) - vim.fn.strdisplaywidth(L.text) - tail_w - 1
    if rest ~= "" and budget > 1 then
      if vim.fn.strdisplaywidth(rest) > budget then rest = vim.fn.strcharpart(rest, 0, budget - 1) .. "…" end
      put(rest, "GitCppDiffDim")
    end
    for _, t in ipairs(tail) do put(t[1], t[2], t[3]) end
  else
    put((node.is_type and G.kind.class or G.kind.namespace) .. " ", node.is_type and "GitCppDiffKindType" or "GitCppDiffFile")
    put(node.label, "GitCppDiffScope", "GitCppDiffItalic")
    counts()
  end
  return L
end

local function esc(s) return (s:gsub("%%", "%%%%")) end

local function key_label(name)
  local k = cfg().keys[name]
  if type(k) == "table" then k = k[1] end
  return k and tostring(k):gsub("<CR>", "⏎"):gsub("<Tab>", "⇥"):gsub("<Esc>", "Esc") or "?"
end

local function update_winbar()
  local G = glyphs()
  local st = model_m.stats(S.model, S.marks)
  local function shown(v) return v and "%#GitCppDiffAccepted#shown" or "%#GitCppDiffDim#hidden" end
  local bar = table.concat({
    "%#GitCppDiffAccepted# ", G.mark.accepted, " ", st.accepted,
    " %#GitCppDiffBad# ", G.mark.bad, " ", st.bad,
    " %#GitCppDiffDim# ", G.mark.pending, " ", st.pending, " pending",
    (S.callers and S.callers.total > 0 and S.callers.done < S.callers.total)
      and ("  %#GitCppDiffDim#callers " .. S.callers.done .. "/" .. S.callers.total ..
        (S.callers.waiting and " (waiting for index)" or "")) or "",
    "%=",
    "%#GitCppDiffDim#", esc(key_label("toggle_accepted")), " accepted:", shown(S.filter.show_accepted),
    "  %#GitCppDiffDim#", esc(key_label("toggle_bad")), " bad:", shown(S.filter.show_bad), " ",
  })
  vim.wo[S.list_win].winbar = bar
end

local update_preview

local function render(keep)
  local G = glyphs()
  S.rows = model_m.flatten(S.model, S.marks, S.filter, S.folded)
  local lines, hls = {}, {}
  if #S.rows == 0 then
    lines[1] = "  nothing to show — " .. key_label("show_all") .. " shows everything"
  else
    for i, ent in ipairs(S.rows) do
      ent.maxw = api.nvim_win_get_width(S.list_win) - 1
      local L = render_row(ent, G)
      lines[i], hls[i] = L.text, L.hl
    end
  end
  local buf = S.list_buf
  vim.bo[buf].modifiable = true
  api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  api.nvim_buf_clear_namespace(buf, NS, 0, -1)
  for i, hl in ipairs(hls) do
    for _, h in ipairs(hl) do
      api.nvim_buf_set_extmark(buf, NS, i - 1, h[1], { end_col = h[2], hl_group = h[3] })
    end
  end
  update_winbar()

  local row = 1
  if keep and keep.key then
    for i, ent in ipairs(S.rows) do
      if ent.node.key == keep.key then row = i break end
    end
    if row == 1 and keep.row and S.rows[1] and S.rows[1].node.key ~= keep.key then row = keep.row end
  elseif keep and keep.row then
    row = keep.row
  end
  row = math.max(1, math.min(row, #lines))
  api.nvim_win_set_cursor(S.list_win, { row, 0 })
  update_preview()
end

local function cur_row() return api.nvim_win_get_cursor(S.list_win)[1] end

local function cur_change()
  local ent = S.rows[cur_row()]
  return ent and model_m.first_change(ent.node), ent
end

-- ───────────────────────────────────── marking ─────────────────────────────────────

local function set_marks(rows, state)
  local ids, seen = {}, {}
  for _, r in ipairs(rows) do
    local ent = S.rows[r]
    if ent then
      for _, c in ipairs(model_m.collect(ent.node)) do
        if not seen[c.id] then seen[c.id] = true; ids[#ids + 1] = c.id end
      end
    end
  end
  if #ids == 0 then return end
  if state then -- pressing the same key again clears (toggle)
    local all = true
    for _, id in ipairs(ids) do
      if S.marks[id] ~= state then all = false break end
    end
    if all then state = nil end
  end
  for _, id in ipairs(ids) do S.marks[id] = state end
  if cfg().persist then marks_m.save(S.data.root, S.marks) end

  local row = rows[1]
  local ent = S.rows[row]
  local key = ent and ent.node.key
  render({ key = key, row = row })
  if cfg().advance and #rows == 1 and S.rows[row] and S.rows[row].node.key == key and row < #S.rows then
    api.nvim_win_set_cursor(S.list_win, { row + 1, 0 })
    update_preview()
  end
end

local function mark_cmd(state)
  return function() set_marks({ cur_row() }, state) end
end

local function mark_visual(state)
  return function()
    local a, b = vim.fn.line("v"), vim.fn.line(".")
    if a > b then a, b = b, a end
    api.nvim_feedkeys(api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
    local rows = {}
    for r = a, b do rows[#rows + 1] = r end
    set_marks(rows, state)
  end
end

-- ───────────────────────────────────── preview ─────────────────────────────────────

local function set_preview_buf(lines, ft, key)
  local buf = S.prev_buf
  if S.prev_key ~= key then
    vim.bo[buf].modifiable = true
    api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].filetype = ft
    pcall(vim.treesitter.stop, buf)
    if ft ~= "" then pcall(vim.treesitter.start, buf, ft == "diff" and "diff" or "cpp") end
    S.prev_key = key
  end
  api.nvim_buf_clear_namespace(buf, PNS, 0, -1)
end

local function preview_title(text)
  pcall(api.nvim_win_set_config, S.prev_win, { title = { { " " .. text .. " ", "GitCppDiffTitle" } }, title_pos = "left" })
end

local function preview_bar(c)
  local width = api.nvim_win_get_width(S.prev_win) - 2
  local head = " " .. (STATUS_LABEL[c.status] or c.status) .. " "
  local name = c.qualified_name
  local reasons = table.concat(c.reasons or {}, "  ·  ")
  local csum = callers.summary(c)
  if csum then reasons = csum .. (reasons ~= "" and ("  ·  " .. reasons) or "") end
  local room = width - vim.fn.strdisplaywidth(head) - vim.fn.strdisplaywidth(name) - 2
  if room < 0 then
    name = vim.fn.strcharpart(name, 0, math.max(1, vim.fn.strchars(name) + room - 1)) .. "…"
    reasons, room = "", 0
  end
  if vim.fn.strdisplaywidth(reasons) > room - 2 then
    reasons = room > 4 and (vim.fn.strcharpart(reasons, 0, room - 3) .. "…") or ""
  end
  vim.wo[S.prev_win].winbar = table.concat({
    "%#", STATUS_HL[c.status] or "GitCppDiffDim", "#", esc(head),
    "%#GitCppDiffDim# ", esc(name),
    reasons ~= "" and ("  " .. esc(reasons)) or "",
  })
end

local function show_source(c)
  local t = preview.target(c)
  local lines = preview.read(S, t.side, t.file)
  if not lines then
    set_preview_buf({ "(could not read " .. t.file .. ")" }, "", "err")
    return
  end
  set_preview_buf(lines, "cpp", t.side .. "|" .. t.file)
  local last = math.min(#lines, t.end_line or t.line)
  api.nvim_buf_set_extmark(S.prev_buf, PNS, t.line - 1, 0, { end_row = last, end_col = 0, hl_group = "GitCppDiffRange", hl_eol = true })
  preview_title(string.format("%s%s:%d", t.side == "old" and "(base) " or "", t.file, t.line))
  pcall(api.nvim_win_set_cursor, S.prev_win, { math.min(t.line, #lines), 0 })
  api.nvim_win_call(S.prev_win, function() vim.fn.winrestview({ topline = math.max(1, t.line - 4) }) end)
end

local function show_diff(c)
  local lines, headers, hls = preview.diff_lines(S, c)
  S.prev_key = nil
  set_preview_buf(lines, "diff", "diff|" .. c.id)
  for _, h in ipairs(hls) do
    if h.line then
      -- a range extmark (not line_hl_group): that one would win over the word highlight's background
      api.nvim_buf_set_extmark(S.prev_buf, PNS, h.row, 0, { end_row = h.row + 1, end_col = 0, hl_group = h.group, hl_eol = true, priority = 150 })
    else
      local len = #(lines[h.row + 1] or "")
      api.nvim_buf_set_extmark(S.prev_buf, PNS, h.row, math.min(h.s, len), { end_col = math.min(h.e, len), hl_group = h.group, priority = 250 })
    end
  end
  for _, r in ipairs(headers) do
    api.nvim_buf_set_extmark(S.prev_buf, PNS, r, 0, { end_row = r + 1, end_col = 0, hl_group = "GitCppDiffTitle", hl_eol = true })
  end
  preview_title("diff · " .. c.qualified_name)
  pcall(api.nvim_win_set_cursor, S.prev_win, { 1, 0 })
  api.nvim_win_call(S.prev_win, function() vim.fn.winrestview({ topline = 1 }) end)
end

update_preview = function()
  if not S or not api.nvim_win_is_valid(S.prev_win) then return end
  S.showing_help = false
  local c = cur_change()
  if not c then
    S.prev_key = nil
    set_preview_buf({ "" }, "", "empty")
    vim.wo[S.prev_win].winbar = ""
    return
  end
  preview_bar(c)
  if S.preview_mode == "diff" then
    S.prev_key = nil -- diff content is per-change
    show_diff(c)
  else
    show_source(c)
  end
end

local function help_lines()
  local k = key_label
  return {
    " gitcppdiff",
    "",
    " " .. k("accept") .. "   accept change      (again = clear; visual: range)",
    " " .. k("bad") .. "   mark change as bad (again = clear; visual: range)",
    " " .. k("clear") .. "   clear mark",
    "     on a class / namespace / file row the mark applies to everything below it",
    "",
    " " .. k("toggle_accepted") .. "   show / hide accepted changes",
    " " .. k("toggle_bad") .. "   show / hide bad changes",
    " " .. k("show_all") .. "   show everything",
    "",
    " " .. k("jump") .. "  jump to the location (declaration)",
    " " .. k("jump_definition") .. "  jump to the definition (.cpp)",
    " " .. k("preview_mode") .. "  toggle preview: source / diff (word-level)",
    " " .. k("callers") .. "  callers / references of the change -> quickfix",
    "",
    " " .. k("fold_toggle") .. " " .. k("fold_close") .. " " .. k("fold_open") .. "  fold: toggle / close / open",
    " " .. k("fold_close_all") .. " " .. k("fold_open_all") .. "  close / open all folds",
    " " .. k("fold_left") .. " " .. k("fold_right") .. "  collapse or parent / expand or first child",
    "",
    " " .. k("expand") .. "   expand / collapse members of added / removed classes",
    " " .. k("refresh") .. "   re-run gitcppdiff",
    " " .. k("quickfix") .. "  send visible changes to the quickfix list",
    " " .. k("close") .. "   close",
  }
end

-- ───────────────────────────────────── jumping ─────────────────────────────────────

local function jump(want_def)
  local c = cur_change()
  if not c then return end
  local t = want_def and preview.definition_target(c) or preview.target(c)
  if not t then
    vim.notify("gitcppdiff: no separate definition for this symbol", vim.log.levels.INFO)
    return
  end
  local d = S.data
  M.close()
  jumpm.open(d, t)
end

local function to_quickfix()
  local items = {}
  for _, ent in ipairs(S.rows) do
    local c = ent.node.change
    if c and ent.show_own then
      items[#items + 1] = {
        filename = S.data.root .. "/" .. c.file, lnum = c.line,
        text = string.format("[%s] %s %s", STATUS_LABEL[c.status] or c.status, c.kind, c.qualified_name),
      }
    end
  end
  local root = S.data.root
  M.close()
  vim.fn.setqflist({}, " ", { title = "gitcppdiff", items = items, context = root })
  vim.cmd("copen")
end

-- ───────────────────────────────────── folding ─────────────────────────────────────

--- Key of the outermost folded ancestor of `node` (or its own key): where the cursor should land.
local function visible_key(node)
  local key = node.key
  local n = node.parent
  while n do
    if S.folded[n.key] then key = n.key end
    n = n.parent
  end
  return key
end

local function refold(node, row)
  render({ key = node and visible_key(node) or nil, row = row })
end

local function fold_set(closed)
  return function()
    local row = cur_row()
    local ent = S.rows[row]
    if not ent then return end
    if ent.has_kids then
      S.folded[ent.node.key] = closed or nil
      refold(ent.node, row)
    elseif closed and ent.node.parent then -- zc on a leaf closes its parent
      local p = ent.node.parent
      S.folded[p.key] = true
      refold(p, row)
    end
  end
end

local function fold_toggle()
  local ent = S.rows[cur_row()]
  if not ent or not ent.has_kids then return end
  S.folded[ent.node.key] = (not S.folded[ent.node.key]) or nil
  refold(ent.node, cur_row())
end

local function fold_all(closed)
  return function()
    local ent = S.rows[cur_row()]
    S.folded = {}
    if closed then
      model_m.walk(S.model, function(n) if #n.children > 0 then S.folded[n.key] = true end end)
    end
    refold(ent and ent.node, cur_row())
  end
end

local function goto_node_row(node)
  for i, e in ipairs(S.rows) do
    if e.node == node then
      api.nvim_win_set_cursor(S.list_win, { i, 0 })
      update_preview()
      return
    end
  end
end

local function fold_left()
  local ent = S.rows[cur_row()]
  if not ent then return end
  if ent.has_kids and not ent.folded then
    S.folded[ent.node.key] = true
    refold(ent.node, cur_row())
  elseif ent.node.parent then
    goto_node_row(ent.node.parent)
  end
end

local function fold_right()
  local row = cur_row()
  local ent = S.rows[row]
  if not ent or not ent.has_kids then return end
  if ent.folded then
    S.folded[ent.node.key] = nil
    refold(ent.node, row)
  elseif S.rows[row + 1] then
    api.nvim_win_set_cursor(S.list_win, { row + 1, 0 })
    update_preview()
  end
end

local function initial_folds(model, mode)
  local f = {}
  if mode == "none" or not mode then return f end
  model_m.walk(model, function(n)
    if #n.children == 0 then return end
    local is_file = n.kind == "file"
    local is_class = n.is_type or (n.change and model_m.TYPE_KINDS[n.change.kind])
    if mode == "all" or (mode == "files" and is_file) or (mode == "classes" and is_class) then
      f[n.key] = true
    end
  end)
  return f
end

--- Move to the next / previous row that is a change (used by :CppDiffNext / :CppDiffPrev).
function M.step(dir, count)
  if not S then return end
  local n = #S.rows
  local row = cur_row()
  for _ = 1, count or 1 do
    for _ = 1, n do
      row = ((row - 1 + dir) % n) + 1
      local e = S.rows[row]
      if e and e.node.change and e.show_own then break end
    end
  end
  api.nvim_win_set_cursor(S.list_win, { row, 0 })
  update_preview()
end

-- ───────────────────────────────────── callers ─────────────────────────────────────

local function on_callers_update()
  if not S or not S.callers or S.callers.stopped then return end
  if S.callers_timer then return end
  S.callers_timer = true
  vim.defer_fn(function()
    if not S then return end
    S.callers_timer = nil
    local ent = S.rows[cur_row()]
    render({ key = ent and ent.node.key, row = cur_row() })
  end, 60)
end

local function callers_to_qf()
  local c = cur_change()
  if not c then return end
  if not c._callers then
    vim.notify("gitcppdiff: no caller information for this row (only API changes and removed symbols)", vim.log.levels.INFO)
    return
  end
  local items = callers.items(c)
  local root, title = S.data.root, "gitcppdiff: " .. (callers.summary(c) or "") .. " – " .. c.qualified_name
  M.close()
  vim.fn.setqflist({}, " ", { title = title, items = items, context = root })
  vim.cmd("copen")
end

local function callers_request()
  local c = cur_change()
  if not c then return end
  if c._callers then return callers_to_qf() end
  if not (c.status == "api-change" or c.status == "removed") then
    vim.notify("gitcppdiff: callers are computed for API changes and removed symbols", vim.log.levels.INFO)
    return
  end
  S.callers.total = S.callers.total + 1
  callers.request(S, c, function() on_callers_update() end, S.callers_client)
end

-- ─────────────────────────────────── windows & keys ───────────────────────────────────

local BORDERS = {
  rounded = { { "╭", "─", "─", "│", "─", "─", "╰", "│" }, { "┬", "─", "╮", "│", "╯", "─", "┴", "│" } },
  single = { { "┌", "─", "─", "│", "─", "─", "└", "│" }, { "┬", "─", "┐", "│", "┘", "─", "┴", "│" } },
  double = { { "╔", "═", "═", "║", "═", "═", "╚", "║" }, { "╦", "═", "╗", "║", "╝", "═", "╩", "║" } },
}

local function layout()
  local c = cfg()
  local cols, rows = vim.o.columns, vim.o.lines - vim.o.cmdheight
  local W = math.min(cols, math.max(60, math.floor(cols * c.width)))
  local H = math.min(rows - 2, math.max(12, math.floor(rows * c.height)))
  local row0, col0 = math.floor((rows - H) / 2), math.floor((cols - W) / 2)
  local lo = math.max(34, math.floor(W * c.list_width))
  local pair = type(c.border) == "string" and BORDERS[c.border]
  local lb, pb = c.border, c.border
  local overlap = 0
  if pair then lb, pb, overlap = pair[1], pair[2], 1 end
  local po = W - lo + overlap
  return {
    list = { relative = "editor", row = row0, col = col0, width = lo - 2, height = H - 2, border = lb },
    prev = { relative = "editor", row = row0, col = col0 + lo - overlap, width = math.max(10, po - 2), height = H - 2, border = pb },
  }
end

local function footer(width)
  local k = key_label
  local variants = {
    string.format(" %s accept · %s bad · %s clear · %s/%s/%s filter · %s jump · %s diff · %s help ",
      k("accept"), k("bad"), k("clear"), k("toggle_accepted"), k("toggle_bad"), k("show_all"), k("jump"), k("preview_mode"), k("help")),
    string.format(" %s accept · %s bad · %s/%s/%s filter · %s jump · %s help ",
      k("accept"), k("bad"), k("toggle_accepted"), k("toggle_bad"), k("show_all"), k("jump"), k("help")),
    string.format(" %s accept · %s bad · %s help ", k("accept"), k("bad"), k("help")),
    string.format(" %s help ", k("help")),
  }
  for _, v in ipairs(variants) do
    if vim.fn.strdisplaywidth(v) <= width - 2 then return v end
  end
  return variants[#variants]
end

local function map(buf, modes, lhs, fn, desc)
  if lhs == false or lhs == nil then return end
  for _, l in ipairs(type(lhs) == "table" and lhs or { lhs }) do
    vim.keymap.set(modes, l, fn, { buffer = buf, nowait = true, silent = true, desc = "gitcppdiff: " .. desc })
  end
end

local function setup_keys()
  local k, b = cfg().keys, S.list_buf
  map(b, "n", k.accept, mark_cmd("accepted"), "accept")
  map(b, "x", k.accept, mark_visual("accepted"), "accept selection")
  map(b, "n", k.bad, mark_cmd("bad"), "mark bad")
  map(b, "x", k.bad, mark_visual("bad"), "mark selection bad")
  map(b, "n", k.clear, mark_cmd(nil), "clear mark")
  map(b, "x", k.clear, mark_visual(nil), "clear marks")

  local function refilter()
    local ent = S.rows[cur_row()]
    render({ key = ent and ent.node.key, row = cur_row() })
  end
  map(b, "n", k.toggle_accepted, function() S.filter.show_accepted = not S.filter.show_accepted; refilter() end, "toggle accepted")
  map(b, "n", k.toggle_bad, function() S.filter.show_bad = not S.filter.show_bad; refilter() end, "toggle bad")
  map(b, "n", k.show_all, function() S.filter.show_accepted, S.filter.show_bad = true, true; refilter() end, "show all")

  map(b, "n", k.jump, function() jump(false) end, "jump")
  map(b, "n", k.jump_definition, function() jump(true) end, "jump to definition")
  map(b, "n", k.preview_mode, function()
    S.preview_mode = S.preview_mode == "diff" and "source" or "diff"
    S.prev_key = nil
    update_preview()
  end, "toggle preview")
  map(b, "n", k.expand, function()
    S.expand = not S.expand
    local ent = S.rows[cur_row()]
    S.model = model_m.build(S.data, { expand = S.expand })
    render({ key = ent and ent.node.key, row = cur_row() })
  end, "expand members")
  map(b, "n", k.callers, callers_request, "callers / references")
  map(b, "n", k.fold_toggle, fold_toggle, "toggle fold")
  map(b, "n", k.fold_close, fold_set(true), "close fold")
  map(b, "n", k.fold_open, fold_set(false), "open fold")
  map(b, "n", k.fold_close_all, fold_all(true), "close all folds")
  map(b, "n", k.fold_open_all, fold_all(false), "open all folds")
  map(b, "n", k.fold_left, fold_left, "fold / parent")
  map(b, "n", k.fold_right, fold_right, "unfold / first child")
  map(b, "n", k.refresh, function() M.refresh() end, "refresh")
  map(b, "n", k.quickfix, to_quickfix, "quickfix")
  map(b, "n", k.close, function() M.close() end, "close")
  map(b, "n", k.help, function()
    S.prev_key = nil
    set_preview_buf(help_lines(), "", "help")
    S.showing_help = true
    vim.wo[S.prev_win].winbar = ""
    preview_title("help")
  end, "help")
end

local function open_windows(range)
  local L = layout()
  local lbuf = api.nvim_create_buf(false, true)
  local pbuf = api.nvim_create_buf(false, true)
  for _, b in ipairs({ lbuf, pbuf }) do
    vim.bo[b].buftype, vim.bo[b].bufhidden, vim.bo[b].swapfile = "nofile", "wipe", false
  end
  vim.bo[lbuf].filetype = "gitcppdiff"
  local lwin = api.nvim_open_win(lbuf, true, vim.tbl_extend("force", L.list, {
    style = "minimal", zindex = 50,
    title = { { " gitcppdiff ", "GitCppDiffTitle" }, { range .. " ", "GitCppDiffDim" } }, title_pos = "left",
    footer = { { footer(L.list.width), "GitCppDiffDim" } }, footer_pos = "center",
  }))
  local pwin = api.nvim_open_win(pbuf, false, vim.tbl_extend("force", L.prev, {
    style = "minimal", zindex = 51, focusable = false,
  }))
  for _, w in ipairs({ lwin, pwin }) do
    vim.wo[w].wrap, vim.wo[w].foldenable, vim.wo[w].signcolumn = false, false, "no"
  end
  vim.wo[lwin].cursorline = true
  vim.wo[lwin].scrolloff = 2
  vim.wo[pwin].number, vim.wo[pwin].cursorline, vim.wo[pwin].scrolloff = true, false, 0
  return lbuf, lwin, pbuf, pwin
end

function M.is_open()
  return S ~= nil and api.nvim_win_is_valid(S.list_win)
end

function M.close()
  if not S then return end
  local s = S
  S = nil
  callers.stop(s)
  pcall(api.nvim_del_augroup_by_name, AUG)
  for _, w in ipairs({ s.list_win, s.prev_win }) do
    if w and api.nvim_win_is_valid(w) then pcall(api.nvim_win_close, w, true) end
  end
end

local function attach(data, keep)
  local model = model_m.build(data, { expand = keep.expand })
  S = {
    data = data, model = model, cache = {}, expand = keep.expand,
    marks = cfg().persist and marks_m.load(data.root) or {},
    filter = filter, preview_mode = keep.preview_mode, args = keep.args,
    folded = keep.folded or initial_folds(model, cfg().fold),
  }
  nav.remember(data, S.marks, keep.args, keep.expand)
  S.list_buf, S.list_win, S.prev_buf, S.prev_win = open_windows(data.range)
  setup_keys()
  api.nvim_create_augroup(AUG, { clear = true })
  api.nvim_create_autocmd("CursorMoved", {
    group = AUG, buffer = S.list_buf,
    callback = function() if S then update_preview() end end,
  })
  api.nvim_create_autocmd("WinLeave", {
    group = AUG, buffer = S.list_buf,
    callback = function() vim.schedule(M.close) end,
  })
  api.nvim_create_autocmd("VimResized", {
    group = AUG,
    callback = function()
      if not M.is_open() then return end
      local L = layout()
      api.nvim_win_set_config(S.list_win, vim.tbl_extend("force", L.list, { footer = { { footer(L.list.width), "GitCppDiffDim" } }, footer_pos = "center" }))
      api.nvim_win_set_config(S.prev_win, L.prev)
      render({ key = S.rows[cur_row()] and S.rows[cur_row()].node.key, row = cur_row() })
    end,
  })
  render()
  callers.start(S, on_callers_update)
end

-- ──────────────────────────────── running the executable ────────────────────────────────

local function run(args, cb)
  local exe = bin.find()
  if not exe then
    vim.notify("gitcppdiff: executable not found. Run :CppDiffBuild (needs cmake + make), " ..
      "or set `bin` in setup().", vim.log.levels.ERROR)
    return
  end
  local dir
  local has_C = vim.tbl_contains(args, "-C")
  if not has_C then
    local name = api.nvim_buf_get_name(0)
    dir = (name ~= "" and not name:find("^%w+://")) and vim.fs.dirname(name) or vim.uv.cwd()
    if vim.fn.isdirectory(dir) == 0 then dir = vim.uv.cwd() end
  end
  local cmd = { exe, "--format", "json", "--color", "never" }
  if dir then vim.list_extend(cmd, { "-C", dir }) end
  vim.list_extend(cmd, cfg().extra_args or {})
  vim.list_extend(cmd, args)
  vim.system(cmd, { text = true }, vim.schedule_wrap(function(res)
    if res.code ~= 0 then
      local msg = vim.trim(res.stderr or "")
      vim.notify("gitcppdiff: " .. (msg ~= "" and msg or ("exit code " .. res.code)), vim.log.levels.ERROR)
      return
    end
    local ok, data = pcall(vim.json.decode, res.stdout, { luanil = { object = true, array = true } })
    if not ok or type(data) ~= "table" then
      vim.notify("gitcppdiff: could not parse output", vim.log.levels.ERROR)
      return
    end
    if (data.schema or 0) < 2 then
      vim.notify("gitcppdiff: executable is too old (JSON schema " .. tostring(data.schema) ..
        "); rebuild with :CppDiffBuild", vim.log.levels.ERROR)
      return
    end
    cb(data)
  end))
end

function M.open(args)
  args = args or {}
  M.setup_highlights()
  if not filter then
    filter = { show_accepted = cfg().show_accepted, show_bad = cfg().show_bad }
  end
  local keep = {
    expand = S and S.expand or cfg().expand,
    preview_mode = S and S.preview_mode or cfg().preview,
    args = args,
  }
  run(args, function(data)
    if #(data.changes or {}) == 0 then
      M.close()
      vim.notify("gitcppdiff: no C++ symbol changes (" .. data.range .. ")", vim.log.levels.INFO)
      return
    end
    M.close()
    attach(data, keep)
  end)
end

function M.refresh()
  if not S then return end
  local keep = { expand = S.expand, preview_mode = S.preview_mode, args = S.args, folded = S.folded }
  callers.clear_cache()
  local ent = S.rows[cur_row()]
  local key = ent and ent.node.key
  run(S.args, function(data)
    if #(data.changes or {}) == 0 then
      M.close()
      vim.notify("gitcppdiff: no C++ symbol changes left", vim.log.levels.INFO)
      return
    end
    M.close()
    attach(data, keep)
    if key then render({ key = key }) end
  end)
end

function M.clear_marks()
  local root = S and S.data.root
  if not root then
    local r = vim.fs.root(0, ".git") or vim.uv.cwd()
    root = r
  end
  marks_m.clear(root)
  if S then S.marks = {}; render({ row = cur_row() }) end
  vim.notify("gitcppdiff: cleared marks for " .. root)
end

--- Run the executable without opening a window (used by :CppDiffNext when nothing was run yet).
function M.load(args, cb)
  M.setup_highlights()
  run(args or {}, function(data)
    if #(data.changes or {}) == 0 then
      vim.notify("gitcppdiff: no C++ symbol changes (" .. data.range .. ")", vim.log.levels.INFO)
      return
    end
    cb(data)
  end)
end

--- Register a result for navigation without a window.
function M.remember(data, args)
  filter = filter or { show_accepted = cfg().show_accepted, show_bad = cfg().show_bad }
  nav.remember(data, cfg().persist and marks_m.load(data.root) or {}, args, cfg().expand)
end

function M.get_filter()
  filter = filter or { show_accepted = cfg().show_accepted, show_bad = cfg().show_bad }
  return filter
end

--- exposed for tests
function M._session() return S end

return M
