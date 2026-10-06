-- "N callers affected": for API changes ask the language server (clangd) for references;
-- for removed symbols (nothing left to ask about) count the textual references that remain.
local api = vim.api
local cfgm = require("gitcppdiff.config")
local jump = require("gitcppdiff.jump")

local M = {}
local cache = {}   -- [root|id] = result

local FUNC = { ["function"] = true, method = true, constructor = true, destructor = true, operator = true }

function M.clear_cache() cache = {} end

local function opts() return cfgm.options.callers end

local function get_client()
  return vim.lsp.get_clients({ name = opts().client })[1]
end

--- Short text for a row: text, highlight
function M.tag(c)
  local k = c._callers
  if not k then return nil end
  local grep = k.source == "grep"
  local word = grep and "refs" or (FUNC[c.kind] and "callers" or "uses")
  if k.count == 0 then return "no " .. word, "GitCppDiffAccepted" end
  return (grep and "~" or "") .. k.count .. " " .. word, "GitCppDiffApi"
end

--- Longer text for the preview bar.
function M.summary(c)
  local k = c._callers
  if not k then return nil end
  local word = k.source == "grep" and "textual references" or (FUNC[c.kind] and "callers" or "uses")
  if k.count == 0 then return "no " .. word end
  return string.format("%d %s in %d file%s", k.count, word, k.files, k.files == 1 and "" or "s")
end

-- ───────────── helpers ─────────────

local function name_col(text, name)
  local best
  local init = 1
  while true do
    local s, e = text:find(name, init, true)
    if not s then break end
    local before, after = text:sub(s - 1, s - 1), text:sub(e + 1, e + 1)
    local ok_b = s == 1 or not before:match("[%w_]")
    local ok_a = after == "" or not after:match("[%w_]")
    if ok_b and ok_a then
      if after == "(" then return s - 1 end -- the declarator, not a use of the same word in a type
      best = best or (s - 1)
    end
    init = e + 1
  end
  if not best and name:sub(1, 8) == "operator" then
    local s = text:find("operator", 1, true)
    if s then return s - 1 end
  end
  return best
end

