.DEFAULT_GOAL := all
.PHONY: all help setup setup-data sdk sdk-v1 vendor-rust r-package r-readme site configure-v2 release-v2 release-v1 test-v2 sql-test sql-test-v1 oracle-test r-test readme benchmarks clean windows-host-check
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
ifneq ($(OSX_BUILD_ARCH),)
CMAKE_EXTRA_BUILD_FLAGS += -DCMAKE_OSX_ARCHITECTURES=$(OSX_BUILD_ARCH)
ifeq ($(OSX_BUILD_ARCH),x86_64)
CMAKE_EXTRA_BUILD_FLAGS += -DCMAKE_SYSTEM_PROCESSOR=x86_64 -DCMAKE_SYSTEM_NAME=Darwin -DRUST_TARGET=x86_64-apple-darwin
else
CMAKE_EXTRA_BUILD_FLAGS += -DCMAKE_SYSTEM_PROCESSOR=arm64 -DCMAKE_SYSTEM_NAME=Darwin -DRUST_TARGET=aarch64-apple-darwin
endif
endif
include extension-ci-tools/makefiles/c_api_extensions/base.Makefile
include extension-ci-tools/makefiles/c_api_extensions/c_cpp.Makefile

.PHONY: configure release debug test_release test_debug distribution-sdk
configure: venv platform extension_version distribution-sdk
distribution-sdk:
	python3 tools/fetch_v1_sdk.py configure/sdk-v1
release: build_extension_with_metadata_release
debug: build_extension_with_metadata_debug
test_release: test_extension_release
test_debug: test_extension_debug

all: release
help:
	@printf '%s\n' 'Distribution v1: configure release debug test_release test_debug (build/release or build/debug)' 'Preview v2: configure-v2 release-v2 test-v2 sql-test r-test oracle-test readme (build/)' 'Local v1: sdk-v1 release-v1 sql-test-v1 (build-v1/)' 'R package: r-package; documentation: site (site/)'
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
vendor-rust:
	Rscript tools/vendor-rust.R
r-package:
	Rscript tools/stage_r_package.R
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
