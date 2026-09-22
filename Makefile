.PHONY: all setup setup-data sdk vendor-rust r-package r-readme configure release test sql-test oracle-test r-test readme benchmarks clean
BUILD_DIR ?= build
DUCKDB_CAPI_DIR ?= $(CURDIR)/duckdb_capi
JOBS ?= 2
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
vendor-rust:
	Rscript tools/vendor-rust.R
r-package:
	Rscript tools/stage_r_package.R
	R CMD build r/Rducksassy
r-readme:
	Rscript -e 'rmarkdown::render("r/Rducksassy/README.Rmd", quiet = TRUE)'
configure:
	cmake -S . -B $(BUILD_DIR) -DCMAKE_BUILD_TYPE=Release -DDUCKDB_CAPI_DIR=$(DUCKDB_CAPI_DIR)
release: configure
	cmake --build $(BUILD_DIR) -j$(JOBS)
test: release
	cargo --config $(BUILD_DIR)/rust-vendor.toml test --frozen --manifest-path rust/Cargo.toml -j$(JOBS)
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
benchmarks: release
	$(R_RUN) tools/render_readme.R benchmarks/sequence_search.Rmd
clean:
	cmake -E rm -rf $(BUILD_DIR)
