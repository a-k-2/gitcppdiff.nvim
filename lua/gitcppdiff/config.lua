local M = {}

---@class gitcppdiff.Config
M.defaults = {
  -- Path to the gitcppdiff executable. nil = auto (<plugin>/bin, <plugin>/build, then $PATH).
  bin = nil,
  -- Extra arguments passed to gitcppdiff on every run, e.g. { "--macro", "MYLIB_EXPORT" }.
  extra_args = {},
  -- Nerd Font glyphs. false = ASCII.
  icons = true,
  -- "rounded" | "single" | "double" get merged borders; any other style gives two boxes.
  border = "rounded",
  -- Window size as a fraction of the editor, and the share of the width used by the list.
  width = 0.92,
  height = 0.85,
  list_width = 0.52,
  -- Initial visibility of reviewed changes (toggle inside the window with A / B / S).
  show_accepted = true,
  show_bad = true,
  -- Initial preview: "source" (code at the location) or "diff" (old vs new). <Tab> toggles.
  preview = "source",
  -- List every member of added/removed classes instead of collapsing them.
  expand = false,
  -- Initial folding of the list: "none" | "files" | "classes" | "all".
  fold = "none",
  -- Caller counts for API changes (LSP references) and removed symbols (remaining textual refs).
  callers = {
    enabled = true,
    auto = true,          -- compute for all API changes in the background (false: only on demand with `gr`)
    max = 300,            -- limit for the automatic run
    client = "clangd",    -- name of the LSP client to ask
    grep_removed = true,  -- count remaining textual references of removed symbols with `git grep`
    index_timeout = 45,   -- seconds to wait for the language server to finish (background) indexing
  },
  -- After accepting / rejecting a single line, move to the next line.
  advance = true,
  -- Remember accepted / bad marks per repository (stdpath("state")).
  persist = true,
  -- Set any entry to false to disable it. `close` takes a list.
  keys = {
    accept = "a",
    bad = "b",
    clear = "u",
    show_all = "S",
    toggle_accepted = "A",
    toggle_bad = "B",
    jump = "<CR>",
    jump_definition = "gd",
    preview_mode = "<Tab>",
    refresh = "r",
    expand = "e",
    quickfix = "<C-q>",
    callers = "gr",
    fold_toggle = "za",
    fold_close = "zc",
    fold_open = "zo",
    fold_close_all = "zM",
    fold_open_all = "zR",
    fold_left = "h",
    fold_right = "l",
    help = "?",
    close = { "q", "<Esc>" },
  },
}

M.options = vim.deepcopy(M.defaults)

function M.setup(opts)
  M.options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

return M
