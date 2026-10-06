#include "git.hpp"

#include <cstdio>
#include <fstream>
#include <sstream>

namespace cppdiff {
namespace {

std::string shq(const std::string& s) {
  std::string o = "'";
  for (char c : s) { if (c == '\'') o += "'\\''"; else o += c; }
  return o + "'";
}

std::string sh(const std::string& cmd, bool* ok) {
  FILE* p = popen((cmd + " 2>/dev/null").c_str(), "r");
  if (!p) { if (ok) *ok = false; return {}; }
  std::string out;
  char buf[1 << 16];
  size_t n;
  while ((n = fread(buf, 1, sizeof buf, p)) > 0) out.append(buf, n);
  int rc = pclose(p);
  if (ok) *ok = (rc == 0);
  return out;
}

std::vector<std::string> split_nul(const std::string& s) {
  std::vector<std::string> v;
  size_t i = 0;
  while (i < s.size()) {
    size_t j = s.find('\0', i);
    if (j == std::string::npos) j = s.size();
    v.push_back(s.substr(i, j - i));
    i = j + 1;
  }
  return v;
}

bool cpp_path(const std::string& p) {
  static const char* exts[] = {".h", ".hh", ".hpp", ".hxx", ".h++", ".cc", ".cpp", ".cxx",
                               ".c++", ".inl", ".ipp", ".tpp", ".ixx", ".cppm"};
  auto dot = p.rfind('.');
  if (dot == std::string::npos) return false;
  std::string e = p.substr(dot);
  for (auto& c : e) c = static_cast<char>(tolower(static_cast<unsigned char>(c)));
  for (auto* x : exts) if (e == x) return true;
  return false;
}

}  // namespace

std::string Git::run(const std::vector<std::string>& args, bool* ok) const {
  std::string cmd = "git";
  if (!root_.empty()) cmd += " -C " + shq(root_);
  for (auto& a : args) cmd += " " + shq(a);
  return sh(cmd, ok);
}

std::optional<Git> Git::open(const std::string& dir) {
  bool ok = false;
  std::string cmd = "git -C " + shq(dir.empty() ? "." : dir) + " rev-parse --show-toplevel";
  std::string r = sh(cmd, &ok);
  while (!r.empty() && (r.back() == '\n' || r.back() == '\r')) r.pop_back();
  if (!ok || r.empty()) return std::nullopt;
  Git g;
  g.root_ = r;
  return g;
}

std::optional<Spec> Git::make_spec(const std::vector<std::string>& pos, bool staged, std::string& err) const {
  Spec s;
  auto trim = [](std::string v) { while (!v.empty() && v.back() == '\n') v.pop_back(); return v; };
  if (pos.empty()) {
    s.base = "HEAD";
  } else if (pos.size() == 1) {
    const std::string& a = pos[0];
    auto d3 = a.find("...");
    auto d2 = a.find("..");
    if (d3 != std::string::npos) {
      std::string l = a.substr(0, d3), r = a.substr(d3 + 3);
      if (l.empty()) l = "HEAD";
      if (r.empty()) r = "HEAD";
      bool ok = false;
      std::string mb = trim(run({"merge-base", l, r}, &ok));
      if (!ok || mb.empty()) { err = "no merge base for " + a; return std::nullopt; }
      s.base = mb; s.head = r; s.head_kind = HeadKind::Rev;
      s.label = l + "..." + r;
    } else if (d2 != std::string::npos) {
      s.base = a.substr(0, d2); s.head = a.substr(d2 + 2);
      if (s.base.empty()) s.base = "HEAD";
      if (s.head.empty()) s.head = "HEAD";
      s.head_kind = HeadKind::Rev;
      s.label = s.base + ".." + s.head;
    } else {
      s.base = a;
    }
  } else if (pos.size() == 2) {
    s.base = pos[0]; s.head = pos[1]; s.head_kind = HeadKind::Rev;
  } else {
    err = "too many revisions"; return std::nullopt;
  }
  if (s.head_kind != HeadKind::Rev) s.head_kind = staged ? HeadKind::Index : HeadKind::Worktree;
  if (s.label.empty())
    s.label = s.base + " → " + (s.head_kind == HeadKind::Rev ? s.head
                                : s.head_kind == HeadKind::Index ? "index" : "worktree");
  bool ok = false;
  run({"rev-parse", "--verify", "--quiet", s.base + "^{commit}"}, &ok);
  if (!ok) { err = "unknown revision '" + s.base + "'"; return std::nullopt; }
  if (s.head_kind == HeadKind::Rev) {
    run({"rev-parse", "--verify", "--quiet", s.head + "^{commit}"}, &ok);
    if (!ok) { err = "unknown revision '" + s.head + "'"; return std::nullopt; }
  }
  return s;
}

std::vector<FileChange> Git::changes(const Spec& s, const std::vector<std::string>& pathspecs) const {
  std::vector<std::string> a = {"diff", "-z", "--name-status", "-M", "--no-color"};
  if (s.head_kind == HeadKind::Index) a.push_back("--cached");
  a.push_back(s.base);
  if (s.head_kind == HeadKind::Rev) a.push_back(s.head);
  if (!pathspecs.empty()) { a.push_back("--"); for (auto& p : pathspecs) a.push_back(p); }

  std::vector<FileChange> out;
  auto t = split_nul(run(a));
  for (size_t i = 0; i < t.size();) {
    FileChange fc;
    const std::string& st = t[i++];
    if (st.empty()) continue;
    fc.status = st[0];
    if ((fc.status == 'R' || fc.status == 'C') && i + 1 < t.size()) {
      fc.old_path = t[i++]; fc.new_path = t[i++];
      fc.status = 'R';
    } else if (i < t.size()) {
      fc.old_path = fc.new_path = t[i++];
    } else break;
    if (!cpp_path(fc.old_path) && !cpp_path(fc.new_path)) continue;
    out.push_back(fc);
  }
  if (s.head_kind == HeadKind::Worktree) {  // untracked files count as added
    std::vector<std::string> u = {"ls-files", "-z", "--others", "--exclude-standard"};
    if (!pathspecs.empty()) { u.push_back("--"); for (auto& p : pathspecs) u.push_back(p); }
    for (auto& p : split_nul(run(u)))
      if (!p.empty() && cpp_path(p)) out.push_back({'A', p, p});
  }
  return out;
}

std::vector<std::string> Git::list_headers(const Spec& s) const {
  static const char* exts[] = {".h", ".hh", ".hpp", ".hxx", ".h++"};
  std::string out;
  if (s.head_kind == HeadKind::Rev) out = run({"ls-tree", "-r", "--name-only", "-z", s.head});
  else if (s.head_kind == HeadKind::Index) out = run({"ls-files", "-z"});
  else out = run({"ls-files", "-z", "--cached", "--others", "--exclude-standard"});
  std::vector<std::string> res;
  for (auto& p : split_nul(out)) {
    auto dot = p.rfind('.');
    if (dot == std::string::npos) continue;
    std::string e = p.substr(dot);
    for (auto& c : e) c = static_cast<char>(tolower(static_cast<unsigned char>(c)));
    for (auto* x : exts) if (e == x) { res.push_back(p); break; }
  }
  return res;
}

std::string Git::read_old(const Spec& s, const std::string& path) const {
  return run({"show", s.base + ":" + path});
}

std::string Git::read_new(const Spec& s, const std::string& path) const {
  switch (s.head_kind) {
    case HeadKind::Rev: return run({"show", s.head + ":" + path});
    case HeadKind::Index: return run({"show", ":" + path});
    case HeadKind::Worktree: {
      std::ifstream f(root_ + "/" + path, std::ios::binary);
      std::stringstream ss;
      ss << f.rdbuf();
      return ss.str();
    }
  }
  return {};
}

}  // namespace cppdiff
