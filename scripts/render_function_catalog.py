#!/usr/bin/env python3
"""Render the function reference and community descriptor from functions.yaml.

Adapted from DuckHTS's renderer. The manifest is JSON-formatted YAML so only the
Python standard library is needed. The extension version comes from
ducksassy-package.json, which also stamps the built extension's metadata.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
from collections import OrderedDict
from pathlib import Path

REQUIRED_EXTENSION = {"name", "description", "language", "build", "license", "maintainers"}
REQUIRED_FUNCTION = {"name", "kind", "category", "signature", "returns", "description", "examples"}
DOC_LISTS = ("hello_world_lines", "extended_intro", "feature_notes")


def die(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def unique_object(pairs: list[tuple[str, object]]) -> OrderedDict[str, object]:
    result: OrderedDict[str, object] = OrderedDict()
    for key, value in pairs:
        if key in result:
            die(f"Duplicate manifest property: {key}")
        result[key] = value
    return result


def fenced_code(text: str, language: str = "") -> str:
    longest_run = max((len(run) for run in re.findall(r"`+", text)), default=0)
    fence = "`" * max(3, longest_run + 1)
    return f"{fence}{language}\n{text}\n{fence}"


def escape_md(text: str) -> str:
    return text.replace("|", "\\|").replace("\n", " ")


def quote_yaml_scalar(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'


def load_manifest(path: Path) -> OrderedDict[str, object]:
    try:
        payload = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=unique_object)
    except json.JSONDecodeError as exc:
        die(f"Failed to parse {path}: {exc}")
    community = payload.get("community_extension")
    if not isinstance(community, dict):
        die(f"{path} is missing community_extension")
    extension = community.get("extension")
    if not isinstance(extension, dict) or REQUIRED_EXTENSION - set(extension):
        die("community_extension.extension is missing: "
            + ", ".join(sorted(REQUIRED_EXTENSION - set(extension or {}))))
    if not isinstance(community.get("repo"), dict) or "github" not in community["repo"]:
        die("community_extension.repo.github is required")
    docs = community.get("docs")
    for field in DOC_LISTS:
        value = docs.get(field) if isinstance(docs, dict) else None
        if not isinstance(value, list) or not all(isinstance(x, str) for x in value):
            die(f"community_extension.docs.{field} must be a list of strings")
    functions = payload.get("functions")
    if not isinstance(functions, list) or not functions:
        die(f"{path} needs a non-empty functions array")
    seen: set[str] = set()
    for index, entry in enumerate(functions):
        if not isinstance(entry, dict) or REQUIRED_FUNCTION - set(entry):
            die(f"functions[{index}] is missing required fields")
        if entry["name"] in seen:
            die(f"Duplicate function entry for {entry['name']}")
        seen.add(entry["name"])
        if entry["kind"] not in ("scalar", "table"):
            die(f"functions[{index}].kind must be scalar or table")
        examples = entry["examples"]
        if not isinstance(examples, list) or not examples or not all(isinstance(x, str) for x in examples):
            die(f"functions[{index}].examples must be a non-empty list of strings")
    return payload


def by_category(functions: list[dict[str, object]]) -> OrderedDict[str, list[dict[str, object]]]:
    groups: OrderedDict[str, list[dict[str, object]]] = OrderedDict()
    for function in functions:
        groups.setdefault(str(function["category"]), []).append(function)
    return groups


def render_reference(functions: list[dict[str, object]]) -> str:
    lines = ["# Function reference", "", "Generated from `functions.yaml` by "
             "`scripts/render_function_catalog.py`.", ""]
    for category, entries in by_category(functions).items():
        lines.extend([f"## {category}", "", "| Function | Kind | Description |", "| --- | --- | --- |"])
        for entry in entries:
            lines.append(f"| [`{entry['name']}`](#{entry['name']}) | {entry['kind']} | "
                         f"{escape_md(str(entry['description']))} |")
        lines.append("")
    for entry in functions:
        # Explicit anchors: GitHub keeps underscores in heading ids, litedown does not.
        lines.extend([f'<a id="{entry["name"]}"></a>', "", f"### {entry['name']}", "",
                      str(entry["description"]), ""])
        lines.extend(["Signature:", "", fenced_code(str(entry["signature"]), "sql"), ""])
        lines.extend(["Returns:", "", fenced_code(str(entry["returns"])), ""])
        lines.extend(["Examples:", ""])
        for example in entry["examples"]:
            lines.extend([fenced_code(example, "sql"), ""])
    return "\n".join(lines).rstrip("\n") + "\n"


def resolve_repo_ref(repo_root: Path, repo: dict[str, object]) -> str:
    explicit = repo.get("ref")
    if isinstance(explicit, str) and explicit:
        return explicit
    if repo.get("ref_source", "git_head") != "git_head":
        die(f"Unsupported repo.ref_source: {repo.get('ref_source')}")
    try:
        result = subprocess.run(["git", "rev-parse", "HEAD"], check=True,
                                capture_output=True, text=True, cwd=repo_root)
    except (OSError, subprocess.CalledProcessError) as exc:
        die(f"Failed to resolve git HEAD for the community descriptor: {exc}")
    return result.stdout.strip()


def render_description_yaml(repo_root: Path, manifest: OrderedDict[str, object], version: str) -> str:
    community = manifest["community_extension"]
    extension, repo, docs = community["extension"], community["repo"], community["docs"]
    functions = manifest["functions"]
    ref = resolve_repo_ref(repo_root, repo)
    reference_url = f"https://github.com/{repo['github']}/blob/{ref}/docs/functions.md"

    body: list[str] = []
    for paragraph in docs["extended_intro"]:
        body.extend([paragraph, ""])
    body.extend([f"[Full function reference]({reference_url}) includes signatures, "
                 "return types and examples.", "", "Functions included in this extension:", ""])
    for category, entries in by_category(functions).items():
        body.extend([f"### {category}", ""])
        body.extend(f"- `{entry['name']}`: {entry['description']}" for entry in entries)
        body.append("")
    body.extend(["Operational notes:", ""])
    body.extend(f"- {note}" for note in docs["feature_notes"])

    lines = ["extension:",
             f"  name: {quote_yaml_scalar(str(extension['name']))}",
             f"  description: {quote_yaml_scalar(str(extension['description']))}",
             f"  version: {quote_yaml_scalar(version)}"]
    for field in ("language", "build", "license"):
        lines.append(f"  {field}: {quote_yaml_scalar(str(extension[field]))}")
    for field in ("requires_toolchains", "excluded_platforms"):
        value = extension.get(field)
        if isinstance(value, str) and value:
            lines.append(f"  {field}: {quote_yaml_scalar(value)}")
    lines.append("  maintainers:")
    lines.extend(f"    - {quote_yaml_scalar(str(m))}" for m in extension["maintainers"])
    lines.extend(["", "repo:", f"  github: {quote_yaml_scalar(str(repo['github']))}",
                  f"  ref: {quote_yaml_scalar(ref)}", "", "docs:", "  hello_world: |"])
    lines.extend(f"    {line}" if line else "    " for line in docs["hello_world_lines"])
    lines.append("  extended_description: |")
    lines.extend(f"    {line}" if line else "    " for line in body)
    return "\n".join(lines) + "\n"


def main(argv: list[str]) -> int:
    repo_root = Path(argv[1]).resolve() if len(argv) > 1 else Path(__file__).resolve().parents[1]
    manifest = load_manifest(repo_root / "functions.yaml")
    version = json.loads((repo_root / "ducksassy-package.json").read_text(encoding="utf-8"))["version"]
    reference = repo_root / "docs" / "functions.md"
    reference.write_text(render_reference(manifest["functions"]), encoding="utf-8")
    print(f"Rendered {len(manifest['functions'])} function entries into {reference}")
    # Like DuckHTS, community-extensions/ is an untracked checkout of the fork.
    fork = repo_root / "community-extensions"
    if fork.is_dir():
        name = manifest["community_extension"]["extension"]["name"]
        descriptor = fork / "extensions" / name / "description.yml"
        descriptor.parent.mkdir(parents=True, exist_ok=True)
        descriptor.write_text(render_description_yaml(repo_root, manifest, version), encoding="utf-8")
        print(f"Rendered community extension descriptor into {descriptor}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
