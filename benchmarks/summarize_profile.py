"""Summarize perf report -t ';' --no-children output without adding inclusive times."""

import csv
import json
from pathlib import Path
import sys


def category(symbol):
    if "pthread_mutex" in symbol:
        return "mutex"
    if "pthread_once" in symbol:
        return "pthread_once"
    if any(name in symbol for name in ("malloc", "calloc", "realloc", "cfree", "_int_free", "memalign")):
        return "allocator"
    if any(name in symbol for name in ("__memset", "__memmove", "__memcpy")):
        return "copy_or_zero"
    if "core::fmt" in symbol or "Cigar as alloc::string::ToString" in symbol:
        return "cigar_formatting"
    if symbol == "sassy_c::validate_alphabet":
        return "alphabet_validation"
    if symbol.startswith("sassy::"):
        return "sassy_search_traceback_encoding"
    return "other"


def main():
    if len(sys.argv) != 3:
        raise SystemExit("Usage: python3 benchmarks/summarize_profile.py INPUT_DIR OUTPUT_DIR")
    source, output = map(Path, sys.argv[1:])
    output.mkdir(parents=True, exist_ok=True)
    symbols = []
    summary = []
    runs = {}
    for name in ("one", "eight", "ascii"):
        groups = {}
        for line in (source / f"{name}-symbols.csv").read_text().splitlines():
            fields = [field.strip() for field in line.split(";")]
            if len(fields) < 4 or not fields[0].endswith("%"):
                continue
            percent = float(fields[0][:-1])
            samples = int(fields[1])
            symbol = fields[3].removeprefix("[.] ")
            group = category(symbol)
            symbols.append([name, percent, samples, fields[2], symbol, group])
            total = groups.setdefault(group, [0.0, 0])
            total[0] += percent
            total[1] += samples
        summary.extend([name, group, round(percent, 2), samples]
                       for group, (percent, samples) in groups.items())
        ready = json.loads((source / name / "ready.json").read_text())
        ready.pop("pid")
        ready["profiled_elapsed_seconds"] = float((source / name / "elapsed.txt").read_text())
        ready["duckdb_samples"] = sum(samples for percent, samples in groups.values())
        runs[name] = ready
    for filename, header, rows in (
        ("symbols.csv", ["run", "self_percent", "samples", "object", "symbol", "category"], symbols),
        ("categories.csv", ["run", "category", "self_percent", "samples"], summary),
    ):
        with (output / filename).open("w", newline="") as handle:
            writer = csv.writer(handle, lineterminator="\n")
            writer.writerow(header)
            writer.writerows(rows)
    (output / "runs.json").write_text(json.dumps(runs, indent=2) + "\n")
    for filename in ("eight-locks.txt", "ascii-memset.txt"):
        lines = (source / filename).read_text().splitlines()
        (output / filename).write_text("\n".join(line.rstrip() for line in lines) + "\n")


if __name__ == "__main__":
    main()
