#include <cstdio>
#include <map>
#include "render.hpp"

namespace cppdiff {
namespace {

std::string esc(const std::string& s) {
  std::string o = "\"";
  for (unsigned char c : s) {
    switch (c) {
      case '"': o += "\\\""; break;
      case '\\': o += "\\\\"; break;
      case '\n': o += "\\n"; break;
      case '\r': o += "\\r"; break;
      case '\t': o += "\\t"; break;
      default:
        if (c < 0x20) { char b[8]; std::snprintf(b, sizeof b, "\\u%04x", c); o += b; }
        else o += static_cast<char>(c);
    }
  }
  return o + "\"";
}

const char* access_name(Access a) {
  switch (a) {
    case Access::Public: return "public";
    case Access::Protected: return "protected";
    case Access::Private: return "private";
    default: return "";
  }
}

std::string side(const Entity* e) {
  if (!e) return "null";
  const Symbol& s = e->primary();
  std::string o = "{\"file\":" + esc(s.file) + ",\"line\":" + std::to_string(s.line) +
                  ",\"end_line\":" + std::to_string(s.end_line) + ",\"signature\":" + esc(s.sig);
  if (e->def && e->decl && e->def->file != e->decl->file)
    o += ",\"definition\":{\"file\":" + esc(e->def->file) + ",\"line\":" + std::to_string(e->def->line) +
         ",\"end_line\":" + std::to_string(e->def->end_line) + "}";
  return o + "}";
}

std::string change_id(const Change& c) {
  uint64_t h = kFnvBasis;
  auto mix = [&](const std::string& x) { h = fnv(h, x); };
  mix(c.old_e ? c.old_e->primary().key : "");
  mix(c.new_e ? c.new_e->primary().key : "");
  mix(status_name(c.status));
  mix(c.old_e ? c.old_e->primary().sig : "");
  mix(c.new_e ? c.new_e->primary().sig : "");
  mix(std::to_string(c.old_e ? c.old_e->body_hash() : 0));
  mix(std::to_string(c.new_e ? c.new_e->body_hash() : 0));
  char b[24];
  std::snprintf(b, sizeof b, "%016llx", static_cast<unsigned long long>(h));
  return b;
}

}  // namespace

std::string render_json(const DiffResult& r, const RenderOptions& o) {
  std::map<std::string, int> cnt;
  for (auto& c : r.changes) cnt[status_name(c.status)]++;
  std::string j = "{\n  \"schema\": 2,\n  \"range\": " + esc(o.label) + ",\n  \"root\": " + esc(o.repo_root) +
                  ",\n  \"base_rev\": " + esc(o.base_rev) + ",\n  \"head_rev\": " + esc(o.head_rev) +
                  ",\n  \"head_kind\": " + esc(o.head_kind) + ",\n  \"files_scanned\": " +
                  std::to_string(o.files_scanned) + ",\n  \"summary\": {";
  bool first = true;
  for (auto s : {Status::Added, Status::Removed, Status::Modified, Status::ApiChange, Status::Renamed}) {
    j += std::string(first ? "" : ", ") + esc(status_name(s)) + ": " + std::to_string(cnt[status_name(s)]);
    first = false;
  }
  j += "},\n  \"changes\": [";
  for (size_t i = 0; i < r.changes.size(); ++i) {
    const Change& c = r.changes[i];
    j += i ? ",\n    " : "\n    ";
    j += "{\"id\":" + esc(change_id(c)) + ",\"status\":" + esc(status_name(c.status)) + ",\"kind\":" + esc(kind_name(c.kind)) +
         ",\"qualified_name\":" + esc(c.qualified) + ",\"name\":" + esc(c.name) + ",\"label\":" + esc(c.sym().label) + ",\"scope\":[" + [&] {
           std::string a;
           for (size_t k = 0; k < c.scope.size(); ++k) a += (k ? "," : "") + esc(c.scope[k]);
           return a;
         }() + "]" +
         ",\"access\":" + esc(access_name(c.sym().access)) + ",\"api\":" + (c.api ? "true" : "false") +
         ",\"file\":" + esc(c.file) + ",\"line\":" + std::to_string(c.line) + ",\"reasons\":[";
    for (size_t k = 0; k < c.reasons.size(); ++k) j += (k ? "," : "") + esc(c.reasons[k]);
    j += "],\"old\":" + side(c.old_e) + ",\"new\":" + side(c.new_e) + "}";
  }
  j += r.changes.empty() ? "]\n}\n" : "\n  ]\n}\n";
  return j;
}

}  // namespace cppdiff
