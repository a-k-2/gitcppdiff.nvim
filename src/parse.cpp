#include "parse.hpp"

#include <tree_sitter/api.h>

#include <cstring>
#include <functional>
#include <string_view>

extern "C" const TSLanguage* tree_sitter_cpp();

namespace cppdiff {
namespace {

using std::string;
using std::vector;
using Skip = std::function<bool(TSNode)>;

// ---------- small helpers ----------

bool is_t(TSNode n, const char* t) { return std::strcmp(ts_node_type(n), t) == 0; }
TSNode field(TSNode n, const char* f) { return ts_node_child_by_field_name(n, f, std::strlen(f)); }
bool null(TSNode n) { return ts_node_is_null(n); }
uint32_t sb(TSNode n) { return ts_node_start_byte(n); }
uint32_t eb(TSNode n) { return ts_node_end_byte(n); }

vector<TSNode> kids(TSNode n) {
  vector<TSNode> v;
  for (uint32_t i = 0, c = ts_node_child_count(n); i < c; ++i) v.push_back(ts_node_child(n, i));
  return v;
}

vector<TSNode> field_kids(TSNode n, const char* f) {
  vector<TSNode> out;
  TSTreeCursor cur = ts_tree_cursor_new(n);
  if (ts_tree_cursor_goto_first_child(&cur)) {
    do {
      const char* fn = ts_tree_cursor_current_field_name(&cur);
      if (fn && !std::strcmp(fn, f)) out.push_back(ts_tree_cursor_current_node(&cur));
    } while (ts_tree_cursor_goto_next_sibling(&cur));
  }
  ts_tree_cursor_delete(&cur);
  return out;
}

string squash(const string& s) {
  string o;
  bool sp = false;
  for (unsigned char c : s) {
    if (isspace(c)) { sp = true; continue; }
    if (sp && !o.empty()) o += ' ';
    sp = false;
    o += static_cast<char>(c);
  }
  return o;
}

bool wordish(const string& t) {
  unsigned char c = static_cast<unsigned char>(t[0]);
  return isalnum(c) || c == '_' || c >= 0x80 || c == '"' || c == '\'' || c == '~' ;
}

// Canonical, formatting-insensitive rendering of a token sequence.
string join_tokens(const vector<string>& t) {
  string o;
  for (size_t i = 0; i < t.size(); ++i) {
    if (i) {
      const string& p = t[i - 1];
      const string& c = t[i];
      bool sp = p == "operator" ? wordish(c) : (p == "*" || p == "&" || p == "&&") ? wordish(c) : (wordish(p) && wordish(c) && p != "~") || p == "," || c == "=" || p == "=" ||
                c == "->" || p == "->" || c == "?" || p == "?" || c == ":" || p == ":";
      if (sp) o += ' ';
    }
    o += t[i];
  }
  return o;
}

// Split "A<B::C>::D::operator::" style names at top-level "::".
vector<string> split_scope(const string& s) {
  vector<string> parts;
  string cur;
  int depth = 0;
  for (size_t i = 0; i < s.size(); ++i) {
    if (cur == "operator" || (cur.rfind("operator", 0) == 0 && cur.size() > 8 && !isalnum((unsigned char)cur[8]) && cur[8] != '_')) {
      cur += s.substr(i); break;
    }
    char c = s[i];
    if (c == '<') ++depth;
    else if (c == '>') --depth;
    if (c == ':' && i + 1 < s.size() && s[i + 1] == ':' && depth <= 0) {
      if (!cur.empty()) parts.push_back(cur);
      cur.clear(); ++i; continue;
    }
    cur += c;
  }
  if (!cur.empty()) parts.push_back(cur);
  return parts;
}

string strip_targs(const string& s) {
  auto p = s.find('<');
  return p == string::npos || p == 0 ? s : s.substr(0, p);
}

const char* access_str(Access a) {
  switch (a) {
    case Access::Public: return "public";
    case Access::Protected: return "protected";
    case Access::Private: return "private";
    default: return "";
  }
}

void add_facet(Facets& f, const char* label, const string& v) {
  if (!v.empty()) f.emplace_back(label, v);
}

// Split leading decl-specifier tokens into (specifiers, rest-as-type).
void split_spec(const vector<string>& lead, string& spec, vector<string>& rest) {
  static const std::set<string> kSpec = {"virtual", "static", "inline", "constexpr", "consteval",
                                         "constinit", "explicit", "friend", "extern", "mutable",
                                         "thread_local"};
  vector<string> sp;
  for (size_t i = 0; i < lead.size(); ++i) {
    if (lead[i] == "[[") {
      string a;
      while (i < lead.size()) { a += lead[i]; if (lead[i] == "]]") break; ++i; }
      sp.push_back(a);
    } else if (kSpec.count(lead[i])) sp.push_back(lead[i]);
    else rest.push_back(lead[i]);
  }
  spec = join(sp, " ");
}

// ---------- extractor ----------

// Canonical cv-qualifier placement: `Z const&` == `const Z&`, also inside template arguments.
// Only the qualifiers of the base type move (before the first * / & / &&); `char* const` is kept.
vector<string> norm_cv_tokens(const vector<string>& t) {
  vector<string> out;
  for (size_t i = 0; i < t.size(); ++i) {
    if (t[i] != "<") { out.push_back(t[i]); continue; }
    int depth = 1;
    size_t j = i + 1;
    for (; j < t.size() && depth > 0; ++j) {
      if (t[j] == "<") ++depth;
      else if (t[j] == ">") --depth;
    }
    if (depth != 0) { out.push_back(t[i]); continue; }  // not a template argument list
    size_t close = j - 1;
    out.push_back("<");
    vector<string> cur;
    int d = 0;
    auto flush = [&](bool last) {
      auto n = norm_cv_tokens(cur);
      out.insert(out.end(), n.begin(), n.end());
      if (!last) out.push_back(",");
      cur.clear();
    };
    for (size_t k = i + 1; k < close; ++k) {
      if (t[k] == "<") ++d;
      else if (t[k] == ">") --d;
      if (t[k] == "," && d == 0) flush(false); else cur.push_back(t[k]);
    }
    flush(true);
    out.push_back(">");
    i = close;
  }
  size_t end = out.size();
  int d = 0;
  for (size_t i = 0; i < out.size(); ++i) {
    if (out[i] == "<") ++d;
    else if (out[i] == ">") --d;
    else if (d == 0 && (out[i] == "*" || out[i] == "&" || out[i] == "&&")) { end = i; break; }
  }
  bool c = false, v = false;
  vector<string> rest;
  d = 0;
  for (size_t i = 0; i < end; ++i) {
    if (out[i] == "<") ++d;
    else if (out[i] == ">") --d;
    if (d == 0 && out[i] == "const") { c = true; continue; }
    if (d == 0 && out[i] == "volatile") { v = true; continue; }
    rest.push_back(out[i]);
  }
  vector<string> res;
  if (c) res.push_back("const");
  if (v) res.push_back("volatile");
  res.insert(res.end(), rest.begin(), rest.end());
  res.insert(res.end(), out.begin() + static_cast<long>(end), out.end());
  return res;
}
string norm_type(const vector<string>& t) { return join_tokens(norm_cv_tokens(t)); }

struct Ctx {
  vector<string> scope;
  string tmpl;       // as written, e.g. template<typename T>
  string tmpl_norm;  // parameter names dropped, used for comparison
  Access access = Access::None;
  bool in_class = false;
  bool anon = false;
  string class_name;
};

class Extractor {
 public:
  Extractor(Side& side, const string& file, const string& src, const std::set<string>& internal_ns)
      : side_(side), file_(file), src_(src), header_(is_header_path(file)), internal_ns_(internal_ns) {}

