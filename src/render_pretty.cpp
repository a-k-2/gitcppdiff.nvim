// Pretty terminal output: truecolor (Catppuccin Mocha), Nerd Font glyphs,
// powerline-style pills, with an ASCII fallback (--no-icons / --color=never).
#include <climits>
#include <map>
#include <memory>
#include <optional>

#include "parse.hpp"
#include "render.hpp"

namespace cppdiff {
namespace {

using std::string;
using std::vector;

struct RGB { int r, g, b; };
constexpr RGB GREEN{166, 227, 161}, RED{243, 139, 168}, YELLOW{249, 226, 175}, PEACH{250, 179, 135},
    MAUVE{203, 166, 247}, BLUE{137, 180, 250}, TEAL{148, 226, 213}, SAPPHIRE{116, 199, 236},
    PINK{245, 194, 231}, TEXT{205, 214, 244}, SUB{147, 153, 178}, DIM{88, 91, 112}, CRUST{17, 17, 27};

struct Sty {
  std::optional<RGB> fg, bg;
  bool bold = false, dim = false, italic = false, strike = false;
};
Sty fg(RGB c) { Sty s; s.fg = c; return s; }
Sty fgb(RGB c) { Sty s; s.fg = c; s.bold = true; return s; }

struct Line {
  string s;
  int w = 0;
};

int cpwidth(const string& t) {
  int n = 0;
  for (unsigned char c : t) if ((c & 0xC0) != 0x80) ++n;
  return n;
}

class Painter {
 public:
  explicit Painter(const RenderOptions& o) : o_(o) {}
  bool icons() const { return o_.icons; }

  void put(Line& l, const string& t, const Sty& st = {}) const {
    l.w += cpwidth(t);
    bool any = st.fg || st.bg || st.bold || st.dim || st.italic || st.strike;
    if (!o_.color || !any) { l.s += t; return; }
    string e = "\x1b[";
    auto add = [&](const string& x) { if (e.size() > 2) e += ';'; e += x; };
    if (st.bold) add("1");
    if (st.dim) add("2");
    if (st.italic) add("3");
    if (st.strike) add("9");
    if (st.fg) add("38;2;" + std::to_string(st.fg->r) + ";" + std::to_string(st.fg->g) + ";" + std::to_string(st.fg->b));
    if (st.bg) add("48;2;" + std::to_string(st.bg->r) + ";" + std::to_string(st.bg->g) + ";" + std::to_string(st.bg->b));
    l.s += e + "m" + t + "\x1b[0m";
  }

  void pill(Line& l, const string& text, RGB c) const {
    if (o_.icons) {
      put(l, "\uE0B6", fg(c));
      Sty s; s.fg = CRUST; s.bg = c; s.bold = true;
      put(l, " " + text + " ", s);
      put(l, "\uE0B4 ", fg(c));
    } else {
      put(l, "[" + text + "] ", fgb(c));
    }
  }

  RGB status_color(Status s) const {
    switch (s) {
      case Status::Added: return GREEN;
      case Status::Removed: return RED;
      case Status::Modified: return YELLOW;
      case Status::ApiChange: return PEACH;
      case Status::Renamed: return BLUE;
    }
    return TEXT;
  }
  string status_glyph(Status s) const {
    if (o_.icons) {
      switch (s) {
        case Status::Added: return "\uF067";
        case Status::Removed: return "\uF068";
        case Status::Modified: return "\uF040";
        case Status::ApiChange: return "\uF071";
        case Status::Renamed: return "\uF0EC";
      }
    }
    switch (s) {
      case Status::Added: return "+";
      case Status::Removed: return "-";
      case Status::Modified: return "~";
      case Status::ApiChange: return "!";
      case Status::Renamed: return ">";
    }
    return "?";
  }
  string status_label(Status s) const {
    switch (s) {
      case Status::Added: return "added";
      case Status::Removed: return "removed";
      case Status::Modified: return "modified";
      case Status::ApiChange: return "API change";
      case Status::Renamed: return "renamed";
    }
    return "";
  }

