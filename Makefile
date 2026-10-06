# `make` builds the executable and installs it to ./bin/gitcppdiff (where the plugin looks first).
BUILD ?= build
GEN := $(shell command -v ninja >/dev/null 2>&1 && echo "-G Ninja")

.PHONY: all test clean
all:
	@echo "==> [1/3] configuring: detecting the C/C++ compiler, downloading tree-sitter + tree-sitter-cpp (first run needs network, 1-2 min)"
	cmake -S . -B $(BUILD) $(GEN) -DCMAKE_BUILD_TYPE=Release
	@echo "==> [2/3] compiling"
	cmake --build $(BUILD) --parallel
	@echo "==> [3/3] installing bin/gitcppdiff"
	mkdir -p bin && cp $(BUILD)/gitcppdiff bin/gitcppdiff
	@echo "==> done"

test: all
	./tests/run.sh bin/gitcppdiff
	./tests/nvim/run.sh

clean:
	rm -rf $(BUILD) bin
