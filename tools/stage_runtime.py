#!/usr/bin/env python3
"""Stage the pinned Linux integration runtimes under .deps/."""
import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]
PACKAGE = json.loads((ROOT / "ducksassy-package.json").read_text())


def git_source(repository, revision, destination, sparse=()):
    if not destination.exists():
        subprocess.run(["git", "init", str(destination)], check=True)
        subprocess.run(["git", "-C", str(destination), "remote", "add", "origin", repository], check=True)
        subprocess.run(["git", "-C", str(destination), "fetch", "--depth=1", "--filter=blob:none", "origin", revision], check=True)
        if sparse:
            subprocess.run(["git", "-C", str(destination), "sparse-checkout", "set", *sparse], check=True)
        subprocess.run(["git", "-C", str(destination), "checkout", "--detach", revision], check=True)
    actual = subprocess.check_output(["git", "-C", str(destination), "rev-parse", "HEAD"], text=True).strip()
    dirty = subprocess.check_output(["git", "-C", str(destination), "status", "--porcelain"], text=True).strip()
    if actual != revision or dirty:
        raise RuntimeError(f"Expected a clean {revision} checkout in {destination}; existing work was not changed")


def duckhts():
    pin = PACKAGE["duckhts_integration"]
    if platform.system() != "Linux" or platform.machine() not in ("x86_64", "AMD64"):
        raise RuntimeError(f"The pinned DuckHTS integration artifact targets {pin['platform']}")
    target = ROOT / ".deps/duckhts.duckdb_extension"
    if target.exists() and hashlib.sha256(target.read_bytes()).hexdigest() == pin["sha256"]:
        return
    request = Request(pin["url"], headers={
        "User-Agent": f"ducksassy-runtime-stager/{PACKAGE['version']}",
    })
    with urlopen(request, timeout=120) as response:
        archive = response.read(pin["archive_bytes"] + 1)
    if hashlib.sha256(archive).hexdigest() != pin["archive_sha256"]:
        raise RuntimeError("DuckHTS archive checksum mismatch; update the pin deliberately")
    data = gzip.decompress(archive)
    if hashlib.sha256(data).hexdigest() != pin["sha256"]:
        raise RuntimeError("DuckHTS extension checksum mismatch")
    with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as temporary:
        staging = Path(temporary.name)
        try:
            temporary.write(data)
            temporary.flush()
            staging.replace(target)
        finally:
            staging.unlink(missing_ok=True)


def duckdb(jobs):
    revision = PACKAGE["duckdb_sdk_revision"]
    binary = ROOT / ".deps/duckdb-build/duckdb"
    if binary.exists():
        version = subprocess.check_output([str(binary), "--version"], text=True)
        if revision[:10] not in version:
            raise RuntimeError(f"Cached DuckDB does not match {revision}")
        return
    source = ROOT / ".deps/duckdb"
    git_source("https://github.com/duckdb/duckdb.git", revision, source)
    subprocess.run(["cmake", "-S", str(source), "-B", str(binary.parent),
                    "-DCMAKE_BUILD_TYPE=Release", "-DBUILD_UNITTESTS=OFF", "-DBUILD_SHELL=ON",
                    "-DBUILD_EXTENSIONS=json;parquet"], check=True)
    subprocess.run(["cmake", "--build", str(binary.parent), "--target", "shell", f"-j{jobs}"], check=True)


def sassy(jobs):
    source = ROOT / ".deps/sassy-source"
    git_source("https://github.com/RagnarGrootKoerkamp/sassy.git", PACKAGE["sassy_source_revision"], source)
    manifest = str(source / "Cargo.toml")
    subprocess.run(["cargo", "fetch", "--locked", "--manifest-path", manifest], check=True)
    environment = dict(os.environ, CARGO_TARGET_DIR=str(ROOT / ".deps/sassy-target"),
                       RUSTFLAGS="-C relocation-model=pic")
    subprocess.run(["cargo", "build", "--locked", "--offline", "--manifest-path", manifest,
                    "--features", "scalar", "--bin", "sassy", "--release", f"-j{jobs}"],
                   check=True, env=environment)


def r_tools():
    pins = PACKAGE["r_tools"]
    git_source("https://github.com/rundel/duckknit.git", pins["duckknit_revision"], ROOT / ".deps/duckknit")
    git_source("https://github.com/RGenomicsETL/duckhts.git", pins["duckhtsbench_revision"],
               ROOT / ".deps/duckhtsbench-source", sparse=("r/duckhtsbench",))
    subprocess.run(["Rscript", "tools/install_r_tools.R"], cwd=ROOT, check=True)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("component", nargs="?", choices=("all", "duckhts", "duckdb", "sassy", "r-tools"), default="all")
    parser.add_argument("--jobs", type=int, default=2)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    (ROOT / ".deps").mkdir(exist_ok=True)
    if args.component in ("all", "duckhts"):
        duckhts()
    if args.component in ("all", "duckdb"):
        duckdb(args.jobs)
    if args.component in ("all", "sassy"):
        sassy(args.jobs)
    if args.component in ("all", "r-tools"):
        r_tools()


if __name__ == "__main__":
    main()
