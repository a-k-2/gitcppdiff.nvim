-- Pure data layer: JSON from gitcppdiff -> tree -> filtered, flattened rows.
-- No Neovim UI calls in here, so it is unit-testable.
local M = {}

local TYPE_KINDS = { class = true, struct = true, union = true, enum = true }
local MEMBER_KINDS = { method = true, constructor = true, destructor = true, operator = true, field = true }
M.TYPE_KINDS = TYPE_KINDS
M.STATUSES = { "added", "removed", "modified", "api-change", "renamed" }

local function join(t, n) return table.concat(t, "::", 1, n or #t) end

local function new_node(kind, key, label, parent)
  return { kind = kind, key = key, label = label, children = {}, idx = {}, parent = parent, line = math.huge }
end

--- Build the tree. `opts.expand` disables collapsing of members of added/removed types.
function M.build(data, opts)
  opts = opts or {}
  local changes = data.changes or {}
  local model = { data = data, changes = changes, files = {}, by_id = {} }

  -- members of wholly added/removed types are folded into the type's row
  local owners = {}
  for _, c in ipairs(changes) do
    c._hidden, c._collapsed_by = nil, nil
    if not opts.expand and TYPE_KINDS[c.kind] and (c.status == "added" or c.status == "removed") then
      owners[c.status .. "|" .. c.qualified_name] = c
    end
  end
  for _, c in ipairs(changes) do
    model.by_id[c.id] = c
    if next(owners) then
      local sc = c.scope or {}
      for i = 1, #sc do
        local o = owners[c.status .. "|" .. join(sc, i)]
        if o and o ~= c then
          c._collapsed_by = o
          o._hidden = o._hidden or {}
          o._hidden[#o._hidden + 1] = c
          break
        end
      end
    end
  end

  local by_path = {}
  local function file_node(path)
    if not by_path[path] then
      local n = new_node("file", "f|" .. path, path, nil)
      by_path[path] = n
      model.files[#model.files + 1] = n
    end
    return by_path[path]
  end
  local function scope_child(parent, seg, key)
    local n = parent.idx[seg]
    if not n then
      n = new_node("scope", key, seg, parent)
      parent.idx[seg] = n
      parent.children[#parent.children + 1] = n
    end
    return n
  end

  for _, c in ipairs(changes) do
    if not c._collapsed_by then
      local fnode = file_node(c.file)
      local parent = fnode
      local sc = c.scope or {}
      for i = 1, #sc do parent = scope_child(parent, sc[i], c.file .. "|" .. join(sc, i)) end
      if MEMBER_KINDS[c.kind] and parent.kind == "scope" then parent.is_type = true end
      if TYPE_KINDS[c.kind] then
        local n = scope_child(parent, c.name, c.file .. "|" .. c.qualified_name)
        n.change, n.is_type = c, true
      else
        local n = new_node("change", c.id, c.name, parent)
        n.change = c
        parent.children[#parent.children + 1] = n
      end
    end
  end

  table.sort(model.files, function(a, b) return a.label < b.label end)
  local function finalize(n)
    n._cnt = {}
    if n.change then n.line = n.change.line end
    for _, k in ipairs(n.children) do
      k.parent = n
      finalize(k)
      n.line = math.min(n.line, k.line)
      for s, v in pairs(k._cnt) do n._cnt[s] = (n._cnt[s] or 0) + v end
      if k.change then n._cnt[k.change.status] = (n._cnt[k.change.status] or 0) + 1 end
    end
    table.sort(n.children, function(a, b)
      if a.line ~= b.line then return a.line < b.line end
      return a.label < b.label
    end)
  end
  for _, f in ipairs(model.files) do finalize(f) end
  return model
end

--- All changes represented by a node: itself, its descendants and folded members.
function M.collect(node)
  if node._all then return node._all end
  local out = {}
  local function add(n)
    if n.change then
      out[#out + 1] = n.change
      for _, h in ipairs(n.change._hidden or {}) do out[#out + 1] = h end
    end
    for _, k in ipairs(n.children) do add(k) end
  end
  add(node)
  node._all = out
  return out
end

--- First change at or below a node (what the preview shows for group rows).
function M.first_change(node)
  if node.change then return node.change end
  for _, k in ipairs(node.children) do
    local c = M.first_change(k)
    if c then return c end
  end
end

--- Aggregate review state of a node: accepted | bad | pending | partial
function M.state_of(node, marks)
  local all = M.collect(node)
  local a, b = 0, 0
  for _, c in ipairs(all) do
    local s = marks[c.id]
    if s == "accepted" then a = a + 1 elseif s == "bad" then b = b + 1 end
  end
  if #all > 0 and a == #all then return "accepted" end
  if #all > 0 and b == #all then return "bad" end
  if a + b == 0 then return "pending" end
  return "partial"
end

--- Call fn(node) for every node of the model (files, scopes, changes).
function M.walk(model, fn)
  local function rec(n)
    fn(n)
    for _, k in ipairs(n.children) do rec(k) end
  end
  for _, f in ipairs(model.files) do rec(f) end
end

--- Rows to display given marks, the visibility filter and the set of folded node keys.
---@return table[] rows  { node, pstack, is_last, show_own, has_kids, folded }
function M.flatten(model, marks, filter, folded)
  folded = folded or {}
  local function change_visible(c)
    local s = marks[c.id]
    if s == "accepted" then return filter.show_accepted end
    if s == "bad" then return filter.show_bad end
    return true
  end
  local memo = {}
  local function visible(n)
    if memo[n] ~= nil then return memo[n] end
    local v = (n.change and change_visible(n.change)) or false
    for _, k in ipairs(n.children) do
      if visible(k) then v = true end
    end
    memo[n] = v
    return v
  end

  local rows = {}
  local function emit(n, pstack, is_last)
    local kids = {}
    for _, k in ipairs(n.children) do
      if visible(k) then kids[#kids + 1] = k end
    end
    local is_folded = #kids > 0 and folded[n.key] == true
    rows[#rows + 1] = {
      node = n,
      pstack = pstack,
      is_last = is_last,
      show_own = n.change ~= nil and change_visible(n.change),
      has_kids = #kids > 0,
      folded = is_folded,
    }
    if is_folded then return end
    local child_stack = vim.deepcopy(pstack)
    if n.kind ~= "file" then child_stack[#child_stack + 1] = is_last end
    for i, k in ipairs(kids) do emit(k, child_stack, i == #kids) end
  end
  for _, f in ipairs(model.files) do
    if visible(f) then emit(f, {}, true) end
  end
  return rows
end

function M.stats(model, marks)
  local s = { total = #model.changes, accepted = 0, bad = 0, pending = 0, by_status = {} }
  for _, c in ipairs(model.changes) do
    local m = marks[c.id]
    if m == "accepted" then s.accepted = s.accepted + 1
    elseif m == "bad" then s.bad = s.bad + 1
    else s.pending = s.pending + 1 end
    s.by_status[c.status] = (s.by_status[c.status] or 0) + 1
  end
  return s
end

return M
