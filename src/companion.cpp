#include "companion.hpp"

#include <algorithm>
#include <sstream>

namespace cppdiff {
namespace {

std::string dir_of(const std::string& p) {
  auto s = p.rfind('/');
  return s == std::string::npos ? "" : p.substr(0, s);
}
std::string base_of(const std::string& p) {
  auto s = p.rfind('/');
  return s == std::string::npos ? p : p.substr(s + 1);
}
std::string stem_of(const std::string& p) {
  std::string b = base_of(p);
  auto d = b.rfind('.');
  return d == std::string::npos ? b : b.substr(0, d);
}
size_t common_dir_prefix(const std::string& a, const std::string& b) {
  size_t n = 0, i = 0;
  while (i < a.size() && i < b.size() && a[i] == b[i]) { if (a[i] == '/') n = i + 1; ++i; }
  return n;
}

}  // namespace

std::vector<std::string> find_companions(const std::string& src, const std::string& text,
                                         const std::set<std::string>& repo_headers,
                                         const std::multimap<std::string, std::string>& by_basename,
                                         const std::set<std::string>& exclude) {
  std::set<std::string> out;
  const std::string stem = stem_of(src), dir = dir_of(src);

  // 1. same directory, same stem
  for (const char* ext : {".h", ".hh", ".hpp", ".hxx", ".h++"}) {
    std::string cand = (dir.empty() ? "" : dir + "/") + stem + ext;
    if (repo_headers.count(cand)) out.insert(cand);
  }

  // 2. quoted includes: the one with the same stem, and the first one
  std::istringstream in(text);
  std::string line;
  bool first = true;
  while (std::getline(in, line)) {
    size_t i = line.find_first_not_of(" \t");
    if (i == std::string::npos || line[i] != '#') continue;
    i = line.find_first_not_of(" \t", i + 1);
    if (i == std::string::npos || line.compare(i, 7, "include") != 0) continue;
    auto q1 = line.find('"', i);
    if (q1 == std::string::npos) continue;  // <system> include
    auto q2 = line.find('"', q1 + 1);
    if (q2 == std::string::npos) continue;
    std::string inc = line.substr(q1 + 1, q2 - q1 - 1);
    bool wanted = first || stem_of(inc) == stem;
    first = false;
    if (!wanted) continue;
    std::string best;
    size_t best_score = 0;
    auto range = by_basename.equal_range(base_of(inc));
    for (auto it = range.first; it != range.second; ++it) {
      const std::string& cand = it->second;
      bool suffix = cand == inc || (cand.size() > inc.size() && cand.compare(cand.size() - inc.size(), inc.size(), inc) == 0 &&
                                    cand[cand.size() - inc.size() - 1] == '/');
      if (!suffix) continue;
      size_t score = common_dir_prefix(cand, src) + 1;
      if (score > best_score) { best_score = score; best = cand; }
    }
    if (!best.empty()) out.insert(best);
  }

  // 3. fallback: a single header with the same stem anywhere
  if (out.empty()) {
    std::vector<std::string> same;
    for (auto& h : repo_headers) if (stem_of(h) == stem) same.push_back(h);
    if (same.size() == 1) out.insert(same[0]);
  }
  std::vector<std::string> res;
  for (auto& c : out) if (!exclude.count(c)) res.push_back(c);
  return res;
}

}  // namespace cppdiff
