# gitcppdiff.nvim

**Semantic `git diff` for C++, inside Neovim.** See which classes, methods, enums, fields and aliases changed
between two revisions — added, removed, modified, **API change**, or renamed/moved — review them in a floating
window with a live code preview, jump to the spot, and mark each change **accepted** or **bad**.

This repo contains both parts:

* `gitcppdiff` — a fast C++20 command line tool (tree-sitter based, no build flags / `compile_commands.json`
  needed, works on any commit). Usable on its own and in CI (`--format json`, `--fail-on-api`).
* the Neovim ≥ 0.12 plugin that drives it (`:CppDiff`).

```
╭ gitcppdiff main...HEAD ───────────────────────┬ src/widget.h:9 ────────────────────────────────╮
│  2   1   14 pending          A accepted:shown │ API change  ui::Widget::resize  parameters: …  │
│   src/widget.h 2 1 1 3 1                      │  7 public:                                     │
│  └─  ui 2 1 1 3 1                             │  8   Widget();                                 │
│     ├─   Color  enum  (API)  :4               │  9   void resize(int w, int h, bool animate…   │
│     ├─   Widget  class  (API)  :6             │ 10   int width() const;                        │
│     │  ├─   resize(int w, int h, bool …) (API)│ 11   void update();                            │
│     │  ├─   paintLegacy()  (RENAMED)  :12     │ 12   void paintLegacy();                       │
│     │  └─   ratio() const  api  :13           │ 13   double ratio() const;                     │
╰ a accept · b bad · A/B/S filter · ⏎ jump · ? help ┴────────────────────────────────────────────╯
```

**Highlights:** accept / bad review marks · fold files and classes · word-level diff preview ·
*N callers affected* from clangd · `:CppDiffNext` / `:CppDiffPrev` from any buffer · per-project `.gitcppdiff`.

## Install

Needs: Neovim ≥ 0.12, git, and — to build the executable once — `make`, `cmake`, a C++20 compiler and network
access (CMake fetches tree-sitter + the C++ grammar). Linux and macOS.

**lazy.nvim**
```lua
{ "a-k-2/gitcppdiff.nvim", build = "make", cmd = "CppDiff", opts = {} }
```

**vim.pack (built in, Neovim 0.12)**
```lua
-- must be defined before vim.pack.add so the first install triggers it
vim.api.nvim_create_autocmd("PackChanged", {
  callback = function(ev)
    local d = ev.data
    if d.spec.name == "gitcppdiff.nvim" and (d.kind == "install" or d.kind == "update") then
      if not d.active then vim.cmd.packadd("gitcppdiff.nvim") end
      require("gitcppdiff").build()   -- async; shows live progress, see "The first build" below
    end
  end,
})
vim.pack.add({ "https://github.com/a-k-2/gitcppdiff.nvim" })
require("gitcppdiff").setup({})   -- optional
```

Or build by hand: `:CppDiffBuild` (runs `make` in the plugin directory) or `make` in a checkout.

### The first build

The first build downloads tree-sitter and the C++ grammar from GitHub and compiles everything, which takes
1–2 minutes (later builds take seconds). Nothing is silent:

