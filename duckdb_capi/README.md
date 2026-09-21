# DuckDB C API v2 SDK

The v1 template headers have been removed. Run `make sdk` to fetch only
`duckdb_v2.h` and `duckdb_extension_v2.h` at the revision pinned in
`tools/fetch_sdk.py`, or point `DUCKDB_CAPI_DIR` at that checkout's
`src/include` directory for an offline build.

The adapter explicitly compiles with `DUCKDB_V2_API_ALLOW_UNSTABLE=0` and
`DUCKDB_V2_API_ALLOW_DEPRECATED=0`. Its metadata targets `C_STRUCT` / `v2.0.0`.
This is a C API **v2-only** implementation, not a v1 extension labelled v2.

The inspected preview SDK still warns that the extension ABI is not frozen.
Use the matching pinned DuckDB checkout for validation. Do not infer a released
cross-version compatibility guarantee from the chosen v2 API version string.
