#!/usr/bin/env bash
# Regression test: builds a tiny repo with a known before/after and checks classifications.
set -euo pipefail
BIN="${1:-$(dirname "$0")/../build/gitcppdiff}"
BIN="$(cd "$(dirname "$BIN")" && pwd)/$(basename "$BIN")"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
cd "$T"; git init -q -b main; git config user.email t@t; git config user.name t

cat > w.h <<'EOF'
namespace ui {
enum class Color { Red, Green };
class Widget : public Base {
public:
  void resize(int w, int h);
  int width() const;
  void update();
  void legacyPaint();
  void gone();
private:
  void priv();
};
}
EOF
cat > w.cpp <<'EOF'
#include "w.h"
namespace ui {
void Widget::resize(int w, int h) { w_ = w; h_ = h; }
int Widget::width() const { return w_; }
void Widget::update() { dirty_ = false; }
void Widget::legacyPaint() { paintOld(1, 2, 3, 4); }
void Widget::priv() { a(); }
}
EOF
git add -A; git commit -qm base

cat > w.h <<'EOF'
namespace ui {
enum class Color { Red, Green, Blue };
class Widget : public Base, public Extra {
public:
  void resize(int w, int h, bool animate = true);
  int width() const;
  void update();
  void paintLegacy();
  double ratio() const;
private:
  void priv(int x);
};
}
EOF
cat > w.cpp <<'EOF'
#include "w.h"
namespace ui {
// comment-only change must be ignored
void Widget::resize(int w, int h, bool animate) { w_ = w; h_ = h; if (animate) go(); }
int Widget::width() const { return w_; }
void Widget::update() { dirty_ = true; }
void Widget::paintLegacy() { paintOld(1, 2, 3, 4); }
double Widget::ratio() const { return 1.0; }
void Widget::priv(int x) { a(x); }
}
EOF

"$BIN" --format json > "$T/out.json"
cat > "$T/chk.py" <<'PY'
import sys, json
d = json.load(open(sys.argv[1]))
want_q, want_status, want_api = sys.argv[2], sys.argv[3], sys.argv[4] == "true"
for c in d["changes"]:
    if c["qualified_name"] == want_q:
        ok = c["status"] == want_status and c["api"] == want_api
        print(("ok   " if ok else "FAIL ") + want_q, c["status"], c["api"])
        sys.exit(0 if ok else 1)
print("FAIL missing", want_q); sys.exit(1)
PY
chk() { python3 "$T/chk.py" "$T/out.json" "$@"; }
fail=0
chk ui::Color                 api-change true  || fail=1
chk ui::Widget                api-change true  || fail=1
chk ui::Widget::resize        api-change true  || fail=1
chk ui::Widget::update        modified   true  || fail=1
chk ui::Widget::paintLegacy   renamed    true  || fail=1
chk ui::Widget::ratio         added      true  || fail=1
chk ui::Widget::gone          removed    true  || fail=1
chk ui::Widget::priv          modified   false || fail=1   # private: signature change is not public API
n=$(python3 -c "import json;print(len(json.load(open('$T/out.json'))['changes']))")
[ "$n" = 8 ] && echo "ok   exactly 8 changes (comment-only edit ignored)" || { echo "FAIL expected 8 changes, got $n"; fail=1; }
"$BIN" --fail-on-api >/dev/null && { echo "FAIL --fail-on-api should exit 2"; fail=1; } || [ $? -eq 2 ] || fail=1

# ── glyph spacing in the CLI: wide Nerd Font glyphs must be followed by a space ──
"$BIN" --color=never > "$T/pretty.txt"
python3 - "$T/pretty.txt" <<'PY' || fail=1
import sys
text = open(sys.argv[1], encoding="utf-8").read()
glyphs = {0xf067: "plus", 0xf068: "minus", 0xf071: "warning", 0xf040: "pencil", 0xf0ec: "exchange", 0xf00c: "check", 0xe0b4: "pill end cap"}
bad = []
for i, ch in enumerate(text):
    if ord(ch) in glyphs and i + 1 < len(text) and text[i + 1] not in " \n":
        bad.append("%s followed by %r near %r" % (glyphs[ord(ch)], text[i + 1], text[max(0, i - 8):i + 10]))
has_counts = any(chr(g) + " " + d in text for g in (0xf067, 0xf071) for d in "123456789")
print(("ok   " if not bad else "FAIL ") + "CLI: every glyph is followed by a space" + ("" if not bad else " -> " + "; ".join(bad[:3])))
print(("ok   " if has_counts else "FAIL ") + "CLI: counts read '+ 2' (glyph, space, number)")
sys.exit(0 if not bad and has_counts else 1)
PY