* **`make`** (lazy.nvim's `build`, or by hand) prints the phases and the full CMake output: compiler detection
  (`The CXX compiler identification is GNU 13.3.0`, `Detecting CXX compiler ABI info`), the `git clone` of each dependency,
  then the numbered compile steps.
* **`:CppDiffBuild`** (and the `vim.pack` hook above) runs the same build asynchronously and shows it as a Neovim
  progress message with a percentage, e.g. `gitcppdiff build:  20% downloading tree-sitter-cpp from GitHub …`,
  `gitcppdiff build:  66% compiling 14/25`. Before it starts it checks that `make`, `cmake`, `git` and a C++ compiler are
  there and names whatever is missing.
* **`:CppDiffBuildLog`** opens the complete output of the last build. If a build fails, the last lines are shown in the
  error message and the log opens by itself.
`:checkhealth gitcppdiff` tells you what is missing. To use a binary from elsewhere: `setup({ bin = "/path/to/gitcppdiff" })`.

## Usage

```vim
:CppDiff                  " HEAD vs working tree (untracked C++ files count as added)
:CppDiff --staged         " HEAD vs index
:CppDiff main...HEAD      " merge-base(main,HEAD) vs HEAD  — the PR view
:CppDiff v1.2 v1.3 -- include/    " two tags, only under include/
:CppDiff --api-only       " only the public API surface
```
Flags after `:CppDiff` go straight to the executable (see `gitcppdiff --help`). Tab-completion offers flags and refs.

### Keys in the window

| key | action |
|-----|--------|
| `j` / `k` | move; the preview follows |
| `a` | **accept** change (again = clear). Visual mode: whole range |
| `b` | mark change as **bad** (again = clear). Visual mode: whole range |
| `u` | clear mark |
| `A` | toggle visibility of **accepted** changes |
| `B` | toggle visibility of **bad** changes |
| `S` | **show all** |
| `<CR>` | jump to the location (declaration; for removed symbols the old revision, read-only) |
| `gd` | jump to the definition in the `.cpp` |
| `<Tab>` | preview: source ⇄ diff (old → new, with **word-level** highlighting) |
| `gr` | callers / references of the change → quickfix (computes it first if needed) |
| `za` `zc` `zo` | fold: toggle / close / open the file or class under the cursor (`zc` on a leaf closes its parent) |
| `zM` `zR` | close / open **all** folds |
| `h` / `l` | collapse (or go to parent) / expand (or go to first child) |
| `e` | expand / collapse the members of added or removed classes |
| `r` | re-run |
| `<C-q>` | visible changes → quickfix list |
| `?` | help · `q` / `<Esc>` close |

On a **class / namespace / file row**, `a` / `b` / `u` apply to *everything below it*. After a single `a`/`b` the
cursor advances to the next row. API changes and renames carry a rounded pill badge (flat `[API]` / `[RENAMED]` with `icons = false`). Pending changes are always visible; with `A` and `B` both off you see exactly what is
left to review. The top bar shows progress (`accepted · bad · pending`) and the filter state.

Marks are stored per repository in `stdpath("state")/gitcppdiff/` and keyed by a hash of the change itself
(symbol + old/new signature + old/new body). As soon as the reviewed code changes again the mark disappears on its
own; unchanged changes keep their mark across runs, ranges and branches. `:CppDiffClearMarks` forgets them all.

### Folding

Files, namespaces and classes fold. A folded row shows the aggregated counts of what is below it, and `a` / `b` on a
folded row still apply to everything inside. Fold state survives re-renders (marking, filtering, `r`). Start folded with
`fold = "files" | "classes" | "all"`.

### Callers affected

For every **API change** the plugin asks your language server (`textDocument/references`) who uses the symbol and shows it
in the row: `2 callers` (functions) or `9 uses` (types, fields). The symbol's own declaration and definition are
excluded. For **removed** symbols nothing is left to ask about, so it counts the textual references that remain
(`git grep -w`), shown as `~1 refs`. `gr` sends the call sites to the quickfix list; the preview bar shows
`2 callers in 1 file`.

* Needs a C++ LSP with the client name from `callers.client` (default `clangd`). If none is running, the plugin loads
  a C++ buffer so an `vim.lsp.enable("clangd")` / lspconfig autostart kicks in, then **waits until clangd has finished
  background indexing** before asking (a count of 0 from a half-built index would be a dangerous lie; zero results are
  retried while indexing is still running).
* Project-wide references need a `compile_commands.json`, as always with clangd.
* Computed in the background (progress in the top bar), at most `callers.max` rows automatically; `callers.auto = false`
  computes only on demand with `gr`. Results are cached until `r`. Only worktree files are queried, so for a
  `rev..rev` range that is not checked out the counts are skipped.

### `:CppDiffNext` / `:CppDiffPrev`

Step through the changes of the last run from any buffer (counts work: `:3CppDiffNext`). It goes to the next change
after the cursor in (file, line) order — also from the read-only old-revision buffers — wraps around, and honours
the same filter: accepted / bad changes are skipped while hidden (`A` / `B`). With the window open it moves in the list
instead. If nothing was run yet it runs `gitcppdiff` first. No keys are bound; pick your own:

```lua
vim.keymap.set("n", "]d", "<cmd>CppDiffNext<cr>", { desc = "next C++ change" })
vim.keymap.set("n", "[d", "<cmd>CppDiffPrev<cr>", { desc = "previous C++ change" })
```

### Options

```lua
require("gitcppdiff").setup({
  bin = nil,                 -- path to the executable (nil: <plugin>/bin, <plugin>/build, $PATH)
  extra_args = {},           -- always passed to the executable, e.g. { "--macro", "MYLIB_EXPORT" }
  icons = true,              -- Nerd Font glyphs; false = ASCII
  border = "rounded",        -- "rounded" | "single" | "double" (merged borders) or any 'winborder' style
  width = 0.92, height = 0.85, list_width = 0.52,
  show_accepted = true,      -- initial filter state
  show_bad = true,
  preview = "source",        -- or "diff"
  expand = false,
  fold = "none",             -- initial folding: none | files | classes | all
  callers = { enabled = true, auto = true, max = 300, client = "clangd", grep_removed = true, index_timeout = 45 },
  advance = true,            -- move to next row after a / b
  persist = true,
  keys = { accept = "a", bad = "b", clear = "u", show_all = "S", toggle_accepted = "A", toggle_bad = "B",
           jump = "<CR>", jump_definition = "gd", preview_mode = "<Tab>", refresh = "r", expand = "e",
           quickfix = "<C-q>", callers = "gr", help = "?", close = { "q", "<Esc>" },
           fold_toggle = "za", fold_close = "zc", fold_open = "zo", fold_close_all = "zM", fold_open_all = "zR",
           fold_left = "h", fold_right = "l" },   -- false disables a key
})
```
Highlight groups (all `default` links, override freely): `GitCppDiffAdded`, `…Removed`, `…Modified`, `…Api`,
`…Renamed`, `…Accepted`, `…Bad`, `…Dim`, `…Title`, `…Range`, `…Kind{Type,Func,Field,Enum,Op}`, and for the diff
preview `…AddLine`, `…DelLine`, `…AddWord`, `…DelWord`, `…Hunk` (word highlights default to a solid block in the colour of `Added` / `Removed`).
Lua API: `require("gitcppdiff").open({ "main...HEAD" })`, `.close()`, `.refresh()`, `.next(n)`, `.prev(n)`, `.build()`.

## The `gitcppdiff` executable

```
gitcppdiff                       # HEAD vs working tree, colourful tree on the terminal
gitcppdiff main...HEAD --api-only
gitcppdiff --format json         # machine-readable
gitcppdiff --fail-on-api         # exit 2 on API change / API removal (CI gate)
```
`--color=never|always`, `--no-icons`, `--only added,removed,modified,api,renamed`, `--all-api`, `--expand`,
`--macro NAME`, `--config FILE`, `--no-config`, `-C dir`, `--staged`, `A..B`, `A...B`, `-- <paths>`, `--dump-ast <file>`.

### `.gitcppdiff` (per project)

A plain file in the repository root, read automatically (`--config FILE` / `--no-config` override). `#` starts a comment.

```
macro MYLIB_EXPORT MYLIB_DEPRECATED   # blank these identifiers before parsing (export / attribute macros)
ignore third_party/ **/*_generated.*  # skip files completely; gitignore-like globs (* ? ** , trailing / = directory)
public include/** api/**              # only headers matching these count as public API
internal-namespace detail internal    # contents of these namespaces are never public API
all-api false                         # true: treat every symbol as API
```

`public` is the one to set for libraries that keep private headers next to the sources: without it every header counts.
Unknown directives produce a warning on stderr. The plugin gets all of this for free because it calls the executable.

### Classification

| status        | rule |
|---------------|------|
| added/removed | identity key only on one side. Key = qualified name + parameter types + cv/ref qualifiers (overloads are distinct) |
| modified      | same key, token hash of body / initializer differs (comments and whitespace ignored) |
| api-change    | *public* symbol whose return type, parameters, default args, qualifiers (`const`, `noexcept`, `override` …), specifiers (`virtual`, `static` …), template header (parameter names ignored), base classes, access, enumerators or member type changed |
| renamed       | removed+added pair with an identical non-trivial body; also catches moves between classes |

A header declaration and its `.cpp` definition are merged into one symbol. When **only the `.cpp` changed**, the
companion header (same stem next to it, or the `#include "…"` with the same stem / the first quoted include) is parsed too —
unchanged, just for the declarations — so out-of-class definitions get their real access (a private method's body change
is not flagged as public API). Type spelling is normalised: `const Z&` and `Z const&` are the same (also inside template
arguments and for `char const*`), `char* const` is not `char*`. "Public API" = public/protected members and
free functions declared in headers; private members and `static` / anonymous-namespace / source-only functions get plain
*modified* (reason marked `(internal)`) unless `--all-api`. A removed+added pair with the same name (overload set changed)
is reported as an API change.

### Known limits (syntactic analysis)

* Macros: an ALL_CAPS token before `template` / `class` / `struct` / … is blanked automatically; others via
  `--macro NAME`, `extra_args`, or `GITCPPDIFF_MACROS=A,B`. Namespace-opening macros (`FMT_BEGIN_NAMESPACE`) are not understood.
* `Foo::bar` defined via `using namespace` is not resolved to `ns::Foo::bar`.
* Overload identity compares token spelling after cv-normalisation (`Foo` vs `ns::Foo` for the same type are different).
* Git limits rename detection when you pass a pathspec.

### JSON (schema 2)

```json
{ "schema": 2, "range": "main...HEAD", "root": "/abs/repo", "base_rev": "…", "head_rev": "…",
  "head_kind": "rev|index|worktree", "files_scanned": 7,
  "summary": {"added":0,"removed":0,"modified":0,"api-change":0,"renamed":0},
  "changes": [ { "id": "f809d3ab813fed30", "status": "api-change", "kind": "method",
      "qualified_name": "ui::Widget::resize", "name": "resize", "label": "resize(int w, int h, bool animate = true)",
      "scope": ["ui","Widget"], "access": "public", "api": true, "file": "src/widget.h", "line": 15,
      "reasons": ["parameters: int, int → int, int, bool", "default args: ∅ → 2=true"],
      "old": {"file":"…","line":0,"end_line":0,"signature":"…","definition":{"file":"…","line":0,"end_line":0}},
      "new": null } ] }
```
`old` / `new` are `null` for added / removed; `definition` appears when the body lives in another file than the declaration.
`id` is stable for identical changes.

## Development

```
make            # build → bin/gitcppdiff
make test       # CLI regression test + headless Neovim end-to-end test (NVIM=/path/to/nvim)
                # the callers tests run against a real clangd when it is installed
```
