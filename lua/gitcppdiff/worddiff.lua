-- Word-level (token) diff of two lines, as byte ranges to highlight.
local M = {}

local diff_fn = (vim.text and vim.text.diff) or vim.diff

local function tokenize(s)
  local toks, pos = {}, 1
  while pos <= #s do
    local a, b = s:find("^[%w_]+", pos)
    if not a then a, b = s:find("^%s+", pos) end
    if not a then
      local c = s:byte(pos)
      local len = c < 0x80 and 1 or c < 0xE0 and 2 or c < 0xF0 and 3 or 4
      a, b = pos, math.min(#s, pos + len - 1)
    end
    toks[#toks + 1] = { text = s:sub(a, b), s = a, e = b }
    pos = b + 1
  end
  return toks
end

local function as_lines(toks)
  local parts = {}
  for i, t in ipairs(toks) do parts[i] = t.text end
  return table.concat(parts, "\n") .. "\n"
end

local function merge(ranges)
  local out = {}
  for _, r in ipairs(ranges) do
    local last = out[#out]
    if last and r[1] - last[2] <= 1 then last[2] = r[2] else out[#out + 1] = { r[1], r[2] } end
  end
  return out
end

local function covered(ranges)
  local n = 0
  for _, r in ipairs(ranges) do n = n + (r[2] - r[1]) end
  return n
end

--- Changed byte ranges {start0, end0exclusive} in `a` and in `b`.
--- Returns empty ranges when the lines are too different for word highlighting to be useful.
---@return integer[][] ra, integer[][] rb
function M.compute(a, b)
  local ta, tb = tokenize(a), tokenize(b)
  if #ta == 0 or #tb == 0 or #ta > 1500 or #tb > 1500 then return {}, {} end
  local hunks = diff_fn(as_lines(ta), as_lines(tb), { result_type = "indices", algorithm = "histogram" })
  local ra, rb = {}, {}
  for _, h in ipairs(hunks or {}) do
    local sa, ca, sb, cb = h[1], h[2], h[3], h[4]
    if ca > 0 then ra[#ra + 1] = { ta[sa].s - 1, ta[sa + ca - 1].e } end
    if cb > 0 then rb[#rb + 1] = { tb[sb].s - 1, tb[sb + cb - 1].e } end
  end
  ra, rb = merge(ra), merge(rb)
  -- almost everything changed: the whole line highlight already says it
  if covered(ra) > 0.7 * #a and covered(rb) > 0.7 * #b then return {}, {} end
  return ra, rb
end

return M