local function ensure_client(path, bufs, cancelled, cb)
  local c = get_client()
  if c then return cb(c, false) end
  -- loading a C++ buffer lets a vim.lsp.enable()d / lspconfig'd clangd auto-start
  local buf = vim.fn.bufadd(path)
  if vim.fn.bufloaded(buf) == 0 then
    vim.fn.bufload(buf)
    vim.bo[buf].buflisted = false
    bufs[#bufs + 1] = buf
  end
  vim.bo[buf].filetype = "cpp"
  local tries, timer = 0, vim.uv.new_timer()
  timer:start(200, 200, vim.schedule_wrap(function()
    tries = tries + 1
    local cl = get_client()
    if cancelled() then
      timer:stop()
      timer:close()
      return
    end
    if cl or tries > 40 then
      timer:stop()
      timer:close()
      cb(cl, true)
    end
  end))
end

local function own_ranges(c)
  local r = {}
  local function add(p) if p then r[#r + 1] = { p.file, p.line, p.end_line or p.line } end end
  add(c.new)
  add(c.new and c.new.definition)
  return r
end

--- Wait until the client reports no running progress (background indexing), so references are complete.
local function wait_idle(client, cancelled, cb, min_total)
  local started, idle_since = vim.uv.hrtime(), nil
  local timer = vim.uv.new_timer()
  timer:start(100, 150, vim.schedule_wrap(function()
    if cancelled() then
      timer:stop()
      timer:close()
      return
    end
    local now = vim.uv.hrtime()
    local busy = vim.lsp.status():find(client.name, 1, true) ~= nil
    if busy then idle_since = nil elseif not idle_since then idle_since = now end
    local settled = idle_since and (now - idle_since) / 1e9 >= 0.8 and (now - started) / 1e9 >= (min_total or 0)
    if settled or (now - started) / 1e9 > opts().index_timeout then
      timer:stop()
      timer:close()
      cb()
    end
  end))
end

-- ───────────── LSP references ─────────────

local function lsp_references(sess, client, c, done)
  local t = c.new
  if not t or not jump.worktree_matches(sess.data, t.file) then return done(nil) end
  local root = sess.data.root
  local path = root .. "/" .. t.file
  local buf = vim.fn.bufadd(path)
  if vim.fn.bufloaded(buf) == 0 then
    vim.fn.bufload(buf)
    vim.bo[buf].buflisted = false
    vim.bo[buf].filetype = "cpp"
    sess.callers.bufs[#sess.callers.bufs + 1] = buf
  end
  if not vim.lsp.buf_is_attached(buf, client.id) then vim.lsp.buf_attach_client(buf, client.id) end
  local line = api.nvim_buf_get_lines(buf, t.line - 1, t.line, false)[1] or ""
  local col = name_col(line, c.name)
  if not col then return done(nil) end
  local ch = col
  if line:sub(1, col):find("[\128-\255]") then
    pcall(function() ch = vim.str_utfindex(line, client.offset_encoding or "utf-16", col, false) end)
  end

  local finished = false
  local function finish(res)
    if finished then return end
    finished = true
    done(res)
  end
  local params = {
    textDocument = { uri = vim.uri_from_bufnr(buf) },
    position = { line = t.line - 1, character = ch },
    context = { includeDeclaration = false },
  }
  local ok, id = client:request("textDocument/references", params, function(err, result)
    if err or type(result) ~= "table" then return finish(nil) end
    local own, locs, files, kept = own_ranges(c), {}, {}, 0
    for _, loc in ipairs(result) do
      local uri = loc.uri or loc.targetUri
      local r = loc.range or loc.targetRange
      if uri and r then
        local fname = vim.uri_to_fname(uri)
        local rel = vim.fs.relpath(root, fname) or fname
        local lnum = r.start.line + 1
        local skip = false
        for _, o in ipairs(own) do
          if o[1] == rel and lnum >= o[2] and lnum <= o[3] then skip = true break end
        end
        if not skip then
          files[rel] = true
          kept = kept + 1
          if #locs < 500 then locs[#locs + 1] = { filename = fname, lnum = lnum, col = r.start.character + 1 } end
        end
      end
    end
    finish({ count = kept, files = vim.tbl_count(files), locs = locs, source = "clangd" })
  end, buf)
  if not ok then return finish(nil) end
  vim.defer_fn(function()
    if not finished and id then pcall(function() client:cancel_request(id) end) end
    finish(nil)
  end, 20000)
end

-- ───────────── textual references (removed symbols) ─────────────

local EXTS = { "*.h", "*.hh", "*.hpp", "*.hxx", "*.cpp", "*.cc", "*.cxx", "*.inl", "*.ipp", "*.tpp" }

local function grep_references(sess, c, done)
  local d = sess.data
  local args = { "git", "-C", d.root, "grep", "-n", "-I", "-F" }
  if c.name:match("^[%a_][%w_]*$") then args[#args + 1] = "-w" end
  if d.head_kind == "index" then args[#args + 1] = "--cached" end
  vim.list_extend(args, { "-e", c.name })
  if d.head_kind == "rev" then args[#args + 1] = d.head_rev end
  args[#args + 1] = "--"
  vim.list_extend(args, EXTS)
  vim.system(args, { text = true }, vim.schedule_wrap(function(r)
    if r.code > 1 then return done(nil) end
    local locs, files, total = {}, {}, 0
    local prefix = d.head_kind == "rev" and (d.head_rev .. ":") or ""
    for l in vim.gsplit(r.stdout or "", "\n", { plain = true, trimempty = true }) do
      if prefix ~= "" and l:sub(1, #prefix) == prefix then l = l:sub(#prefix + 1) end
      local f, n, text = l:match("^(.-):(%d+):(.*)$")
      if f then
        total = total + 1
        files[f] = true
        if #locs < 500 then locs[#locs + 1] = { filename = d.root .. "/" .. f, lnum = tonumber(n), col = 1, text = text } end
      end
    end
    done({ count = total, files = vim.tbl_count(files), locs = locs, source = "grep" })
  end))
end

-- ───────────── orchestration ─────────────

local function finish_one(sess, c, res, on_update)
  local cs = sess.callers
  if cs.stopped then return end
  c._callers = res
  if res then cache[sess.data.root .. "|" .. c.id] = res end
  cs.done = cs.done + 1
  on_update(c)
end

--- Compute (or fetch from cache) the reference info for one change.
function M.request(sess, c, on_update, client_cb)
  local key = sess.data.root .. "|" .. c.id
  if cache[key] then
    c._callers = cache[key]
    sess.callers.done = sess.callers.done + 1
    return on_update(c)
  end
  if c.status == "removed" then
    return grep_references(sess, c, function(res) finish_one(sess, c, res, on_update) end)
  end
  client_cb(function(client)
    if sess.callers.stopped then return end
    if not client then return finish_one(sess, c, nil, on_update) end
    local attempt = 0
    local function cancelled() return sess.callers.stopped end
    local function try()
      lsp_references(sess, client, c, function(res)
        local busy = vim.lsp.status():find(client.name, 1, true) ~= nil
        -- 0 references while the index is still being built (or has not started) is not trustworthy
        if res and res.count == 0 and attempt < 3 and (busy or (sess.callers.fresh and attempt == 0)) then
          attempt = attempt + 1
          return wait_idle(client, cancelled, try, 1.0)
        end
        finish_one(sess, c, res, on_update)
      end)
    end
    try()
  end)
end

local function make_client_cb(sess)
  local resolved, waiting, client = false, {}, nil
  local warned = false
  return function(cb)
    if resolved then return cb(client) end
    waiting[#waiting + 1] = cb
    if #waiting > 1 then return end
    local first
    for _, c in ipairs(sess.data.changes) do
      if c.new then first = c.new.file break end
    end
    local function resolve(cl)
      resolved, client = true, cl
      sess.callers.waiting = false
      if sess.callers.on_update then sess.callers.on_update() end
      for _, w in ipairs(waiting) do w(cl) end
      waiting = {}
    end
    sess.callers.waiting = true
    local function cancelled() return sess.callers.stopped end
    ensure_client(sess.data.root .. "/" .. (first or ""), sess.callers.bufs, cancelled, function(cl, fresh)
      sess.callers.fresh = fresh
      if not cl then
        if not warned then
          warned = true
          vim.notify("gitcppdiff: caller counts need a running `" .. opts().client ..
            "` (open a C++ file with LSP enabled)", vim.log.levels.INFO)
        end
        return resolve(nil)
      end
      -- a client we just started has not begun indexing yet: give it time to start
      wait_idle(cl, cancelled, function() resolve(cl) end, fresh and 2.0 or 0)
    end)
  end
end

--- Start computing for all API changes / removals of a session (async, limited concurrency).
function M.start(sess, on_update)
  local o = opts()
  sess.callers = { total = 0, done = 0, bufs = {}, stopped = false, on_update = on_update }
  sess.callers_client = make_client_cb(sess)
  if not o.enabled or not o.auto then return end
  local targets = {}
  for _, c in ipairs(sess.data.changes) do
    if c.api and not c._collapsed_by and (c.status == "api-change" or (c.status == "removed" and o.grep_removed)) then
      targets[#targets + 1] = c
      if #targets >= o.max then break end
    end
  end
  sess.callers.total = #targets
  local i, running = 0, 0
  local function pump()
    while running < 6 and i < #targets and not sess.callers.stopped do
      i = i + 1
      running = running + 1
      local c = targets[i]
      M.request(sess, c, function(ch)
        running = running - 1
        on_update(ch)
        vim.schedule(pump)
      end, sess.callers_client)
    end
  end
  pump()
end

function M.stop(sess)
  local cs = sess and sess.callers
  if not cs then return end
  cs.stopped = true
  vim.schedule(function()
    for _, b in ipairs(cs.bufs) do
      if api.nvim_buf_is_valid(b) and not vim.bo[b].modified and #vim.fn.win_findbuf(b) == 0 then
        pcall(api.nvim_buf_delete, b, {})
      end
    end
  end)
end

--- quickfix items for a change (reads the referenced lines lazily)
function M.items(c)
  local k = c._callers
  if not k then return {} end
  local lines_cache, items = {}, {}
  for _, l in ipairs(k.locs) do
    local text = l.text
    if not text then
      lines_cache[l.filename] = lines_cache[l.filename] or (vim.fn.filereadable(l.filename) == 1 and vim.fn.readfile(l.filename) or {})
      text = vim.trim(lines_cache[l.filename][l.lnum] or "")
    end
    items[#items + 1] = { filename = l.filename, lnum = l.lnum, col = l.col, text = text }
  end
  return items
end

return M