  string kind_glyph(Kind k, bool scope_is_type) const {
    if (!o_.icons) {
      switch (k) {
        case Kind::Class: case Kind::Struct: case Kind::Union: return "C";
        case Kind::Enum: return "E";
        case Kind::Field: return "v";
        case Kind::Alias: return "t";
        case Kind::Namespace: return "N";
        default: return "f";
      }
    }
    switch (k) {
      case Kind::Namespace: return "\uEA8B";
      case Kind::Class: return "\uEB5B";
      case Kind::Struct: case Kind::Union: return "\uEA91";
      case Kind::Enum: return "\uEA95";
      case Kind::Function: return "\U000F0295";
      case Kind::Method: case Kind::Constructor: case Kind::Destructor: return "\uEA8C";
      case Kind::Operator: return "\uEB64";
      case Kind::Field: return "\uEB5F";
      case Kind::Alias: return "\uEB61";
    }
    (void)scope_is_type;
    return "";
  }
  RGB kind_color(Kind k) const {
    switch (k) {
      case Kind::Namespace: return BLUE;
      case Kind::Class: case Kind::Struct: case Kind::Union: return MAUVE;
      case Kind::Enum: return PEACH;
      case Kind::Function: return TEAL;
      case Kind::Method: return SAPPHIRE;
      case Kind::Constructor: case Kind::Destructor: return PINK;
      case Kind::Operator: return YELLOW;
      case Kind::Field: return SUB;
      case Kind::Alias: return BLUE;
    }
    return TEXT;
  }

  string guide(bool last) const {
    if (o_.icons) return last ? "└─ " : "├─ ";
    return last ? "`- " : "|- ";
  }
  string cont(bool last) const {
    if (last) return "   ";
    return o_.icons ? "│  " : "|  ";
  }
  string rule_char() const { return o_.icons ? "─" : "-"; }

 private:
  const RenderOptions& o_;
};

struct TNode {
  string label;
  const Change* ch = nullptr;
  bool is_type = false;
  vector<std::unique_ptr<TNode>> kids;
  std::map<string, TNode*> idx;
  int line = INT_MAX;
  int hidden = 0;
  int cnt[5] = {0, 0, 0, 0, 0};
};

TNode* scope_node(TNode* root, const vector<string>& scope, const std::set<string>& types) {
  TNode* cur = root;
  string path;
  for (auto& seg : scope) {
    path += (path.empty() ? "" : "::") + seg;
    auto it = cur->idx.find(seg);
    if (it == cur->idx.end()) {
      auto n = std::make_unique<TNode>();
      n->label = seg;
      n->is_type = types.count(path) > 0;
      TNode* raw = n.get();
      cur->kids.push_back(std::move(n));
      cur->idx[seg] = raw;
      cur = raw;
    } else cur = it->second;
  }
  return cur;
}

void finalize_tree(TNode* n) {
  if (n->ch) n->line = n->ch->line;
  for (auto& k : n->kids) {
    finalize_tree(k.get());
    n->line = std::min(n->line, k->line);
    for (int i = 0; i < 5; ++i) n->cnt[i] += k->cnt[i];
    if (k->ch) n->cnt[static_cast<int>(k->ch->status)]++;
  }
  std::stable_sort(n->kids.begin(), n->kids.end(),
                   [](const auto& a, const auto& b) { return a->line < b->line; });
}

string labels_only(const vector<string>& reasons) {
  vector<string> l;
  for (auto& r : reasons) {
    if (r.rfind("renamed:", 0) == 0 || r.rfind("moved:", 0) == 0) continue;
    auto p = r.find(':');
    string x = r == "body changed" ? "body" : p == string::npos ? r : r.substr(0, p);
    if (r.size() > 11 && r.compare(r.size() - 11, 11, " (internal)") == 0 && p != string::npos) x += " (internal)";
    l.push_back(x);
  }
  return join(l, ", ");
}

class Renderer {
 public:
  Renderer(const DiffResult& r, const RenderOptions& o) : r_(r), o_(o), p_(o) {}

