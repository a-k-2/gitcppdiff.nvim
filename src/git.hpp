#pragma once
#include <optional>
#include <string>
#include <vector>

namespace cppdiff {

enum class HeadKind { Rev, Index, Worktree };

struct Spec {
  std::string base;            // revision
  std::string head;            // revision (when head_kind == Rev)
  HeadKind head_kind = HeadKind::Worktree;
  std::string label;           // e.g. "HEAD → worktree"
};

struct FileChange {
  char status = 'M';           // A, M, D, R, T
  std::string old_path, new_path;
};

class Git {
 public:
  static std::optional<Git> open(const std::string& dir);
  // positional: [], [A], [A, B], ["A..B"], ["A...B"]
  std::optional<Spec> make_spec(const std::vector<std::string>& pos, bool staged, std::string& err) const;
  std::vector<FileChange> changes(const Spec& s, const std::vector<std::string>& pathspecs) const;
  // All header files of the head side (for companion lookup).
  std::vector<std::string> list_headers(const Spec& s) const;
  std::string read_old(const Spec& s, const std::string& path) const;
  std::string read_new(const Spec& s, const std::string& path) const;
  const std::string& root() const { return root_; }

 private:
  std::string run(const std::vector<std::string>& args, bool* ok = nullptr) const;
  std::string root_;
};

}  // namespace cppdiff
