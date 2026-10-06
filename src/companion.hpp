#pragma once
#include <map>
#include <set>
#include <string>
#include <vector>

namespace cppdiff {

// Headers that belong to a source file (same stem next to it, or the `#include "…"` of
// the same stem / first quoted include). They give access specifiers and declarations for
// out-of-class definitions when only the .cpp changed. Paths in `exclude` are skipped.
std::vector<std::string> find_companions(const std::string& src_path, const std::string& src_text,
                                         const std::set<std::string>& repo_headers,
                                         const std::multimap<std::string, std::string>& by_basename,
                                         const std::set<std::string>& exclude);

}  // namespace cppdiff
