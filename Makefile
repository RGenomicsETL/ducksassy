.DEFAULT_GOAL := all
.PHONY: all help setup setup-data sdk sdk-v1 vendor-rust r-bootstrap r-bootstrap-check r-package r-readme site function_catalog configure-v2 release-v2 release-v1 test-v2 sql-test sql-test-v1 oracle-test r-test readme benchmarks clean windows-host-check
BUILD_DIR ?= build
MINGW_CC ?= x86_64-w64-mingw32-gcc
DUCKDB_CAPI_DIR ?= $(CURDIR)/duckdb_capi
JOBS ?= 2
V1_BUILD_DIR ?= build-v1
V1_DUCKDB ?= $(CURDIR)/.deps-v1/cli/duckdb
V1_DUCKHTS ?= $(CURDIR)/.deps/duckhts.duckdb_extension
R_RUN ?= R_LIBS="$(CURDIR)/.deps/Rlib" Rscript

# Distribution contract: CMake owns both the C adapter and Rust static archives.
# rust.Makefile is for Rust-only extensions; its build recipes conflict with c_cpp.
EXTENSION_NAME := ducksassy
PROJ_DIR := $(CURDIR)
TARGET_DUCKDB_VERSION := $(shell python3 -c 'import json; print(json.load(open("ducksassy-package.json"))["v1_host"]["extension_api_version"])')
DUCKDB_TEST_VERSION := $(shell python3 -c 'import json; print(json.load(open("ducksassy-package.json"))["v1_host"]["duckdb_version"].removeprefix("v"))')
EXTENSION_VERSION := $(shell python3 -c 'import json; print(json.load(open("ducksassy-package.json"))["version"])')
CMAKE_EXTRA_BUILD_FLAGS += -DDUCKSASSY_HOST=v1 -DDUCKSASSY_DISTRIBUTION=ON -DDUCKDB_CAPI_DIR=$(CURDIR)/configure/sdk-v1 -DSASSY_CARGO_JOBS=$(JOBS)
ifneq ($(DUCKDB_PLATFORM),)
CMAKE_EXTRA_BUILD_FLAGS += -DDUCKDB_PLATFORM=$(DUCKDB_PLATFORM)
endif
ifneq ($(filter windows_amd64_mingw windows_amd64_rtools,$(DUCKDB_PLATFORM)),)
DISTRIBUTION_RUST_TARGET := x86_64-pc-windows-gnu
CMAKE_EXTRA_BUILD_FLAGS += -DRUST_TARGET=$(DISTRIBUTION_RUST_TARGET)
endif
ifneq ($(filter wasm_%,$(DUCKDB_PLATFORM)),)
DISTRIBUTION_RUST_TARGET := wasm32-unknown-emscripten
CMAKE_EXTRA_BUILD_FLAGS += -DRUST_TARGET=$(DISTRIBUTION_RUST_TARGET)
endif
ifneq ($(OSX_BUILD_ARCH),)
CMAKE_EXTRA_BUILD_FLAGS += -DCMAKE_OSX_ARCHITECTURES=$(OSX_BUILD_ARCH)
ifeq ($(OSX_BUILD_ARCH),x86_64)
OSX_RUST_TARGET := x86_64-apple-darwin
CMAKE_EXTRA_BUILD_FLAGS += -DCMAKE_SYSTEM_PROCESSOR=x86_64
else
OSX_RUST_TARGET := aarch64-apple-darwin
CMAKE_EXTRA_BUILD_FLAGS += -DCMAKE_SYSTEM_PROCESSOR=arm64
endif
CMAKE_EXTRA_BUILD_FLAGS += -DCMAKE_SYSTEM_NAME=Darwin -DRUST_TARGET=$(OSX_RUST_TARGET)
endif
# Include the CI makefiles only once the submodule exists, so a fresh clone can
# still run `make setup`, which initializes it.
CI_TOOLS_MAKEFILES := extension-ci-tools/makefiles/c_api_extensions
ifneq ($(wildcard $(CI_TOOLS_MAKEFILES)/base.Makefile),)
include $(CI_TOOLS_MAKEFILES)/base.Makefile
include $(CI_TOOLS_MAKEFILES)/c_cpp.Makefile
else
venv platform extension_version build_extension_with_metadata_release build_extension_with_metadata_debug test_extension_release test_extension_debug:
	@echo "extension-ci-tools is missing; run make setup or git submodule update --init" >&2
	@exit 1
endif

.PHONY: configure release debug test_release test_debug distribution-sdk rust-target
configure: venv platform extension_version distribution-sdk
distribution-sdk:
	python3 tools/fetch_v1_sdk.py configure/sdk-v1
# Install std into the project's pinned toolchain, not the runner's default.
# Native developers need only their host target.
rust-target:
ifneq ($(strip $(OSX_RUST_TARGET) $(DISTRIBUTION_RUST_TARGET)),)
	rustup target add $(OSX_RUST_TARGET) $(DISTRIBUTION_RUST_TARGET)
