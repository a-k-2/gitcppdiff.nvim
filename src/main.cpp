#include <sys/ioctl.h>
#include <unistd.h>

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <fstream>
#include <map>
#include <set>
#include <sstream>

#include "companion.hpp"
#include "diff.hpp"
#include "projconfig.hpp"
#include "git.hpp"
#include "parse.hpp"
#include "render.hpp"

using namespace cppdiff;

namespace {

const char* kHelp = R"(gitcppdiff — semantic git diff for C++: which classes / methods changed, and did the API?

USAGE
  gitcppdiff [options] [<rev> | <rev>..<rev> | <rev>...<rev> | <rev> <rev>] [-- <path>...]

  (no revision)      HEAD vs. working tree (untracked C++ files count as added)
  --staged           HEAD vs. index
  A..B / A B         A vs. B          A...B   merge-base(A,B) vs. B

OPTIONS
  --format <pretty|json>   output format (default: pretty)
  --color <auto|always|never>
  --no-icons               ASCII glyphs instead of Nerd Font icons
  --only <list>            comma list of: added,removed,modified,api,renamed
  --api-only               only changes that touch the public API surface
  --all-api                treat private / source-only symbols as API too
  --expand                 list every member of added/removed classes
  --macro <NAME>           blank an export/attribute macro before parsing (repeatable,
                           also GITCPPDIFF_MACROS=A,B). ALL_CAPS tokens before template/
                           class/struct/... are detected automatically
  --config <file>          project settings (default: <repo>/.gitcppdiff), --no-config to skip
  -C <dir>                 run as if started in <dir>
  --fail-on-api            exit 2 if any API change or API removal is found (CI)
  -v, --verbose            warn about unparsable regions
  -h, --help

Status legend:  added · removed · modified (body) · API change (signature, access,
bases, default args, enumerators ...) · renamed / moved
)";

struct Opts {
  std::string format = "pretty", color = "auto", dir = ".";
  bool icons = true, api_only = false, all_api = false, expand = false, fail_api = false,
       staged = false, verbose = false;
  std::set<std::string> only, macros;
  std::string config_file;
  bool no_config = false;
  std::vector<std::string> pos, paths;
};

bool parse_args(int argc, char** argv, Opts& o) {
  bool after_dd = false;
  for (int i = 1; i < argc; ++i) {
    std::string a = argv[i];
    auto val = [&](std::string& dst) {
      if (i + 1 >= argc) { std::fprintf(stderr, "gitcppdiff: %s needs a value\n", a.c_str()); return false; }
      dst = argv[++i];
      return true;
    };
    if (after_dd) { o.paths.push_back(a); continue; }
    if (a == "--") after_dd = true;
    else if (a == "-h" || a == "--help") { std::fputs(kHelp, stdout); std::exit(0); }
    else if (a == "--format") { if (!val(o.format)) return false; }
    else if (a.rfind("--format=", 0) == 0) o.format = a.substr(9);
    else if (a == "--color") { if (!val(o.color)) return false; }
    else if (a.rfind("--color=", 0) == 0) o.color = a.substr(8);
    else if (a == "--no-icons") o.icons = false;
    else if (a == "--api-only") o.api_only = true;
    else if (a == "--all-api") o.all_api = true;
    else if (a == "--expand") o.expand = true;
    else if (a == "--fail-on-api") o.fail_api = true;
    else if (a == "--staged" || a == "--cached") o.staged = true;
    else if (a == "-v" || a == "--verbose") o.verbose = true;
    else if (a == "--dump-ast") { std::string f; if (!val(f)) return false;
      std::ifstream in(f, std::ios::binary); std::stringstream ss; ss << in.rdbuf();
      std::fputs(dump_ast(ss.str()).c_str(), stdout); std::exit(0); }
    else if (a == "--macro" || a.rfind("--macro=", 0) == 0) {
      std::string v;
      if (a == "--macro") { if (!val(v)) return false; } else v = a.substr(8);
      o.macros.insert(v);
    }
    else if (a == "--config") { if (!val(o.config_file)) return false; }
    else if (a == "--no-config") o.no_config = true;
    else if (a == "-C") { if (!val(o.dir)) return false; }
    else if (a == "--only" || a.rfind("--only=", 0) == 0) {
      std::string v;
      if (a == "--only") { if (!val(v)) return false; } else v = a.substr(7);
      size_t p = 0;
      while (p <= v.size()) {
        size_t q = v.find(',', p);
        if (q == std::string::npos) q = v.size();
        if (q > p) o.only.insert(v.substr(p, q - p));
        p = q + 1;
      }
    }
    else if (!a.empty() && a[0] == '-') { std::fprintf(stderr, "gitcppdiff: unknown option %s (see --help)\n", a.c_str()); return false; }
    else o.pos.push_back(a);
  }
  return true;
}

int term_width() {
  struct winsize w;
  if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 && w.ws_col > 20) return std::min<int>(w.ws_col, 140);
  return 100;
}

}  // namespace

