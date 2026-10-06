#include "diff.hpp"

#include <algorithm>
#include <map>
#include "projconfig.hpp"
#include <tuple>

namespace cppdiff {
namespace {

using std::string;
using std::vector;

bool public_header(const Entity& e, const ApiPolicy& pol) {
  auto ok = [&](const std::optional<Symbol>& s) {
    return s && s->is_header && (pol.public_globs.empty() || matches_any(pol.public_globs, s->file));
  };
  return ok(e.decl) || ok(e.def);
}

bool is_api(const Entity& e, const ApiPolicy& pol) {
  if (pol.all) return true;
  const Symbol& p = e.primary();
  if (p.internal && p.access != Access::Unknown) return false;   // detail:: / anonymous namespace
  switch (p.access) {
    case Access::Private: return false;
    case Access::Public:
    case Access::Protected: return public_header(e, pol);
    case Access::Unknown: return !p.internal;
    case Access::None: return public_header(e, pol) && !p.internal;
  }
  return false;
}

string or_none(const string& s) { return s.empty() ? "∅" : s; }

vector<string> split_us(const string& s) {
  vector<string> v;
  size_t i = 0;
  while (i <= s.size()) {
    size_t j = s.find('\x1f', i);
    if (j == string::npos) j = s.size();
    if (j > i) v.push_back(s.substr(i, j - i));
    i = j + 1;
  }
  return v;
}

vector<string> facet_reasons(const Facets& a, const Facets& b) {
  std::map<string, string> ma, mb;
  vector<string> order;
  for (auto& [k, v] : a) { ma[k] = v; order.push_back(k); }
  for (auto& [k, v] : b) { mb[k] = v; if (!ma.count(k)) order.push_back(k); }
  vector<string> out;
  for (auto& k : order) {
    string x = ma.count(k) ? ma[k] : "", y = mb.count(k) ? mb[k] : "";
    if (x == y) continue;
    if (k == "enumerators") {
      auto xs = split_us(x), ys = split_us(y);
      string d;
      for (auto& e : ys) if (std::find(xs.begin(), xs.end(), e) == xs.end()) d += (d.empty() ? "" : ", ") + string("+") + e;
      for (auto& e : xs) if (std::find(ys.begin(), ys.end(), e) == ys.end()) d += (d.empty() ? "" : ", ") + string("-") + e;
      out.push_back("enumerators: " + d);
    } else {
      out.push_back(k + ": " + or_none(x) + " → " + or_none(y));
    }
  }
  return out;
}

double jaccard(const vector<uint64_t>& a, const vector<uint64_t>& b) {
  if (a.empty() && b.empty()) return 0.5;
  size_t i = 0, j = 0, inter = 0;
  while (i < a.size() && j < b.size()) {
    if (a[i] == b[j]) { ++inter; ++i; ++j; }
    else if (a[i] < b[j]) ++i; else ++j;
  }
  size_t uni = a.size() + b.size() - inter;
  return uni ? static_cast<double>(inter) / static_cast<double>(uni) : 0.0;
}

const vector<uint64_t>& grams_of(const Entity& e) {
  static const vector<uint64_t> empty;
  return e.def ? e.def->grams : empty;
}

void finish(Change& c, const ApiPolicy& pol) {
  const Entity& e = c.new_e ? *c.new_e : *c.old_e;
  const Symbol& s = e.primary();
  c.kind = s.kind;
  c.qualified = s.qualified();
  c.name = s.name;
  c.scope = s.scope;
  c.file = s.file;
  c.line = s.line;
  c.api = (c.old_e && is_api(*c.old_e, pol)) || (c.new_e && is_api(*c.new_e, pol));
}

string body_reason(const Entity& o, const Entity& n) {
  if (o.def && n.def) return o.def->body_hash != n.def->body_hash ? "body changed" : "";
  if (!o.def && n.def) return "definition added";
  if (o.def && !n.def) return "definition removed";
  return "";
}

}  // namespace

const char* status_name(Status s) {
  switch (s) {
    case Status::Added: return "added";
    case Status::Removed: return "removed";
    case Status::Modified: return "modified";
    case Status::ApiChange: return "api-change";
    case Status::Renamed: return "renamed";
  }
  return "";
}

const char* kind_name(Kind k) {
  switch (k) {
    case Kind::Namespace: return "namespace";
    case Kind::Class: return "class";
    case Kind::Struct: return "struct";
    case Kind::Union: return "union";
    case Kind::Enum: return "enum";
    case Kind::Function: return "function";
    case Kind::Method: return "method";
    case Kind::Constructor: return "constructor";
    case Kind::Destructor: return "destructor";
    case Kind::Operator: return "operator";
    case Kind::Field: return "field";
    case Kind::Alias: return "alias";
  }
  return "";
}

DiffResult diff(const Side& o, const Side& n, const ApiPolicy& pol) {
  DiffResult r;
  r.type_scopes = o.classes;
  r.type_scopes.insert(n.classes.begin(), n.classes.end());

  vector<const Entity*> removed, added;

  // 1. identical keys
  for (auto& [key, ne] : n.ents) {
    auto it = o.ents.find(key);
    if (it == o.ents.end()) { added.push_back(&ne); continue; }
    const Entity& oe = it->second;
    auto reasons = facet_reasons(oe.primary().facets, ne.primary().facets);
    string br = body_reason(oe, ne);
    if (reasons.empty() && br.empty()) continue;
    Change c;
    c.old_e = &oe; c.new_e = &ne;
    finish(c, pol);
    bool sig = !reasons.empty();
    if (!sig && ne.def) { c.file = ne.def->file; c.line = ne.def->line; }  // body-only: point at the code
    c.status = sig && c.api ? Status::ApiChange : Status::Modified;
    c.reasons = reasons;
    if (sig && !c.api) for (auto& x : c.reasons) x += " (internal)";
    if (!br.empty()) c.reasons.push_back(br);
    r.changes.push_back(std::move(c));
  }
  for (auto& [key, oe] : o.ents) if (!n.ents.count(key)) removed.push_back(&oe);

  auto pair_up = [&](const Entity* oe, const Entity* ne, Status forced, bool rename) {
    Change c;
    c.old_e = oe; c.new_e = ne;
    finish(c, pol);
    c.reasons = facet_reasons(oe->primary().facets, ne->primary().facets);
    string br = body_reason(*oe, *ne);
    if (!br.empty()) c.reasons.push_back(br);
    if (rename) {
      const Symbol& a = oe->primary();
      const Symbol& b = ne->primary();
      if (a.scope == b.scope) c.reasons.insert(c.reasons.begin(), "renamed: " + a.name + " → " + b.name);
      else c.reasons.insert(c.reasons.begin(), "moved: " + a.qualified() + " → " + b.qualified());
      c.status = Status::Renamed;
    } else {
      c.status = c.api ? forced : Status::Modified;
      if (!c.api) for (auto& x : c.reasons) if (x != "body changed") x += " (internal)";
    }
    r.changes.push_back(std::move(c));
  };

  // 2. renames / moves: identical, non-trivial body, unique on both sides
  {
    std::map<uint64_t, vector<size_t>> rm, ad;
    for (size_t i = 0; i < removed.size(); ++i)
      if (removed[i]->def && removed[i]->def->body_len >= 8 && is_func_kind(removed[i]->primary().kind))
        rm[removed[i]->def->body_hash].push_back(i);
    for (size_t i = 0; i < added.size(); ++i)
      if (added[i]->def && added[i]->def->body_len >= 8 && is_func_kind(added[i]->primary().kind))
        ad[added[i]->def->body_hash].push_back(i);
    std::set<size_t> dr, da;
    for (auto& [h, rv] : rm) {
      auto it = ad.find(h);
      if (it == ad.end() || rv.size() != 1 || it->second.size() != 1) continue;
      if (removed[rv[0]]->primary().qualified() == added[it->second[0]]->primary().qualified())
        continue;  // same name: an overload/signature change, handled below
      pair_up(removed[rv[0]], added[it->second[0]], Status::Renamed, true);
      dr.insert(rv[0]); da.insert(it->second[0]);
    }
    vector<const Entity*> r2, a2;
    for (size_t i = 0; i < removed.size(); ++i) if (!dr.count(i)) r2.push_back(removed[i]);
    for (size_t i = 0; i < added.size(); ++i) if (!da.count(i)) a2.push_back(added[i]);
    removed.swap(r2); added.swap(a2);
  }

  // 3. same scope::name, different signature (overload set changed)
  {
    auto gk = [](const Entity* e) { const Symbol& s = e->primary(); return join(s.scope, "::") + "|" + s.name; };
    std::map<string, vector<size_t>> rg, ag;
    for (size_t i = 0; i < removed.size(); ++i) if (is_func_kind(removed[i]->primary().kind)) rg[gk(removed[i])].push_back(i);
    for (size_t i = 0; i < added.size(); ++i) if (is_func_kind(added[i]->primary().kind)) ag[gk(added[i])].push_back(i);
    std::set<size_t> dr, da;
    for (auto& [k, rv] : rg) {
      auto it = ag.find(k);
      if (it == ag.end()) continue;
      auto& av = it->second;
      if (rv.size() == 1 && av.size() == 1) {
        pair_up(removed[rv[0]], added[av[0]], Status::ApiChange, false);
        dr.insert(rv[0]); da.insert(av[0]);
        continue;
      }
      struct Cand { double s; size_t r, a; };
      vector<Cand> cands;
      for (auto ri : rv) for (auto ai : av)
        cands.push_back({jaccard(grams_of(*removed[ri]), grams_of(*added[ai])), ri, ai});
      std::sort(cands.begin(), cands.end(), [](const Cand& x, const Cand& y) { return x.s > y.s; });
      for (auto& cd : cands) {
        if (cd.s < 0.5 || dr.count(cd.r) || da.count(cd.a)) continue;
        pair_up(removed[cd.r], added[cd.a], Status::ApiChange, false);
        dr.insert(cd.r); da.insert(cd.a);
      }
    }
    vector<const Entity*> r2, a2;
    for (size_t i = 0; i < removed.size(); ++i) if (!dr.count(i)) r2.push_back(removed[i]);
    for (size_t i = 0; i < added.size(); ++i) if (!da.count(i)) a2.push_back(added[i]);
    removed.swap(r2); added.swap(a2);
  }

  // 4. what is left is plainly added / removed
  for (auto* e : removed) {
    Change c; c.old_e = e; c.status = Status::Removed; finish(c, pol);
    r.changes.push_back(std::move(c));
  }
  for (auto* e : added) {
    Change c; c.new_e = e; c.status = Status::Added; finish(c, pol);
    r.changes.push_back(std::move(c));
  }

  std::sort(r.changes.begin(), r.changes.end(), [](const Change& a, const Change& b) {
    return std::tie(a.file, a.line, a.qualified) < std::tie(b.file, b.line, b.qualified);
  });
  return r;
}

}  // namespace cppdiff
