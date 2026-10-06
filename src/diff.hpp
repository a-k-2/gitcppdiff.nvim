#pragma once
#include <set>
#include <string>
#include <vector>
#include "model.hpp"

namespace cppdiff {

enum class Status { Added, Removed, Modified, ApiChange, Renamed };

struct Change {
  Status status = Status::Modified;
  Kind kind = Kind::Function;
  std::string qualified;               // new name if present, else old
  std::string name;
  std::vector<std::string> scope;
  std::string file;                    // file shown under (new if present)
  int line = 0;
  const Entity* old_e = nullptr;
  const Entity* new_e = nullptr;
  std::vector<std::string> reasons;    // human readable "what changed"
  bool api = false;                    // part of the public API surface
  const Symbol& sym() const { return new_e ? new_e->primary() : old_e->primary(); }
};

struct DiffResult {
  std::vector<Change> changes;
  std::set<std::string> type_scopes;   // qualified names that are classes/structs/unions
};

struct ApiPolicy {
  bool all = false;                          // every symbol counts as API
  std::vector<std::string> public_globs;     // if non-empty: only headers matching these are public
};

DiffResult diff(const Side& old_side, const Side& new_side, const ApiPolicy& policy);

const char* status_name(Status s);
const char* kind_name(Kind k);

}  // namespace cppdiff