  void run(TSNode root) {
    Ctx c;
    visit_children(root, c);
  }

 private:
  Side& side_;
  const string& file_;
  const string& src_;
  bool header_;
  const std::set<string>& internal_ns_;

  string text(TSNode n) const { return src_.substr(sb(n), eb(n) - sb(n)); }
  int line_of(TSNode n) const { return static_cast<int>(ts_node_start_point(n).row) + 1; }
  int end_line_of(TSNode n) const { return static_cast<int>(ts_node_end_point(n).row) + 1; }

  void collect(TSNode n, vector<string>& out, const Skip& skip = nullptr) const {
    if (null(n) || is_t(n, "comment")) return;
    if (skip && skip(n)) return;
    uint32_t cc = ts_node_child_count(n);
    if (cc == 0) {
      string t = squash(text(n));
      if (!t.empty()) out.push_back(t);
      return;
    }
    for (uint32_t i = 0; i < cc; ++i) collect(ts_node_child(n, i), out, skip);
  }
  vector<string> tokens(TSNode n, const Skip& skip = nullptr) const {
    vector<string> v; collect(n, v, skip); return v;
  }

  void fill_body(Symbol& s, const vector<string>& toks) const {
    s.is_def = true;
    uint64_t h = kFnvBasis;
    for (auto& t : toks) h = fnv(h, t);
    s.body_hash = h;
    s.body_len = toks.size();
    for (size_t i = 0; i + 1 < toks.size(); ++i) s.grams.push_back(fnv(fnv(kFnvBasis, toks[i]), toks[i + 1]));
    if (toks.size() == 1) s.grams.push_back(fnv(kFnvBasis, toks[0]));
    std::sort(s.grams.begin(), s.grams.end());
    s.grams.erase(std::unique(s.grams.begin(), s.grams.end()), s.grams.end());
  }

