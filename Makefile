.PHONY: all build test test-tsan run-examples fmt fmt-check ci

all: ci

build:
	zig build

test:
	zig build test --summary all

test-tsan:
	zig build test-tsan --summary all

run-examples:
	zig build run-examples

fmt:
	zig fmt src examples build.zig

fmt-check:
	zig fmt --check src examples build.zig

ci: fmt-check build test test-tsan run-examples
