#include "projconfig.hpp"

#include <fstream>
#include <sstream>

namespace cppdiff {
namespace {

bool gm(const char* p, const char* s, const char* s0) {
  while (*p) {
    if (p[0] == '*' && p[1] == '*') {
      p += 2;
      bool dir = *p == '/';
      if (dir) ++p;
      for (const char* q = s;; ++q) {
        if ((!dir || q == s0 || q[-1] == '/') && gm(p, q, s0)) return true;
        if (!*q) break;
      }
      return false;
    }
    if (*p == '*') {
      ++p;
      for (const char* q = s;; ++q) {
        if (gm(p, q, s0)) return true;
        if (!*q || *q == '/') break;
      }
      return false;
    }
    if (*p == '?') {
      if (!*s || *s == '/') return false;
      ++p; ++s;
      continue;
    }
    if (*p != *s) return false;
    ++p; ++s;
  }
  return !*s;
}

}  // namespace

bool glob_match(const std::string& pattern, const std::string& path) {
  std::string p = pattern;
  if (!p.empty() && p[0] == '/') p.erase(0, 1);                       // anchored at repo root
  else if (p.find('/') == std::string::npos || p.find('/') == p.size() - 1) p = "**/" + p;  // any depth
  if (!p.empty() && p.back() == '/') p += "**";
  return gm(p.c_str(), path.c_str(), path.c_str()) || gm((p + "/**").c_str(), path.c_str(), path.c_str());
}

bool matches_any(const std::vector<std::string>& patterns, const std::string& path) {
  for (auto& p : patterns) if (glob_match(p, path)) return true;
  return false;
}

ProjectConfig load_project_config(const std::string& file) {
  ProjectConfig c;
  std::ifstream in(file);
  if (!in) return c;
  c.path = file;
  std::string line;
  int n = 0;
  while (std::getline(in, line)) {
    ++n;
    auto hash = line.find('#');
    if (hash != std::string::npos) line.erase(hash);
    std::istringstream ss(line);
    std::string key;
    if (!(ss >> key)) continue;
    std::vector<std::string> args;
    for (std::string a; ss >> a;) args.push_back(a);
    auto warn = [&](const std::string& m) { c.warnings.push_back(file + ":" + std::to_string(n) + ": " + m); };
    if (key == "macro") c.macros.insert(args.begin(), args.end());
    else if (key == "ignore") c.ignore.insert(c.ignore.end(), args.begin(), args.end());
    else if (key == "public") c.public_globs.insert(c.public_globs.end(), args.begin(), args.end());
    else if (key == "internal-namespace") c.internal_ns.insert(args.begin(), args.end());
    else if (key == "all-api") {
      if (args.size() == 1 && (args[0] == "true" || args[0] == "false")) c.all_api = args[0] == "true";
      else warn("all-api expects true or false");
    } else warn("unknown directive '" + key + "'");
    if (args.empty() && key != "" && key != "all-api" &&
        (key == "macro" || key == "ignore" || key == "public" || key == "internal-namespace"))
      warn("'" + key + "' needs at least one argument");
  }
  return c;
}

}  // namespace cppdiff
