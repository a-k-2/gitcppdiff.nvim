#pragma once
#include <string>
#include "model.hpp"

struct TSParser;

namespace cppdiff {

class Parser {
 public:
  Parser();
  ~Parser();
  Parser(const Parser&) = delete;
  Parser& operator=(const Parser&) = delete;
  // Extract all symbols of `text` into `side`.
  void parse_into(Side& side, const std::string& file, const std::string& text);
  // Identifiers (export / attribute macros) that are blanked out before parsing.
  void set_macros(std::set<std::string> m) { macros_ = std::move(m); }
  // Namespaces whose contents never count as public API (e.g. detail, internal).
  void set_internal_namespaces(std::set<std::string> n) { internal_ns_ = std::move(n); }

 private:
  std::set<std::string> macros_, internal_ns_;
  TSParser* p_;
};

std::string dump_ast(const std::string& text);
bool is_header_path(const std::string& path);
// Resolve Function-vs-Method for out-of-class definitions once all files are known.
void finalize(Side& side, const std::set<std::string>& all_classes,
              const std::set<std::string>& all_namespaces);

}  // namespace cppdiff
