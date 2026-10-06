// Core data model shared by parser, differ and renderers.
#pragma once
#include <algorithm>
#include <cstdint>
#include <map>
#include <optional>
#include <set>
#include <string>
#include <vector>

namespace cppdiff {

enum class Kind { Namespace, Class, Struct, Union, Enum, Function, Method,
                  Constructor, Destructor, Operator, Field, Alias };
enum class Access { None, Public, Protected, Private, Unknown };
using Facets = std::vector<std::pair<std::string, std::string>>;

constexpr uint64_t kFnvBasis = 1469598103934665603ULL;
inline uint64_t fnv(uint64_t h, const std::string& s) {
  for (unsigned char c : s) { h ^= c; h *= 1099511628211ULL; }
  h ^= 0xff; h *= 1099511628211ULL;
  return h;
}

inline std::string join(const std::vector<std::string>& v, const std::string& sep) {
  std::string o;
  for (size_t i = 0; i < v.size(); ++i) { if (i) o += sep; o += v[i]; }
  return o;
}

inline bool is_type_kind(Kind k) {
  return k == Kind::Class || k == Kind::Struct || k == Kind::Union || k == Kind::Enum;
}
inline bool is_func_kind(Kind k) {
  return k == Kind::Function || k == Kind::Method || k == Kind::Constructor ||
         k == Kind::Destructor || k == Kind::Operator;
}

struct Symbol {
  std::string key;                 // identity across revisions
  Kind kind = Kind::Function;
  Access access = Access::None;
  std::vector<std::string> scope;  // enclosing namespaces / classes
  std::string name;                // unqualified
  std::string label;               // short display, e.g. "resize(int, int) const"
  std::string sig;                 // full display signature
  Facets facets;                   // API-relevant parts (compared by label)
  std::string file;
  int line = 0, end_line = 0;
  bool is_def = false;             // has a body / initializer
  bool inline_def = false;         // declared and defined in one place (in-class)
  bool is_header = false;
  bool qualified_def = false;      // out-of-class `A::b` definition
  bool internal = false;           // static or in anonymous namespace
  uint64_t body_hash = 0;
  size_t body_len = 0;
  std::vector<uint64_t> grams;     // sorted unique token bigrams (similarity)

  std::string qualified() const {
    std::string q = join(scope, "::");
    if (!q.empty()) q += "::";
    return q + name;
  }
};

// A symbol as seen across all parsed files of one revision:
// header declaration + source definition are merged into one entity.
struct Entity {
  std::optional<Symbol> decl, def;
  const Symbol& primary() const { return decl ? *decl : *def; }
  Symbol& primary() { return decl ? *decl : *def; }
  uint64_t body_hash() const { return def ? def->body_hash : 0; }
  bool header_any() const { return (decl && decl->is_header) || (def && def->is_header); }
};

struct Side {
  std::map<std::string, Entity> ents;
  std::set<std::string> classes, namespaces;
  int errors = 0;

  void add(Symbol s) {
    Entity& e = ents[s.key];
    if (s.is_def) {
      if (!e.def) {
        e.def = s;
      } else {  // e.g. #if/#else branches defining the same symbol
        e.def->body_hash = e.def->body_hash * 1099511628211ULL ^ s.body_hash;
        e.def->body_len += s.body_len;
        e.def->grams.insert(e.def->grams.end(), s.grams.begin(), s.grams.end());
        std::sort(e.def->grams.begin(), e.def->grams.end());
        e.def->grams.erase(std::unique(e.def->grams.begin(), e.def->grams.end()), e.def->grams.end());
      }
      if (s.inline_def && !e.decl) e.decl = s;
    } else if (!e.decl) {
      e.decl = s;
    }
  }
};

}  // namespace cppdiff