endif
build_extension_library_release build_extension_library_debug: rust-target
link_wasm_release: build_extension_library_release
link_wasm_debug: build_extension_library_debug
# Emscripten 3.1.71's Binaryen does not recognize Rust 1.91's bulk-memory-opt
# feature tag. -O1 skips the post-link optimizer; Rust remains release-optimized.
# Upstream's final emcc command does not forward its CMake feature flags.
ifeq ($(DUCKDB_PLATFORM),wasm_mvp)
link_wasm_release link_wasm_debug: export EMCC_CFLAGS = -O1
else ifeq ($(DUCKDB_PLATFORM),wasm_eh)
link_wasm_release link_wasm_debug: export EMCC_CFLAGS = -O1 -fwasm-exceptions
else ifeq ($(DUCKDB_PLATFORM),wasm_threads)
link_wasm_release link_wasm_debug: export EMCC_CFLAGS = -O1 -fwasm-exceptions -pthread -msimd128 -mbulk-memory
endif
release: rust-target build_extension_with_metadata_release
debug: rust-target build_extension_with_metadata_debug
test_release: test_extension_release
test_debug: test_extension_debug

all: release
help:
	@printf '%s\n' 'Distribution v1: configure release debug test_release test_debug (build/release or build/debug)' 'Preview v2: configure-v2 release-v2 test-v2 sql-test r-test oracle-test readme (build/)' 'Local v1: sdk-v1 release-v1 sql-test-v1 (build-v1/)' 'R package: r-bootstrap r-bootstrap-check r-package; documentation: site (site/), function_catalog'
setup:
	git submodule update --init
	python3 tools/fetch_sdk.py $(DUCKDB_CAPI_DIR)
	python3 tools/stage_runtime.py --jobs $(JOBS)
setup-data:
	$(R_RUN) tools/stage_benchmark_data.R
sdk:
	python3 tools/fetch_sdk.py $(DUCKDB_CAPI_DIR)
sdk-v1:
	python3 tools/fetch_v1_sdk.py
.PHONY: wasm-playwright-test
wasm-playwright-test:
	bash scripts/start_duckdb_wasm_local_test.sh --test
windows-host-check:
	mkdir -p $(V1_BUILD_DIR)/windows-host-check
	$(MINGW_CC) -std=gnu11 -Wall -Wextra -Werror -D_WIN32_WINNT=0x0600 -DDUCKDB_EXTENSION_NAME=ducksassy -I.deps-v1/sdk -Iinclude -Isrc -c src/host_v1.c -o $(V1_BUILD_DIR)/windows-host-check/host_v1.o
	$(MINGW_CC) -std=gnu11 -Wall -Wextra -Werror -Iinclude -Isrc -c src/ducksassy_core.c -o $(V1_BUILD_DIR)/windows-host-check/core.o
release-v1:
	cmake -S . -B $(V1_BUILD_DIR) -DCMAKE_BUILD_TYPE=Release -DDUCKSASSY_HOST=v1
	cmake --build $(V1_BUILD_DIR) -j$(JOBS)
sql-test-v1: release-v1
	python3 test/run_sql.py --host v1 --duckdb $(V1_DUCKDB) --extension $(V1_BUILD_DIR)/ducksassy.duckdb_extension --duckhts $(V1_DUCKHTS)
	python3 test/native_load.py --host v1 --duckdb $(V1_DUCKDB) --extension $(V1_BUILD_DIR)/ducksassy.duckdb_extension
	python3 test/check_function_catalog.py --duckdb $(V1_DUCKDB) --extension $(V1_BUILD_DIR)/ducksassy.duckdb_extension
# Renders docs/functions.md and, when ./community-extensions is a checkout of the
# fork, extensions/ducksassy/description.yml for the community submission.
function_catalog:
	python3 scripts/render_function_catalog.py
	python3 test/check_function_catalog.py
vendor-rust:
	Rscript tools/vendor-rust.R
r-bootstrap:
	cd r/Rducksassy && Rscript bootstrap.R ../..
# Fails when committed package copies differ from what bootstrap generates.
r-bootstrap-check: r-bootstrap
	git diff --exit-code -- r/Rducksassy
	test -z "$$(git status --porcelain --untracked-files=all -- r/Rducksassy)"
r-package: r-bootstrap
	R CMD build r/Rducksassy
r-readme:
	Rscript -e 'rmarkdown::render("r/Rducksassy/README.Rmd", quiet = TRUE)'
site:
	Rscript tools/build-site.R
configure-v2:
	cmake -S . -B $(BUILD_DIR) -DCMAKE_BUILD_TYPE=Release -DDUCKDB_CAPI_DIR=$(DUCKDB_CAPI_DIR) -DDUCKSASSY_HOST=v2
release-v2: configure-v2
	cmake --build $(BUILD_DIR) -j$(JOBS)
test-v2: release-v2
	cargo --config $(BUILD_DIR)/rust-vendor.toml test --frozen --manifest-path rust/Cargo.toml -j$(JOBS)
	ctest --test-dir $(BUILD_DIR) --output-on-failure
	python3 test/check_contract.py
	python3 test/test_staging.py
sql-test: release-v2
	python3 test/run_sql.py
	python3 test/native_load.py --host v2 --duckdb .deps/duckdb-build/duckdb --extension $(BUILD_DIR)/ducksassy.duckdb_extension
oracle-test: release-v2
	$(R_RUN) test/compare_crispr.R
r-test: release-v2
	$(R_RUN) test/run_sql.R
readme: release-v2
	$(R_RUN) tools/render_readme.R
benchmarks: release-v2
	$(R_RUN) tools/render_readme.R benchmarks/sequence_search.Rmd
clean:
	cmake -E rm -rf $(BUILD_DIR)