  string run() {
    string out;
    // ---- banner ----
    {
      Line l;
      p_.put(l, " ");
      if (o_.icons) { p_.put(l, "\uE725", fgb(PEACH)); p_.put(l, "  "); }
      p_.put(l, "gitcppdiff", fgb(MAUVE));
      p_.put(l, "  ");
      p_.put(l, o_.label, fgb(TEXT));
      out += l.s + "\n\n";
    }
    if (r_.changes.empty()) {
      Line l;
      p_.put(l, "  ");
      p_.put(l, o_.icons ? "\uF00C" : "ok", fgb(GREEN));
      p_.put(l, "  no C++ symbol changes", fgb(TEXT));
      p_.put(l, "  (" + std::to_string(o_.files_scanned) + " file" + (o_.files_scanned == 1 ? "" : "s") + " scanned)", fg(DIM));
      return out + l.s + "\n";
    }

    // ---- summary ----
    int tot[5] = {0, 0, 0, 0, 0};
    std::map<string, vector<const Change*>> by_file;
    for (auto& c : r_.changes) { tot[static_cast<int>(c.status)]++; by_file[c.file].push_back(&c); }
    {
      Line l;
      p_.put(l, "  ");
      p_.put(l, std::to_string(by_file.size()) + " file" + (by_file.size() == 1 ? "" : "s"), fgb(TEXT));
      p_.put(l, "  ·  ", fg(DIM));
      p_.put(l, std::to_string(r_.changes.size()) + " symbol" + (r_.changes.size() == 1 ? "" : "s"), fgb(TEXT));
      p_.put(l, "      ");
      for (Status s : {Status::Added, Status::Removed, Status::Modified, Status::ApiChange, Status::Renamed}) {
        int n = tot[static_cast<int>(s)];
        if (!n) continue;
        p_.put(l, p_.status_glyph(s) + " " + std::to_string(n), fgb(p_.status_color(s)));
        p_.put(l, " " + p_.status_label(s) + "   ", fg(SUB));
      }
      out += l.s + "\n\n";
    }

    // collapse members of wholly added/removed types
    for (auto& c : r_.changes)
      if (is_type_kind(c.kind) && (c.status == Status::Added || c.status == Status::Removed))
        collapse_.push_back(&c);

    for (auto& [file, list] : by_file) out += render_file(file, list) + "\n";

    // ---- legend ----
    {
      Line l;
      p_.put(l, "  ");
      for (Status s : {Status::Added, Status::Removed, Status::Modified, Status::ApiChange, Status::Renamed}) {
        p_.put(l, p_.status_glyph(s), fg(p_.status_color(s)));
        p_.put(l, " " + p_.status_label(s) + "   ", fg(DIM));
      }
      out += l.s + "\n";
    }
    return out;
  }

 private:
  const DiffResult& r_;
  const RenderOptions& o_;
  Painter p_;
  vector<const Change*> collapse_;

  const Change* collapsed_by(const Change& c) const {
    if (o_.expand) return nullptr;
    string sc = join(c.scope, "::");
    const Change* best = nullptr;
    for (auto* t : collapse_) {
      if (t == &c || t->status != c.status) continue;
      const string& q = t->qualified;
      if (sc == q || sc.rfind(q + "::", 0) == 0)
        if (!best || q.size() < best->qualified.size()) best = t;
    }
    return best;
  }