  void fill_common(Symbol& s, TSNode n, const Ctx& c) const {
    s.file = file_;
    s.is_header = header_;
    s.internal = c.anon;
    TSNode p = ts_node_parent(n);
    TSNode start = (!null(p) && is_t(p, "template_declaration")) ? p : n;
    s.line = line_of(start);
    s.end_line = end_line_of(n);
    if (c.in_class) s.access = c.access;
  }

  void visit_children(TSNode n, Ctx& c) {
    if (null(n)) return;
    for (uint32_t i = 0, cc = ts_node_child_count(n); i < cc; ++i) visit(ts_node_child(n, i), c);
  }

  void visit(TSNode n, Ctx& c) {
    std::string_view t = ts_node_type(n);
    if (t == "namespace_definition") ns(n, c);
    else if (t == "class_specifier" || t == "struct_specifier" || t == "union_specifier") cls(n, c);
    else if (t == "enum_specifier") enm(n, c);
    else if (t == "template_declaration") {
      Ctx c2 = c;
      TSNode params = field(n, "parameters");
      c2.tmpl = null(params) ? "template<>" : "template" + join_tokens(tokens(params));
      c2.tmpl_norm = null(params) ? "template<>" : norm_tparams(params);
      for (auto k : kids(n)) if (!(sb(k) == sb(params) && eb(k) == eb(params))) visit(k, c2);
    }
    else if (t == "function_definition") func(n, c, true);
    else if (t == "declaration" || t == "field_declaration") decl(n, c);
    else if (t == "access_specifier") {
      string a = squash(text(n));
      if (a.rfind("public", 0) == 0) c.access = Access::Public;
      else if (a.rfind("protected", 0) == 0) c.access = Access::Protected;
      else if (a.rfind("private", 0) == 0) c.access = Access::Private;
    }
    else if (t == "alias_declaration") alias(n, c);
    else if (t == "type_definition") tdef(n, c);
    else if (t == "linkage_specification") {
      TSNode b = field(n, "body");
      if (!null(b)) { if (is_t(b, "declaration_list")) visit_children(b, c); else visit(b, c); }
    }
    else if (t.rfind("preproc_if", 0) == 0 || t.rfind("preproc_el", 0) == 0 ||
             t == "declaration_list" || t == "field_declaration_list" || t == "translation_unit")
      visit_children(n, c);
    else if (t == "ERROR") { side_.errors++; visit_children(n, c); }
  }

  string norm_tparams(TSNode list) const {
    vector<string> ps;
    for (auto k : kids(list)) {
      if (!ts_node_is_named(k) || is_t(k, "comment")) continue;
      string t = ts_node_type(k);
      vector<string> tok;
      if (t == "type_parameter_declaration" || t == "variadic_type_parameter_declaration") {
        bool eq = false, dropped = false;
        for (auto ch : kids(k)) {
          if (is_t(ch, "=")) eq = true;
          if (!eq && !dropped && is_t(ch, "type_identifier")) { dropped = true; continue; }
          collect(ch, tok);
        }
      } else if (t == "parameter_declaration" || t == "optional_parameter_declaration" ||
                 t == "variadic_parameter_declaration") {
        TSNode idn = find_identifier(field(k, "declarator"));
        collect(k, tok, [&](TSNode x) { return !null(idn) && sb(x) == sb(idn) && eb(x) == eb(idn) && ts_node_child_count(x) == 0; });
      } else {
        collect(k, tok);
      }
      ps.push_back(join_tokens(tok));
    }
    return "template<" + join(ps, ", ") + ">";
  }

  // ----- namespaces -----
  void ns(TSNode n, Ctx& c) {
    Ctx c2 = c;
    c2.tmpl.clear(); c2.access = Access::None; c2.in_class = false;
    TSNode nm = field(n, "name");
    if (null(nm)) { c2.scope.push_back("(anonymous)"); c2.anon = true; }
    else for (auto& p : split_scope(join_tokens(tokens(nm)))) {
      c2.scope.push_back(p);
      if (internal_ns_.count(p)) c2.anon = true;  // e.g. `detail`, `internal`: not public API
    }
    for (size_t i = 1; i <= c2.scope.size(); ++i)
      side_.namespaces.insert(join(vector<string>(c2.scope.begin(), c2.scope.begin() + i), "::"));
    visit_children(field(n, "body"), c2);
  }

