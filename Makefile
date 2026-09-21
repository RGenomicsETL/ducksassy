.PHONY: all setup setup-data sdk configure release test sql-test oracle-test r-test readme clean
BUILD_DIR ?= build
DUCKDB_CAPI_DIR ?= $(CURDIR)/build/sdk
JOBS ?= 2
R_RUN = R_LIBS="$(CURDIR)/.deps/Rlib" Rscript
all: release
setup:
	git submodule update --init
	cargo fetch --locked --manifest-path rust/Cargo.toml
	python3 tools/fetch_sdk.py $(DUCKDB_CAPI_DIR)
	python3 tools/stage_runtime.py --jobs $(JOBS)
setup-data:
	$(R_RUN) tools/stage_benchmark_data.R
sdk:
	python3 tools/fetch_sdk.py $(DUCKDB_CAPI_DIR)
configure:
	cmake -S . -B $(BUILD_DIR) -DCMAKE_BUILD_TYPE=Release -DDUCKDB_CAPI_DIR=$(DUCKDB_CAPI_DIR)
release: configure
	cmake --build $(BUILD_DIR) -j$(JOBS)
test: release
	cargo test --locked --offline --manifest-path rust/Cargo.toml
	ctest --test-dir $(BUILD_DIR) --output-on-failure
	python3 test/check_contract.py
	python3 test/test_staging.py
sql-test: release
	python3 test/run_sql.py
oracle-test: release
	$(R_RUN) test/compare_crispr.R
r-test: release
	$(R_RUN) test/run_sql.R
readme: release
	$(R_RUN) tools/render_readme.R
clean:
	cmake -E rm -rf $(BUILD_DIR)