  string render_file(const string& file, const vector<const Change*>& list) {
    TNode root;
    std::map<const Change*, TNode*> where;
    for (auto* c : list) {
      if (auto* by = collapsed_by(*c)) { hidden_[by]++; continue; }
      TNode* node;
      if (is_type_kind(c->kind)) {
        vector<string> sc = c->scope;
        sc.push_back(c->name);
        node = scope_node(&root, sc, r_.type_scopes);
        node->is_type = true;
      } else {
        TNode* parent = scope_node(&root, c->scope, r_.type_scopes);
        auto n = std::make_unique<TNode>();
        node = n.get();
        parent->kids.push_back(std::move(n));
      }
      node->ch = c;
      where[c] = node;
    }
    for (auto& [c, node] : where) node->hidden = hidden_.count(c) ? hidden_[c] : 0;
    finalize_tree(&root);

    string out;
    int tot[5] = {0, 0, 0, 0, 0};
    for (auto* c : list) tot[static_cast<int>(c->status)]++;

    Line left, right;
    p_.put(left, " ");
    bool hdr = is_header_path(file);
    if (p_.icons()) { p_.put(left, hdr ? "\uE61E" : "\uE61D", fgb(hdr ? MAUVE : BLUE)); p_.put(left, " "); }
    auto slash = file.rfind('/');
    if (slash != string::npos) p_.put(left, file.substr(0, slash + 1), fg(SUB));
    p_.put(left, slash == string::npos ? file : file.substr(slash + 1), fgb(TEXT));
    for (Status s : {Status::Added, Status::Removed, Status::Modified, Status::ApiChange, Status::Renamed}) {
      int n = tot[static_cast<int>(s)];
      if (!n) continue;
      p_.put(right, p_.status_glyph(s) + std::to_string(n) + " ", fgb(p_.status_color(s)));
    }
    int fill = std::max(3, o_.width - left.w - right.w - 3);
    string rl;
    for (int i = 0; i < fill; ++i) rl += p_.rule_char();
    Line mid;
    p_.put(mid, " ");
    p_.put(mid, rl, fg(DIM));
    p_.put(mid, " ");
    out += left.s + mid.s + right.s + "\n";

    for (size_t i = 0; i < root.kids.size(); ++i)
      render_node(*root.kids[i], " ", i + 1 == root.kids.size(), out);
    return out;
  }

  void counts(Line& l, const TNode& n) {
    bool any = false;
    for (int i = 0; i < 5; ++i) if (n.cnt[i]) any = true;
    if (!any) return;
    p_.put(l, "  ");
    for (Status s : {Status::Added, Status::Removed, Status::Modified, Status::ApiChange, Status::Renamed}) {
      int c = n.cnt[static_cast<int>(s)];
      if (c) p_.put(l, p_.status_glyph(s) + std::to_string(c) + " ", fg(p_.status_color(s)));
    }
  }

