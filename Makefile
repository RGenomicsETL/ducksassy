.PHONY: all sdk configure release test clean
BUILD_DIR ?= build
DUCKDB_CAPI_DIR ?= $(CURDIR)/build/sdk
JOBS ?= 2
all: release
sdk:
	python3 tools/fetch_sdk.py $(DUCKDB_CAPI_DIR)
configure:
	cmake -S . -B $(BUILD_DIR) -DCMAKE_BUILD_TYPE=Release -DDUCKDB_CAPI_DIR=$(DUCKDB_CAPI_DIR)
release: configure
	cmake --build $(BUILD_DIR) -j$(JOBS)
test: release
	cargo test --manifest-path rust/Cargo.toml
	ctest --test-dir $(BUILD_DIR) --output-on-failure
	python3 test/check_contract.py
clean:
	cmake -E rm -rf $(BUILD_DIR)
