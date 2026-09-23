.PHONY: all setup setup-data sdk sdk-v1 vendor-rust r-package r-readme configure release release-v1 test sql-test sql-test-v1 oracle-test r-test readme benchmarks clean
BUILD_DIR ?= build
DUCKDB_CAPI_DIR ?= $(CURDIR)/duckdb_capi
JOBS ?= 2
V1_BUILD_DIR ?= build-v1
V1_DUCKDB ?= $(CURDIR)/.deps-v1/cli/duckdb
V1_DUCKHTS ?= $(CURDIR)/.deps/duckhts.duckdb_extension
R_RUN = R_LIBS="$(CURDIR)/.deps/Rlib" Rscript
all: release
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
configure:
	cmake -S . -B $(BUILD_DIR) -DCMAKE_BUILD_TYPE=Release -DDUCKDB_CAPI_DIR=$(DUCKDB_CAPI_DIR) -DDUCKSASSY_HOST=v2
release: configure
	cmake --build $(BUILD_DIR) -j$(JOBS)
test: release
	cargo --config $(BUILD_DIR)/rust-vendor.toml test --frozen --manifest-path rust/Cargo.toml -j$(JOBS)
	ctest --test-dir $(BUILD_DIR) --output-on-failure
	python3 test/check_contract.py
	python3 test/test_staging.py
sql-test: release
	python3 test/run_sql.py
	python3 test/native_load.py --host v2 --duckdb .deps/duckdb-build/duckdb --extension $(BUILD_DIR)/ducksassy.duckdb_extension
oracle-test: release
	$(R_RUN) test/compare_crispr.R
r-test: release
	$(R_RUN) test/run_sql.R
readme: release
	$(R_RUN) tools/render_readme.R
benchmarks: release
	$(R_RUN) tools/render_readme.R benchmarks/sequence_search.Rmd
clean:
	cmake -E rm -rf $(BUILD_DIR)