int main(int argc, char** argv) {
  Opts o;
  if (!parse_args(argc, argv, o)) return 64;

  bool tty = isatty(STDOUT_FILENO);
  bool color = o.color == "always" || (o.color == "auto" && tty && !std::getenv("NO_COLOR") &&
                                       std::getenv("TERM") && std::strcmp(std::getenv("TERM"), "dumb") != 0);
  if (const char* e = std::getenv("GITCPPDIFF_ICONS")) if (!std::strcmp(e, "0")) o.icons = false;

  auto git = Git::open(o.dir);
  if (!git) { std::fprintf(stderr, "gitcppdiff: not inside a git repository\n"); return 128; }
  std::string err;
  auto spec = git->make_spec(o.pos, o.staged, err);
  if (!spec) { std::fprintf(stderr, "gitcppdiff: %s\n", err.c_str()); return 128; }

  auto files = git->changes(*spec, o.paths);

  // project settings: .gitcppdiff
  ProjectConfig pc;
  if (!o.no_config) pc = load_project_config(o.config_file.empty() ? git->root() + "/.gitcppdiff" : o.config_file);
  for (auto& w : pc.warnings) std::fprintf(stderr, "gitcppdiff: warning: %s\n", w.c_str());
  o.macros.insert(pc.macros.begin(), pc.macros.end());
  files.erase(std::remove_if(files.begin(), files.end(), [&](const FileChange& f) {
                return matches_any(pc.ignore, f.new_path) || matches_any(pc.ignore, f.old_path);
              }), files.end());

  Parser parser;
  if (const char* m = std::getenv("GITCPPDIFF_MACROS")) {
    std::string v = m;
    size_t p = 0;
    while (p <= v.size()) {
      size_t q = v.find(',', p);
      if (q == std::string::npos) q = v.size();
      if (q > p) o.macros.insert(v.substr(p, q - p));
      p = q + 1;
    }
  }
  parser.set_macros(o.macros);
  parser.set_internal_namespaces(pc.internal_ns);
  Side old_side, new_side;
  for (auto& f : files) {
    if (f.status != 'A') parser.parse_into(old_side, f.old_path, git->read_old(*spec, f.old_path));
    if (f.status != 'D') parser.parse_into(new_side, f.new_path, git->read_new(*spec, f.new_path));
  }

  // Companion headers of changed sources: unchanged, parsed only for declarations / access.
  {
    bool any_source = false;
    for (auto& f : files) if (!is_header_path(f.new_path) && !is_header_path(f.old_path)) any_source = true;
    if (any_source) {
      auto hv = git->list_headers(*spec);
      std::set<std::string> headers(hv.begin(), hv.end());
      std::multimap<std::string, std::string> by_base;
      for (auto& h : hv) by_base.emplace(h.substr(h.rfind('/') == std::string::npos ? 0 : h.rfind('/') + 1), h);
      std::set<std::string> changed, comps;
      for (auto& f : files) { changed.insert(f.old_path); changed.insert(f.new_path); }
      for (auto& f : files) {
        if (is_header_path(f.new_path) || is_header_path(f.old_path)) continue;
        std::string src = f.status == 'D' ? f.old_path : f.new_path;
        std::string text = f.status == 'D' ? git->read_old(*spec, src) : git->read_new(*spec, src);
        for (auto& c : find_companions(src, text, headers, by_base, changed)) comps.insert(c);
      }
      for (auto& c : comps) {
        if (o.verbose) std::fprintf(stderr, "gitcppdiff: companion header %s\n", c.c_str());
        parser.parse_into(old_side, c, git->read_old(*spec, c));
        parser.parse_into(new_side, c, git->read_new(*spec, c));
      }
    }
  }
  std::set<std::string> classes = old_side.classes, nss = old_side.namespaces;
  classes.insert(new_side.classes.begin(), new_side.classes.end());
  nss.insert(new_side.namespaces.begin(), new_side.namespaces.end());
  finalize(old_side, classes, nss);
  finalize(new_side, classes, nss);
  if (o.verbose && (old_side.errors || new_side.errors))
    std::fprintf(stderr, "gitcppdiff: warning: %d parse-error region(s) skipped or recovered\n",
                 old_side.errors + new_side.errors);

  ApiPolicy policy;
  policy.all = o.all_api || pc.all_api.value_or(false);
  policy.public_globs = pc.public_globs;
  DiffResult res = diff(old_side, new_side, policy);

  // filters
  auto keep = [&](const Change& c) {
    if (o.api_only && !c.api) return false;
    if (o.only.empty()) return true;
    std::string s = status_name(c.status);
    if (o.only.count(s)) return true;
    if (c.status == Status::ApiChange && o.only.count("api")) return true;
    return false;
  };
  res.changes.erase(std::remove_if(res.changes.begin(), res.changes.end(),
                                   [&](const Change& c) { return !keep(c); }),
                    res.changes.end());

  RenderOptions ro;
  ro.color = color;
  ro.icons = o.icons;
  ro.expand = o.expand;
  ro.verbose = o.verbose;
  ro.width = term_width();
  ro.files_scanned = static_cast<int>(files.size());
  ro.label = spec->label;
  ro.repo_root = git->root();
  ro.base_rev = spec->base;
  ro.head_rev = spec->head;
  ro.head_kind = spec->head_kind == HeadKind::Rev ? "rev" : spec->head_kind == HeadKind::Index ? "index" : "worktree";

  std::string out = o.format == "json" ? render_json(res, ro) : render_pretty(res, ro);
  std::fwrite(out.data(), 1, out.size(), stdout);

  if (o.fail_api)
    for (auto& c : res.changes)
      if (c.status == Status::ApiChange || (c.status == Status::Removed && c.api)) return 2;
  return 0;
}
