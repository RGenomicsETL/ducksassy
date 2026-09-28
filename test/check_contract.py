#!/usr/bin/env python3
"""Static architecture checks; these do NOT replace compilation or SQL tests."""
from pathlib import Path
import re
import tomllib

root = Path(__file__).resolve().parents[1]
source = (root / "src/host_v2.c").read_text()
core = (root / "src/ducksassy_core.c").read_text() + (root / "src/ducksassy_core.h").read_text()
assert 'duckdb_' not in core
v1 = (root / "src/host_v1.c").read_text()
assert 'DUCKDB_EXTENSION_ENTRYPOINT' in v1
assert 'DUCKDB_EXTENSION_API_VERSION_UNSTABLE' not in v1
cargo = tomllib.loads((root / "rust/Cargo.toml").read_text())
assert set(cargo["dependencies"]) == {"sassy", "pa-types"}
assert "staticlib" in cargo["lib"]["crate-type"]
assert cargo["profile"]["release"]["panic"] == "unwind"
assert '#include "duckdb_extension_v2.h"' in source
assert "#define DUCKDB_V2_API_ALLOW_UNSTABLE 0" in source
assert "#define DUCKDB_V2_API_ALLOW_DEPRECATED 0" in source
assert not (root / "duckdb_capi/duckdb.h").exists()
assert not (root / "duckdb_capi/duckdb_extension.h").exists()
called = set(re.findall(r"\b(duckdb_[a-zA-Z0-9_]+)\s*\(", source))
assert all(name.startswith("duckdb_v2_") for name in called), called
assert "ThreadPool" not in (root / "rust/src/lib.rs").read_text()
bootstrap = (root / "sql/ducksassy.sql").read_text()
assert bootstrap.index("LOAD duckhts;") < bootstrap.index("LOAD ducksassy;")
assert "duckhts_htslib_version()" not in bootstrap
assert "scan_mode := 'sequential'" in bootstrap
print("Architecture contract checks passed (not a runtime test)")