  // ----- classes / structs / unions -----
  void cls(TSNode n, Ctx& c) {
    TSNode body = field(n, "body");
    if (null(body)) return;  // forward declaration
    string kw = is_t(n, "class_specifier") ? "class" : is_t(n, "struct_specifier") ? "struct" : "union";
    TSNode nm = field(n, "name");
    vector<string> parts;
    if (null(nm)) parts = {"(anonymous)"};
    else parts = split_scope(join_tokens(tokens(nm)));
    if (parts.empty()) return;
    bool spec_tmpl = c.tmpl == "template<>";
    vector<string> sc = c.scope;
    for (size_t i = 0; i + 1 < parts.size(); ++i) sc.push_back(spec_tmpl ? parts[i] : strip_targs(parts[i]));

    string bases, fin;
    for (auto k : kids(n)) {
      if (is_t(k, "base_class_clause")) {
        auto t = tokens(k);
        if (!t.empty() && t[0] == ":") t.erase(t.begin());
        bases = join_tokens(t);
      } else if (is_t(k, "virtual_specifier")) fin = squash(text(k));
    }

    Symbol s;
    s.kind = kw == "class" ? Kind::Class : kw == "struct" ? Kind::Struct : Kind::Union;
    s.scope = sc;
    s.name = parts.back();
    s.key = "type:" + s.qualified();
    fill_common(s, n, c);
    s.label = s.name;
    s.sig = (c.tmpl.empty() ? "" : c.tmpl + " ") + kw + " " + s.name + (fin.empty() ? "" : " " + fin) +
            (bases.empty() ? "" : " : " + bases);
    add_facet(s.facets, "template", c.tmpl_norm);
    add_facet(s.facets, "kind", kw);
    add_facet(s.facets, "bases", bases);
    add_facet(s.facets, "specifiers", fin);
    add_facet(s.facets, "access", access_str(s.access));
    side_.classes.insert(s.qualified());
    side_.add(s);

    Ctx c2;
    c2.scope = sc; c2.scope.push_back(s.name);
    c2.in_class = true;
    c2.access = kw == "class" ? Access::Private : Access::Public;
    c2.anon = c.anon;
    c2.class_name = strip_targs(s.name);
    visit_children(body, c2);
  }

  // ----- enums -----
  void enm(TSNode n, Ctx& c) {
    TSNode body = field(n, "body");
    TSNode nm = field(n, "name");
    if (null(body) || null(nm)) return;
    string kind = "enum";
    for (auto k : kids(n)) {
      if (sb(k) >= sb(nm)) break;
      string t = squash(text(k));
      if (t == "class" || t == "struct") kind = "enum " + t;
    }
    string under;
    TSNode base = field(n, "base");
    if (!null(base)) { auto t = tokens(base); if (!t.empty() && t[0] == ":") t.erase(t.begin()); under = join_tokens(t); }
    vector<string> en;
    for (auto k : kids(body)) if (is_t(k, "enumerator")) en.push_back(join_tokens(tokens(k)));

    Symbol s;
    s.kind = Kind::Enum;
    s.scope = c.scope;
    s.name = join_tokens(tokens(nm));
    s.key = "type:" + s.qualified();
    fill_common(s, n, c);
    s.label = s.name;
    s.sig = kind + " " + s.name + (under.empty() ? "" : " : " + under);
    add_facet(s.facets, "kind", kind);
    add_facet(s.facets, "underlying type", under);
    add_facet(s.facets, "enumerators", join(en, "\x1f"));
    add_facet(s.facets, "access", access_str(s.access));
    side_.add(s);
  }

  // ----- aliases / typedefs -----
  void alias(TSNode n, Ctx& c) {
    TSNode nm = field(n, "name");
    if (null(nm)) return;
    TSNode ty = field(n, "type");
    Symbol s;
    s.kind = Kind::Alias;
    s.scope = c.scope;
    s.name = squash(text(nm));
    s.key = "type:" + s.qualified();
    fill_common(s, n, c);
    string def = join_tokens(tokens(ty));
    s.label = s.name;
    s.sig = (c.tmpl.empty() ? "" : c.tmpl + " ") + "using " + s.name + " = " + def;
    add_facet(s.facets, "template", c.tmpl_norm);
    add_facet(s.facets, "definition", norm_type(tokens(ty)));
    add_facet(s.facets, "access", access_str(s.access));
    side_.add(s);
  }

