#pragma once
#include <optional>
#include <set>
#include <string>
#include <vector>

namespace cppdiff {

// Per-repository settings from `.gitcppdiff` (repo root). Line based, `#` comments:
//   macro MYLIB_EXPORT MYLIB_DEPRECATED   blank these identifiers before parsing
//   ignore third_party/ **/*_generated.*  skip these files entirely (gitignore-like globs)
//   public include/** api/**              only headers matching these count as public API
//   internal-namespace detail internal    contents of these namespaces are never public API
//   all-api true|false                    treat every symbol as API
struct ProjectConfig {
  std::set<std::string> macros, internal_ns;
  std::vector<std::string> ignore, public_globs;
  std::optional<bool> all_api;
  std::vector<std::string> warnings;
  std::string path;  // file that was read, empty if none
};

ProjectConfig load_project_config(const std::string& file);

// gitignore-like: `*` `?` stay inside one path segment, `**` crosses `/`, a pattern without
// `/` matches at any depth, a trailing `/` matches a directory subtree.
bool glob_match(const std::string& pattern, const std::string& path);
bool matches_any(const std::vector<std::string>& patterns, const std::string& path);

}  // namespace cppdiff
