#!/usr/bin/env bash
# Creates a demo repo at $1: committed "before" state + uncommitted "after" worktree + an untracked new file.
set -euo pipefail
R="$1"; mkdir -p "$R/src"; cd "$R"
git init -q -b main; git config user.email t@t; git config user.name t
cat > src/widget.h <<'EOF'
#pragma once
namespace ui {

enum class Color { Red, Green, Blue };

class Widget : public Base {
public:
  Widget();
  void resize(int w, int h);
  int width() const;
  void update();
  void legacyPaint();
private:
  int width_ = 0;
  void internalReset();
};

class OldPanel {
public:
  void show();
  void hide();
};

}  // namespace ui
EOF
cat > src/widget.cpp <<'EOF'
#include "widget.h"

namespace ui {

Widget::Widget() {}

void Widget::resize(int w, int h) {
  width_ = w;
  height_ = h;
}

int Widget::width() const { return width_; }
void Widget::update() { dirty_ = false; }
void Widget::legacyPaint() { paintOld(1, 2, 3, 4); }
void Widget::internalReset() { width_ = 0; }

}  // namespace ui
EOF
cat > src/main.cpp <<'EOF'
#include "widget.h"
int main() {
  ui::Widget w;
  w.resize(1, 2);
  w.resize(3, 4);
  ui::OldPanel p;
  p.show();
  ui::Color c = ui::Color::Red;
  return w.width() + (int)c;
}
EOF
git add -A; git commit -qm base
cat > src/widget.h <<'EOF'
#pragma once
namespace ui {

enum class Color { Red, Green, Blue, Yellow };

class Widget : public Base, public Serializable {
public:
  Widget();
  void resize(int w, int h, bool animate = true);
  int width() const;
  void update();
  void paintLegacy();
  double ratio() const;
private:
  int width_ = 0;
  void internalReset(bool hard);
};

class Panel {
public:
  void show();
  void toggle();
};

}  // namespace ui
EOF
cat > src/widget.cpp <<'EOF'
#include "widget.h"

namespace ui {

Widget::Widget() {}

void Widget::resize(int w, int h, bool animate) {
  width_ = w;
  height_ = h;
  if (animate) startAnimation();
}

int Widget::width() const { return width_; }
void Widget::update() { dirty_ = true; }
void Widget::paintLegacy() { paintOld(1, 2, 3, 4); }
double Widget::ratio() const { return double(width_) / height_; }
void Widget::internalReset(bool hard) { width_ = 0; if (hard) height_ = 0; }

}  // namespace ui
EOF
cat > src/theme.hpp <<'EOF'
#pragma once
namespace ui {
class Theme {
public:
  Theme();
  int level() const { return level_; }
private:
  int level_ = 1;
};
}
EOF
cat > compile_commands.json <<EOF
[{"directory":"$R","command":"clang++ -std=c++17 -c src/main.cpp","file":"$R/src/main.cpp"},
 {"directory":"$R","command":"clang++ -std=c++17 -c src/widget.cpp","file":"$R/src/widget.cpp"}]
EOF