  void tdef(TSNode n, Ctx& c) {
    TSNode d = field(n, "declarator");
    if (null(d) || !(is_t(d, "type_identifier") || is_t(d, "primitive_type"))) return;
    string name = squash(text(d));
    vector<string> ty = tokens(n, [&](TSNode k) { return sb(k) == sb(d) && eb(k) == eb(d); });
    ty.erase(std::remove(ty.begin(), ty.end(), "typedef"), ty.end());
    ty.erase(std::remove(ty.begin(), ty.end(), ";"), ty.end());
    Symbol s;
    s.kind = Kind::Alias;
    s.scope = c.scope;
    s.name = name;
    s.key = "type:" + s.qualified();
    fill_common(s, n, c);
    string def = join_tokens(ty);
    s.label = name;
    s.sig = "typedef " + def + " " + name;
    add_facet(s.facets, "definition", norm_type(ty));
    add_facet(s.facets, "access", access_str(s.access));
    side_.add(s);
  }

  // ----- declarations (functions, fields) -----
  void decl(TSNode n, Ctx& c) {
    TSNode ty = field(n, "type");
    if (!null(ty) && (is_t(ty, "class_specifier") || is_t(ty, "struct_specifier") ||
                      is_t(ty, "union_specifier") || is_t(ty, "enum_specifier")))
      visit(ty, c);
    bool fn = func(n, c, false);
    if (!fn && c.in_class && is_t(n, "field_declaration")) fields(n, c);
  }

  // Descend through pointer/reference wrappers to a function_declarator.
  bool unwrap(TSNode d, vector<string>& ptr, TSNode& fd) const {
    for (int guard = 0; guard < 16; ++guard) {
      if (is_t(d, "function_declarator") || is_t(d, "operator_cast")) { fd = d; return true; }
      if (is_t(d, "qualified_identifier")) {
        TSNode nm = field(d, "name");
        if (!null(nm) && is_t(nm, "operator_cast")) { fd = d; return true; }
        return false;
      }
      if (!(is_t(d, "pointer_declarator") || is_t(d, "reference_declarator") ||
            is_t(d, "parenthesized_declarator") || is_t(d, "attributed_declarator")))
        return false;
      TSNode inner = field(d, "declarator");
      if (null(inner)) {
        uint32_t nc = ts_node_named_child_count(d);
        if (!nc) return false;
        inner = ts_node_named_child(d, nc - 1);
      }
      for (auto k : kids(d)) {
        if (sb(k) == sb(inner) && eb(k) == eb(inner)) continue;
        collect(k, ptr);
      }
      d = inner;
    }
    return false;
  }

  vector<string> lead_tokens(TSNode n, TSNode first_decl) const {
    vector<string> lead;
    for (auto k : kids(n)) {
      if (sb(k) >= sb(first_decl)) break;
      if (is_t(k, "comment") || is_t(k, "access_specifier")) continue;
      if ((is_t(k, "class_specifier") || is_t(k, "struct_specifier") || is_t(k, "union_specifier") ||
           is_t(k, "enum_specifier")) && !null(field(k, "body"))) {
        TSNode nm = field(k, "name");
        lead.push_back(null(nm) ? "(anonymous)" : squash(text(nm)));
        continue;
      }
      collect(k, lead);
    }
    return lead;
  }