# ───────────────── helpers for the scenarios below ─────────────────
q() {  # q <name> <python expr over d (json) and c(qualified_name) -> change>
  python3 - "$1" "$2" "$J" <<'PY' || fail=1
import sys, json
name, expr, path = sys.argv[1:4]
d = json.load(open(path))
def c(q):
    for x in d["changes"]:
        if x["qualified_name"] == q: return x
    return None
ok = bool(eval(expr))
print(("ok   " if ok else "FAIL ") + name)
sys.exit(0 if ok else 1)
PY
}
newrepo() { R="$(mktemp -d)"; cd "$R"; git init -q -b main; git config user.email t@t; git config user.name t; }
run_json() { "$BIN" --format json "$@" > "$J"; }
J="$T/scn.json"

# ── A. only the .cpp changes: access comes from the (unchanged) companion header ──
newrepo
mkdir src
cat > src/w.h <<'EOF'
class Widget {
public:
  void pub();
private:
  void priv();
};
EOF
cat > src/w.cpp <<'EOF'
#include "w.h"
void Widget::pub() { a(); b(); c(); }
void Widget::priv() { a(); b(); c(); }
EOF
git add -A; git commit -qm base
sed -i 's/a(); b(); c();/a(); b(); c(); d();/' src/w.cpp
run_json
q "A: public method body change is API-visible"  'c("Widget::pub")["status"]=="modified" and c("Widget::pub")["api"] is True'
q "A: private method body change is NOT API"      'c("Widget::priv")["status"]=="modified" and c("Widget::priv")["api"] is False'
q "A: access resolved from companion header"     'c("Widget::priv")["access"]=="private" and c("Widget::pub")["access"]=="public"'
q "A: only the .cpp was scanned as changed"      'd["files_scanned"]==1'

# ── B. east const vs west const is not a change; real constness change is ──
newrepo
cat > a.hpp <<'EOF'
struct Z {};
void f(const Z& a, const char* s, char* const p);
std::vector<const Z&> g(std::vector<Z const*> v);
EOF
git add -A; git commit -qm base
cat > a.hpp <<'EOF'
struct Z {};
void f(Z const& a, char const* s, char* const p);
std::vector<Z const&> g(std::vector<const Z*> v);
EOF
run_json
q "B: const placement only -> no changes" 'len(d["changes"])==0'
cat > a.hpp <<'EOF'
struct Z {};
void f(const Z& a, const char* s, char* p);
std::vector<const Z&> g(std::vector<Z const*> v);
EOF
run_json
q "B: pointer constness change is reported" 'c("f")["status"]=="api-change"'

# ── C. .gitcppdiff ──
newrepo
mkdir -p gen include src
cat > gen/auto.hpp <<'EOF'
void generated(int a);
EOF
cat > include/pub.h <<'EOF'
class Pub { public: void m(int a); };
EOF
cat > src/priv.h <<'EOF'
class Priv { public: void m(int a); };
EOF
cat > src/det.h <<'EOF'
namespace detail { void helper(int a); }
namespace shown { void visible(int a); }
EOF
cat > src/mac.h <<'EOF'
MYEXPORT void exported(int x);
EOF
git add -A; git commit -qm base
cat > gen/auto.hpp <<'EOF'
void generated(int a, int b);
EOF
cat > include/pub.h <<'EOF'
class Pub { public: void m(int a, int b); };
EOF
cat > src/priv.h <<'EOF'
class Priv { public: void m(int a, int b); };
EOF
cat > src/det.h <<'EOF'
namespace detail { void helper(int a, int b); }
namespace shown { void visible(int a, int b); }
EOF
cat > src/mac.h <<'EOF'
MYEXPORT void exported(int x, int y);
EOF
run_json
q "C0: without config everything is API / visible" 'c("generated")["api"] and c("Priv::m")["api"] and c("detail::helper")["api"]'
q "C0: unknown macro leaks into the signature"      '"MYEXPORT" in c("exported")["new"]["signature"]'
cat > .gitcppdiff <<'EOF'
# project settings
ignore gen/                      # generated code
public include/**                # only these headers are public
internal-namespace detail
macro MYEXPORT
EOF
run_json
q "C1: ignore removes generated files"        'c("generated") is None'
q "C2: public globs: include/ stays API"      'c("Pub::m")["api"] is True and c("Pub::m")["status"]=="api-change"'
q "C2: public globs: src/ header is not API"  'c("Priv::m")["api"] is False and c("Priv::m")["status"]=="modified"'
q "C3: internal-namespace is not API"         'c("detail::helper")["api"] is False'
q "C3: other namespaces unaffected (public glob applies)" 'c("shown::visible")["api"] is False'
q "C4: macro directive cleans the signature"  'c("exported")["new"]["signature"]=="void exported(int x, int y)"'
"$BIN" --no-config --format json > "$J"
q "C5: --no-config ignores the file"          'c("generated") is not None'
printf 'bogus thing\nall-api maybe\n' > .gitcppdiff
"$BIN" --format json 2>"$T/warn.txt" > "$J"
grep -q "unknown directive 'bogus'" "$T/warn.txt" && echo "ok   C6: bad directive warns" || { echo "FAIL C6: no warning"; fail=1; }

[ $fail -eq 0 ] && echo "all good" || { echo "FAILURES"; exit 1; }