  void render_node(const TNode& n, const string& prefix, bool last, string& out) {
    Line l;
    p_.put(l, prefix + p_.guide(last), fg(DIM));
    string cp = prefix + p_.cont(last);

    if (!n.ch) {  // context node (namespace / untouched class)
      p_.put(l, p_.kind_glyph(n.is_type ? Kind::Class : Kind::Namespace, n.is_type) + " ",
             fg(n.is_type ? MAUVE : BLUE));
      Sty st = fg(SUB); st.italic = true;
      p_.put(l, n.label, st);
      counts(l, n);
      out += l.s + "\n";
    } else {
      const Change& c = *n.ch;
      const Symbol& s = c.sym();
      RGB sc = p_.status_color(c.status);
      p_.put(l, p_.status_glyph(c.status) + " ", fgb(sc));
      p_.put(l, p_.kind_glyph(c.kind, false) + " ", fg(p_.kind_color(c.kind)));
      string name = s.name, rest = s.label.substr(std::min(s.label.size(), s.name.size()));
      Sty ns = fgb(TEXT);
      if (c.status == Status::Added) ns = fgb(GREEN);
      if (c.status == Status::Removed) { ns = fg(RED); ns.strike = true; }
      p_.put(l, name, ns);
      if (!rest.empty()) p_.put(l, rest, fg(SUB));
      if (is_type_kind(c.kind)) p_.put(l, "  " + string(kind_name(c.kind)), fg(DIM));
      p_.put(l, "  ");
      if (c.status == Status::ApiChange) p_.pill(l, "API", PEACH);
      else if (c.status == Status::Renamed) p_.pill(l, c.reasons.size() && c.reasons[0].rfind("moved", 0) == 0 ? "MOVED" : "RENAMED", BLUE);
      else if (c.status == Status::Modified && !c.reasons.empty()) {
        bool body = false, sig = false;
        for (auto& r : c.reasons) (r == "body changed" ? body : sig) = true;
        string t = body && sig ? "body + signature" : sig ? "signature" : "body";
        if (c.reasons.size() == 1 && c.reasons[0] == "definition added") t = "definition added";
        if (c.reasons.size() == 1 && c.reasons[0] == "definition removed") t = "definition removed";
        p_.put(l, t, fg(DIM));
        p_.put(l, "  ");
      } else if (c.api && (c.status == Status::Added || c.status == Status::Removed)) {
        p_.put(l, "api", fg(DIM));
        p_.put(l, "  ");
      }
      if (n.hidden) p_.put(l, string(c.status == Status::Added ? "+" : "-") + std::to_string(n.hidden) + " members  ", fg(DIM));
      if (!n.kids.empty()) counts(l, n);
      p_.put(l, ":" + std::to_string(c.line), fg(DIM));
      out += l.s + "\n";
      details(c, cp, n.kids.empty(), out);
    }
    for (size_t i = 0; i < n.kids.size(); ++i) render_node(*n.kids[i], cp, i + 1 == n.kids.size(), out);
  }

  void details(const Change& c, const string& cp, bool leaf, string& out) {
    (void)leaf;
    auto dline = [&](const string& mark, RGB col, const string& text, bool strike = false) {
      Line d;
      p_.put(d, cp, fg(DIM));
      p_.put(d, "   ");
      p_.put(d, mark + " ", fgb(col));
      Sty st = fg(col); st.strike = false; (void)strike;
      p_.put(d, text, st);
      out += d.s + "\n";
    };
    auto note = [&](const string& text) {
      Line d;
      p_.put(d, cp, fg(DIM));
      p_.put(d, "   ");
      p_.put(d, (p_.icons() ? "↳ " : "-> "), fg(DIM));
      p_.put(d, text, fg(SUB));
      out += d.s + "\n";
    };
    if (c.status != Status::ApiChange && c.status != Status::Renamed && c.status != Status::Modified) return;
    if (!c.old_e || !c.new_e) return;

    if (c.status == Status::Renamed && !c.reasons.empty()) note(c.reasons[0]);

    bool sig_reasons = false;
    for (auto& r : c.reasons) if (r != "body changed" && r != "definition added" && r != "definition removed" &&
                                  r.rfind("renamed:", 0) != 0 && r.rfind("moved:", 0) != 0) sig_reasons = true;
    if (!sig_reasons) return;

    const string& a = c.old_e->primary().sig;
    const string& b = c.new_e->primary().sig;
    if (a != b && !is_type_kind(c.kind)) {
      dline("-", RED, a);
      dline("+", GREEN, b);
      string lbl = labels_only(c.reasons);
      if (!lbl.empty()) note("changed: " + lbl);
    } else if (a != b) {
      dline("-", RED, a);
      dline("+", GREEN, b);
      string lbl = labels_only(c.reasons);
      if (!lbl.empty()) note("changed: " + lbl);
    } else {
      for (auto& r : c.reasons)
        if (r != "body changed" && r != "definition added" && r != "definition removed") note(r);
    }
  }

  std::map<const Change*, int> hidden_;
};

}  // namespace

std::string render_pretty(const DiffResult& r, const RenderOptions& o) {
  return Renderer(r, o).run();
}

}  // namespace cppdiff