  bool func(TSNode n, const Ctx& c, bool def_node) {
    auto decls = field_kids(n, "declarator");
    if (decls.empty()) return false;
    bool any = false;
    TSNode body = field(n, "body");
    bool has_body = def_node && !null(body) && (is_t(body, "compound_statement") || is_t(body, "function_try_block"));

    for (TSNode d : decls) {
      vector<string> ptr;
      TSNode fd;
      if (!unwrap(d, ptr, fd)) continue;
      TSNode paramsN, trailParent;
      string full;
      if (is_t(fd, "function_declarator")) {
        TSNode nameN = field(fd, "declarator");
        paramsN = field(fd, "parameters");
        trailParent = fd;
        if (null(nameN) || null(paramsN)) continue;
        full = join_tokens(tokens(nameN));
      } else {  // conversion operator: [Scope::]operator T() [quals]
        TSNode oc = is_t(fd, "operator_cast") ? fd : field(fd, "name");
        TSNode afd = field(oc, "declarator");
        if (null(afd)) continue;
        paramsN = field(afd, "parameters");
        trailParent = afd;
        if (null(paramsN)) continue;
        string pre = join_tokens(tokens(fd, [&](TSNode x) { return sb(x) >= sb(oc); }));
        full = pre + "operator " + join_tokens(tokens(field(oc, "type")));
      }
      any = true;

      // name & scope
      vector<string> parts = split_scope(full);
      if (parts.empty()) continue;
      string last = parts.back();
      bool spec_tmpl = c.tmpl == "template<>";
      vector<string> sc = c.scope;
      for (size_t i = 0; i + 1 < parts.size(); ++i) sc.push_back(spec_tmpl ? parts[i] : strip_targs(parts[i]));
      bool qualified = parts.size() > 1;

      Kind kind = c.in_class ? Kind::Method : Kind::Function;
      if (!last.empty() && last[0] == '~') kind = Kind::Destructor;
      else if (last.rfind("operator", 0) == 0) kind = Kind::Operator;
      else if ((c.in_class && strip_targs(last) == c.class_name) ||
               (parts.size() >= 2 && strip_targs(parts[parts.size() - 2]) == strip_targs(last)))
        kind = Kind::Constructor;

      // leading specifiers / return type
      string spec;
      vector<string> rt;
      split_spec(lead_tokens(n, decls[0]), spec, rt);
      for (auto& p : ptr) rt.push_back(p);
      string ret = join_tokens(rt);
      string ret_n = norm_type(rt);
      if (ret.empty() && (kind == Kind::Function || kind == Kind::Method)) continue;  // macro-like

      // parameters
      vector<string> ptypes, pdisp, pdefs;
      for (auto pn : kids(paramsN)) {
        string pt = ts_node_type(pn);
        if (pt == "...") { ptypes.push_back("..."); pdisp.push_back("..."); continue; }
        if (!ts_node_is_named(pn) || pt == "comment") continue;
        TSNode dn = field(pn, "declarator");
        TSNode dv = field(pn, "default_value");
        TSNode idn{};
        idn = find_identifier(dn);
        vector<string> tt;
        for (auto k : kids(pn)) {
          if (!null(dv) && sb(k) == sb(dv) && eb(k) == eb(dv)) continue;
          if (is_t(k, "=")) continue;
          collect(k, tt, [&](TSNode x) { return !null(idn) && sb(x) == sb(idn) && eb(x) == eb(idn) && ts_node_child_count(x) == 0; });
        }
        string type = join_tokens(tt);
        string name = null(idn) ? "" : squash(text(idn));
        string def = null(dv) ? "" : join_tokens(tokens(dv));
        ptypes.push_back(norm_type(tt));
        if (!def.empty()) pdefs.push_back(std::to_string(ptypes.size() - 1) + "=" + def);
        pdisp.push_back(type + (name.empty() ? "" : " " + name) + (def.empty() ? "" : " = " + def));
      }
      if (ptypes.size() == 1 && ptypes[0] == "void") { ptypes.clear(); pdisp.clear(); }

      // trailing qualifiers: after parameter list (const, noexcept, override, -> T ...)
      vector<string> tq;
      bool after = false;
      for (auto k : kids(trailParent)) {
        if (after) collect(k, tq);
        if (sb(k) == sb(paramsN) && eb(k) == eb(paramsN)) after = true;
      }
      TSNode lastd = decls.back();
      for (auto k : kids(n)) {  // "= 0", "= default", "= delete"
        if (sb(k) < eb(lastd)) continue;
        if (is_t(k, "compound_statement") || is_t(k, "field_initializer_list") ||
            is_t(k, "function_try_block") || is_t(k, "comment") || is_t(k, ";") || is_t(k, ",") || is_t(k, ":") ||
            is_t(k, "ERROR")) continue;
        collect(k, tq, [](TSNode x) { return is_t(x, ";"); });
      }
      string quals = join_tokens(tq);
      vector<string> kq;
      for (auto& t : tq) if (t == "const" || t == "volatile" || t == "&" || t == "&&") kq.push_back(t);

      Symbol s;
      s.kind = kind;
      s.scope = sc;
      s.name = last;
      s.qualified_def = qualified;
      s.internal = c.anon || spec.find("static") != string::npos;
      string pstr = join(pdisp, ", ");
      s.key = "fn:" + s.qualified() + "(" + join(ptypes, ",") + ")" + (kq.empty() ? "" : " " + join(kq, " "));
      fill_common(s, n, c);
      s.internal = c.anon || spec.find("static") != string::npos;
      if (!qualified && !c.in_class) s.access = Access::None;
      else if (!c.in_class) s.access = Access::Unknown;
      s.label = last + "(" + pstr + ")" + (quals.empty() ? "" : " " + quals);
      s.sig = (c.tmpl.empty() ? "" : c.tmpl + " ") + (spec.empty() ? "" : spec + " ") +
              (ret.empty() ? "" : ret + " ") + s.label;
      add_facet(s.facets, "template", c.tmpl_norm);
      add_facet(s.facets, "specifiers", spec);
      add_facet(s.facets, "return type", ret_n);
      add_facet(s.facets, "parameters", join(ptypes, ", "));
      add_facet(s.facets, "default args", join(pdefs, ", "));
      add_facet(s.facets, "qualifiers", quals);
      add_facet(s.facets, "access", access_str(s.access));
      if (has_body) {
        vector<string> bt = tokens(body);
        for (auto k : kids(n)) if (is_t(k, "field_initializer_list") || is_t(k, "ERROR")) collect(k, bt);
        fill_body(s, bt);
        s.inline_def = c.in_class;
      }
      side_.add(s);
    }
    return any;
  }

