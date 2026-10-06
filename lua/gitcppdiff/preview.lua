-- Content for the preview pane: file text at the right revision, locations, symbol diffs.
local worddiff = require("gitcppdiff.worddiff")

local M = {}

local function git(root, args)
  local r = vim.system(vim.list_extend({ "git", "-C", root }, args), { text = true }):wait()
  if r.code ~= 0 then return nil end
  return r.stdout
end
M.git = git

local function split(out)
  local lines = vim.split(out, "\n", { plain = true })
  if lines[#lines] == "" then table.remove(lines) end
  return lines
end

--- Lines of `path` on side "old" (base revision) or "new" (head / index / worktree).
---@return string[]|nil
function M.read(sess, side, path)
  local key = side .. "|" .. path
  local cached = sess.cache[key]
  if cached ~= nil then return cached or nil end
  local d = sess.data
  local lines
  if side == "old" then
    local out = git(d.root, { "show", d.base_rev .. ":" .. path })
    lines = out and split(out)
  elseif d.head_kind == "worktree" then
    local f = d.root .. "/" .. path
    lines = vim.fn.filereadable(f) == 1 and vim.fn.readfile(f) or nil
  else
    local spec = d.head_kind == "index" and (":" .. path) or (d.head_rev .. ":" .. path)
    local out = git(d.root, { "show", spec })
    lines = out and split(out)
  end
  sess.cache[key] = lines or false
  return lines
end

--- Where to look for this change: { side, file, line, end_line, kind = "decl"|"def" }
function M.target(c)
  if c.new then
    local n = c.new
    if n.definition and n.definition.file == c.file and n.definition.line == c.line then
      return { side = "new", file = n.definition.file, line = n.definition.line,
               end_line = n.definition.end_line, kind = "def" }
    end
    return { side = "new", file = n.file, line = n.line, end_line = n.end_line, kind = "decl" }
  end
  local o = c.old
  return { side = "old", file = o.file, line = o.line, end_line = o.end_line, kind = "decl" }
end

--- The definition (body) location when it lives apart from the declaration.
function M.definition_target(c)
  if c.new and c.new.definition then
    local d = c.new.definition
    return { side = "new", file = d.file, line = d.line, end_line = d.end_line, kind = "def" }
  end
  if c.old and c.old.definition then
    local d = c.old.definition
    return { side = "old", file = d.file, line = d.line, end_line = d.end_line, kind = "def" }
  end
end

local function slice(lines, a, b)
  local out = {}
  for i = a, math.min(b, #lines) do out[#out + 1] = lines[i] end
  return out
end

local diff_fn = (vim.text and vim.text.diff) or vim.diff

--- Unified diff of the symbol (declaration and, if separate, definition), old -> new.
--- hls: { row = 0-based, group, line = true | s = , e = } — line level and word level highlights.
---@return string[] lines, integer[] header_rows, table[] hls
function M.diff_lines(sess, c)
  local out, headers, hls = {}, {}, {}
  local function section(old, new)
    local ol = old and M.read(sess, "old", old.file)
    local nl = new and M.read(sess, "new", new.file)
    local ot = old and ol and slice(ol, old.line, old.end_line) or {}
    local nt = new and nl and slice(nl, new.line, new.end_line) or {}
    local body = {}
    if not old then
      for _, l in ipairs(nt) do body[#body + 1] = "+" .. l end
    elseif not new then
      for _, l in ipairs(ot) do body[#body + 1] = "-" .. l end
    elseif table.concat(ot, "\n") ~= table.concat(nt, "\n") then
      local d = diff_fn(table.concat(ot, "\n") .. "\n", table.concat(nt, "\n") .. "\n",
        { result_type = "unified", ctxlen = 3, algorithm = "histogram" })
      body = split(d or "")
    end
    if #body == 0 then return end
    local title = (old and old.file or new.file)
    if old and new and old.file ~= new.file then title = old.file .. " → " .. new.file end
    headers[#headers + 1] = #out
    out[#out + 1] = "── " .. title .. " ──"
    local base = #out  -- row (0-based) of body[1]
    vim.list_extend(out, body)
    out[#out + 1] = ""

    -- line level
    for i, l in ipairs(body) do
      local ch = l:sub(1, 1)
      local row = base + i - 1
      if l:sub(1, 2) == "@@" then hls[#hls + 1] = { row = row, group = "GitCppDiffHunk", line = true }
      elseif ch == "+" then hls[#hls + 1] = { row = row, group = "GitCppDiffAddLine", line = true }
      elseif ch == "-" then hls[#hls + 1] = { row = row, group = "GitCppDiffDelLine", line = true } end
    end
    -- word level: pair the i-th removed line of a block with the i-th added line that follows
    local i = 1
    while i <= #body do
      if body[i]:sub(1, 1) == "-" and body[i]:sub(1, 3) ~= "---" then
        local ms = i
        while i <= #body and body[i]:sub(1, 1) == "-" do i = i + 1 end
        local me = i - 1
        local ps = i
        while i <= #body and body[i]:sub(1, 1) == "+" do i = i + 1 end
        local pe = i - 1
        for k = 0, math.min(me - ms, pe - ps) do
          local a, b = body[ms + k]:sub(2), body[ps + k]:sub(2)
          local ra, rb = worddiff.compute(a, b)
          for _, r in ipairs(ra) do
            hls[#hls + 1] = { row = base + ms + k - 1, group = "GitCppDiffDelWord", s = r[1] + 1, e = r[2] + 1 }
          end
          for _, r in ipairs(rb) do
            hls[#hls + 1] = { row = base + ps + k - 1, group = "GitCppDiffAddWord", s = r[1] + 1, e = r[2] + 1 }
          end
        end
      else
        i = i + 1
      end
    end
  end
  section(c.old, c.new)
  section(c.old and c.old.definition, c.new and c.new.definition)
  if #out == 0 then out[1] = "(no textual change in the symbol's source range)" end
  return out, headers, hls
end

return M
