#pragma once
#include <string>
#include "diff.hpp"
#include "git.hpp"

namespace cppdiff {

struct RenderOptions {
  bool color = true;
  bool icons = true;
  bool expand = false;      // list members of added/removed types individually
  bool verbose = false;
  int width = 100;
  int files_scanned = 0;
  std::string label;
  std::string repo_root;
  std::string base_rev, head_rev, head_kind;  // head_kind: rev | index | worktree
};

std::string render_pretty(const DiffResult& r, const RenderOptions& o);
std::string render_json(const DiffResult& r, const RenderOptions& o);

}  // namespace cppdiff