  TSNode find_identifier(TSNode n) const {
    if (null(n)) return TSNode{};
    if (is_t(n, "identifier") || is_t(n, "field_identifier")) return n;
    for (auto k : kids(n)) {
      TSNode r = find_identifier(k);
      if (!null(r)) return r;
    }
    return TSNode{};
  }

  void fields(TSNode n, const Ctx& c) {
    auto decls = field_kids(n, "declarator");
    if (decls.empty()) return;
    string spec;
    vector<string> lead_type;
    split_spec(lead_tokens(n, decls[0]), spec, lead_type);
    TSNode dv = field(n, "default_value");
    bool macro_lead = lead_type.size() == 1 && lead_type[0].find_first_not_of("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_") == string::npos;
    for (TSNode d : decls) {
      if (macro_lead && is_t(d, "parenthesized_declarator")) continue;  // DECLARE_FOO(Bar)
      TSNode id = find_identifier(d);
      if (null(id)) continue;
      vector<string> tt = lead_type;
      collect(d, tt, [&](TSNode x) { return sb(x) == sb(id) && eb(x) == eb(id) && ts_node_child_count(x) == 0; });
      string type = join_tokens(tt);
      string type_n = norm_type(tt);
      Symbol s;
      s.kind = Kind::Field;
      s.scope = c.scope;
      s.name = squash(text(id));
      s.key = "var:" + s.qualified();
      fill_common(s, n, c);
      s.label = s.name + ": " + type;
      s.sig = (spec.empty() ? "" : spec + " ") + type + " " + s.name;
      add_facet(s.facets, "specifiers", spec);
      add_facet(s.facets, "type", type_n);
      add_facet(s.facets, "access", access_str(s.access));
      if (!null(dv)) {
        fill_body(s, tokens(dv));
        s.inline_def = true;
      }
      side_.add(s);
    }
  }
};

}  // namespace

string blank_macros(const string& src, const std::set<string>& user) {
  static const std::set<string> kLead = {"template", "class", "struct", "union", "enum", "namespace"};
  string out = src;
  size_t n = src.size(), i = 0;
  bool line_start = true, in_pp = false;
  string last_ident;  // previous identifier when only whitespace separates it from here
  auto ident_at = [&](size_t p, size_t& end) {
    while (p < n && (src[p] == ' ' || src[p] == '\t' || src[p] == '\n' || src[p] == '\r')) ++p;
    size_t j = p;
    while (j < n && (isalnum(static_cast<unsigned char>(src[j])) || src[j] == '_')) ++j;
    end = j;
    return j > p && !isdigit(static_cast<unsigned char>(src[p])) ? src.substr(p, j - p) : string();
  };
  while (i < n) {
    char c = src[i];
    if (c == '\n') {
      if (!(i > 0 && src[i - 1] == '\\')) in_pp = false;
      line_start = true; ++i; continue;
    }
    if (line_start) {
      if (c == ' ' || c == '\t') { ++i; continue; }
      if (c == '#') in_pp = true;
      line_start = false;
    }
    if (c == '/' && i + 1 < n && src[i + 1] == '/') { while (i < n && src[i] != '\n') ++i; continue; }
    if (c == '/' && i + 1 < n && src[i + 1] == '*') {
      i += 2;
      while (i + 1 < n && !(src[i] == '*' && src[i + 1] == '/')) ++i;
      i = std::min(n, i + 2);
      continue;
    }
    if (c == '"' || c == '\'') {
      char q = c; ++i;
      while (i < n && src[i] != q && src[i] != '\n') { if (src[i] == '\\') ++i; ++i; }
      ++i; last_ident.clear(); continue;
    }
    if (isalpha(static_cast<unsigned char>(c)) || c == '_') {
      size_t j = i;
      while (j < n && (isalnum(static_cast<unsigned char>(src[j])) || src[j] == '_')) ++j;
      string id = src.substr(i, j - i);
      if (!in_pp) {
        bool blank = user.count(id) > 0;
        bool caps = id.size() >= 3 && id.find_first_not_of("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_") == string::npos &&
                    isalpha(static_cast<unsigned char>(id[0]));
        if (!blank && caps) {
          size_t e1;
          string next = ident_at(j, e1);
          if (kLead.count(next)) blank = true;                      // EXPORT template<...> / EXPORT class X
          else if ((last_ident == "class" || last_ident == "struct" || last_ident == "union") && !next.empty() &&
                   !kLead.count(next)) {                            // class EXPORT Name [final] [:{]
            size_t p = e1;
            while (p < n && (src[p] == ' ' || src[p] == '\t' || src[p] == '\n' || src[p] == '\r')) ++p;
            if (p < n && (src[p] == '{' || (src[p] == ':' && !(p + 1 < n && src[p + 1] == ':')) ||
                          src.compare(p, 5, "final") == 0))
              blank = true;
          }
        }
        if (blank) for (size_t k = i; k < j; ++k) out[k] = ' ';
        else last_ident = id;
      }
      i = j; continue;
    }
    if (c != ' ' && c != '\t' && c != '\r') last_ident.clear();
    ++i;
  }
  return out;
}

bool is_header_path(const string& p) {
  static const char* exts[] = {".h", ".hh", ".hpp", ".hxx", ".h++", ".inl", ".ipp", ".tpp"};
  auto dot = p.rfind('.');
  if (dot == string::npos) return false;
  string e = p.substr(dot);
  for (auto& ch : e) ch = static_cast<char>(tolower(static_cast<unsigned char>(ch)));
  for (auto* x : exts) if (e == x) return true;
  return false;
}

Parser::Parser() : p_(ts_parser_new()) { ts_parser_set_language(p_, tree_sitter_cpp()); }
Parser::~Parser() { ts_parser_delete(p_); }

std::string dump_ast(const std::string& text) {
  TSParser* p = ts_parser_new();
  ts_parser_set_language(p, tree_sitter_cpp());
  TSTree* t = ts_parser_parse_string(p, nullptr, text.data(), static_cast<uint32_t>(text.size()));
  std::string out;
  std::function<void(TSNode, const char*, int)> rec = [&](TSNode n, const char* fname, int d) {
    if (!ts_node_is_named(n)) return;
    out += std::string(static_cast<size_t>(d) * 2, ' ');
    if (fname) out += std::string(fname) + ": ";
    out += ts_node_type(n);
    if (ts_node_child_count(n) == 0) out += " '" + text.substr(ts_node_start_byte(n), ts_node_end_byte(n) - ts_node_start_byte(n)) + "'";
    out += "\n";
    TSTreeCursor cur = ts_tree_cursor_new(n);
    if (ts_tree_cursor_goto_first_child(&cur)) {
      do { rec(ts_tree_cursor_current_node(&cur), ts_tree_cursor_current_field_name(&cur), d + 1); }
      while (ts_tree_cursor_goto_next_sibling(&cur));
    }
    ts_tree_cursor_delete(&cur);
  };
  rec(ts_tree_root_node(t), nullptr, 0);
  ts_tree_delete(t);
  ts_parser_delete(p);
  return out;
}

void Parser::parse_into(Side& side, const string& file, const string& text) {
  if (text.empty()) return;
  string src = blank_macros(text, macros_);
  TSTree* tree = ts_parser_parse_string(p_, nullptr, src.data(), static_cast<uint32_t>(src.size()));
  if (!tree) return;
  Extractor ex(side, file, src, internal_ns_);
  ex.run(ts_tree_root_node(tree));
  ts_tree_delete(tree);
}

void finalize(Side& side, const std::set<string>& classes, const std::set<string>& namespaces) {
  auto fix = [&](std::optional<Symbol>& so) {
    if (!so || so->kind != Kind::Function || !so->qualified_def || so->scope.empty()) return;
    string sc = join(so->scope, "::");
    if (classes.count(sc)) so->kind = Kind::Method;
    else if (namespaces.count(sc)) so->kind = Kind::Function;
    else if (isupper(static_cast<unsigned char>(so->scope.back()[0]))) so->kind = Kind::Method;
  };
  for (auto& [k, e] : side.ents) { fix(e.decl); fix(e.def); }
}

}  // namespace cppdiff
