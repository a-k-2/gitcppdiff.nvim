# `make` builds the executable and installs it to ./bin/gitcppdiff (where the plugin looks first).
BUILD ?= build
GEN := $(shell command -v ninja >/dev/null 2>&1 && echo "-G Ninja")

.PHONY: all test clean
all:
	cmake -S . -B $(BUILD) $(GEN) -DCMAKE_BUILD_TYPE=Release
	cmake --build $(BUILD) --parallel
	mkdir -p bin && cp $(BUILD)/gitcppdiff bin/gitcppdiff

test: all
	./tests/run.sh bin/gitcppdiff
	./tests/nvim/run.sh

clean:
	rm -rf $(BUILD) bin
