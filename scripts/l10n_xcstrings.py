#!/usr/bin/env python3

from __future__ import annotations

import argparse
import csv
import dataclasses
import json
import re
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any, Iterable


DEFAULT_TARGETS: dict[str, Path] = {
    "ios": Path("FptnVPN/Resources/Localizable.xcstrings"),
    "macos": Path("Fptn-macOS/Resources/Localizable.xcstrings"),
    "tvos": Path("Fptn-tvOS/Resources/Localizable.xcstrings"),
}

DEFAULT_OUT_DIR = Path("build/l10n")


@dataclasses.dataclass(frozen=True)
class StringUnit:
    value: str | None
    state: str | None


@dataclasses.dataclass
class Entry:
    key: str
    extraction_state: str | None
    localizations: dict[str, StringUnit]
    unsupported_localizations: set[str]


_FORMAT_PLACEHOLDER_RE = re.compile(
    r"%(?:\d+\$)?(?:[-+ #0]*\d*(?:\.\d+)?)?(?:hh|h|ll|l|j|z|t|L)?[@A-Za-z]"
)


def _read_json(path: Path) -> dict[str, Any]:
    with path.open("r", encoding="utf-8") as f:
        return json.load(f)


def _write_json(path: Path, data: dict[str, Any]) -> None:
    # Try to keep a Xcode-like style: it typically uses a space before and after ':'
    # (`"key" : "value"`). This is still valid JSON.
    text = json.dumps(
        data,
        ensure_ascii=False,
        indent=2,
        sort_keys=False,
        separators=(",", " : "),
    )
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text + "\n", encoding="utf-8")


def _normalize_placeholder(token: str) -> str:
    # Normalize away positional selectors (%1$@) and keep only placeholder kind.
    # This reduces false-positive mismatches when en uses positional args.
    if token.endswith("@"):  # %@, %1$@
        return "%@"
    # Keep the format type as a single char (lowercased).
    # Example: %d, %f, %s, %D -> %d
    return f"%{token[-1].lower()}"


def _extract_placeholders(s: str | None) -> tuple[str, ...]:
    if not s:
        return ()
    # Ignore escaped percent.
    s = s.replace("%%", "")
    raw = _FORMAT_PLACEHOLDER_RE.findall(s)
    return tuple(_normalize_placeholder(t) for t in raw)


def _placeholder_multiset(s: str | None) -> Counter[str]:
    return Counter(_extract_placeholders(s))


def _is_token_like(s: str) -> bool:
    # Heuristic for things that are expected to stay identical across locales.
    if s.startswith("@"):
        return True
    if re.fullmatch(r"https?://\S+", s):
        return True
    if re.fullmatch(r"%[\w@.$+-]+", s):
        return True
    if re.fullmatch(r"[A-Z0-9 _.-]{2,}", s):
        return True
    return False


def _load_xcstrings(path: Path) -> tuple[dict[str, Any], str | None, list[Entry]]:
    doc = _read_json(path)
    source_language = doc.get("sourceLanguage")

    entries: list[Entry] = []
    strings_obj = doc.get("strings") or {}
    if not isinstance(strings_obj, dict):
        raise ValueError(f"Expected 'strings' to be a dict in {path}")

    for key, entry_obj in strings_obj.items():
        if not isinstance(entry_obj, dict):
            continue

        extraction_state = entry_obj.get("extractionState")
        if extraction_state is not None and not isinstance(extraction_state, str):
            extraction_state = None

        localizations: dict[str, StringUnit] = {}
        unsupported: set[str] = set()

        locs = entry_obj.get("localizations")
        if isinstance(locs, dict):
            for locale, loc_obj in locs.items():
                if not isinstance(locale, str) or not isinstance(loc_obj, dict):
                    continue

                # Supported shape: { "stringUnit": { "state": "translated", "value": "..." } }
                string_unit = loc_obj.get("stringUnit")
                if isinstance(string_unit, dict):
                    value = string_unit.get("value")
                    state = string_unit.get("state")
                    if value is not None and not isinstance(value, str):
                        value = None
                    if state is not None and not isinstance(state, str):
                        state = None
                    localizations[locale] = StringUnit(value=value, state=state)
                else:
                    # Future-proofing: variations/plurals/etc.
                    unsupported.add(locale)

        entries.append(
            Entry(
                key=str(key),
                extraction_state=extraction_state,
                localizations=localizations,
                unsupported_localizations=unsupported,
            )
        )

    return doc, source_language, entries


def _iter_locales(entries: Iterable[Entry]) -> list[str]:
    locales: set[str] = set()
    for entry in entries:
        locales.update(entry.localizations.keys())
        locales.update(entry.unsupported_localizations)
    return sorted(locales)


def export_tsv(xcstrings_path: Path, out_path: Path, locales: list[str] | None) -> None:
    _, source_language, entries = _load_xcstrings(xcstrings_path)

    if locales is None:
        locales = _iter_locales(entries)

    out_path.parent.mkdir(parents=True, exist_ok=True)

    with out_path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f, delimiter="\t", quoting=csv.QUOTE_MINIMAL)

        header: list[str] = [
            "key",
            "sourceLanguage",
            "extractionState",
            "unsupported",
            "sourceText",
            "sourcePlaceholders",
        ]
        for locale in locales:
            header.extend([f"{locale}.value", f"{locale}.state"])  # state can be blank
        writer.writerow(header)

        for entry in sorted(entries, key=lambda e: e.key):
            source_unit = entry.localizations.get(source_language or "")
            source_text = (
                source_unit.value
                if source_unit and isinstance(source_unit.value, str) and source_unit.value != ""
                else entry.key
            )
            source_placeholders = " ".join(_extract_placeholders(source_text))
            unsupported = " ".join(sorted(entry.unsupported_localizations))

            row: list[str] = [
                entry.key,
                source_language or "",
                entry.extraction_state or "",
                unsupported,
                source_text,
                source_placeholders,
            ]
            for locale in locales:
                unit = entry.localizations.get(locale)
                row.append(unit.value if unit and unit.value is not None else "")
                row.append(unit.state if unit and unit.state is not None else "")

            writer.writerow(row)


@dataclasses.dataclass(frozen=True)
class Report:
    total_keys: int
    locales: tuple[str, ...]
    missing_by_locale: dict[str, int]
    non_translated_by_locale: dict[str, int]
    same_as_source_by_locale: dict[str, int]
    placeholder_mismatches: int
    trailing_space_keys: int
    near_duplicate_groups: int


def _build_report(entries: list[Entry], source_language: str | None) -> Report:
    locales = _iter_locales(entries)

    # Coverage/lints are most useful for non-source locales.
    coverage_locales = [l for l in locales if l and l != (source_language or "")]

    missing_by_locale: Counter[str] = Counter()
    non_translated_by_locale: Counter[str] = Counter()
    same_as_source_by_locale: Counter[str] = Counter()

    placeholder_mismatches = 0
    trailing_space_keys = 0

    for entry in entries:
        if entry.key != entry.key.rstrip() or entry.key != entry.key.lstrip():
            trailing_space_keys += 1

        source_value = entry.localizations.get(source_language or "")
        baseline = source_value.value if (source_value and source_value.value) else entry.key
        baseline_placeholders = _placeholder_multiset(baseline)

        for locale in coverage_locales:
            unit = entry.localizations.get(locale)
            if unit is None or (unit.value is None) or unit.value == "":
                missing_by_locale[locale] += 1
                continue

            if unit.state and unit.state != "translated":
                non_translated_by_locale[locale] += 1

            if unit.value == baseline and not _is_token_like(baseline):
                same_as_source_by_locale[locale] += 1

            loc_placeholders = _placeholder_multiset(unit.value)
            if baseline_placeholders != loc_placeholders:
                # Placeholders are a common source of runtime crashes or broken formatting.
                placeholder_mismatches += 1

    # Near-duplicate keys (helps spot accidental duplicates or punctuation variants)
    def normalize_key(k: str) -> str:
        k = k.replace("…", "...")
        k = k.replace("—", "-")
        k = k.replace("–", "-")
        k = re.sub(r"\s+", " ", k.strip())
        return k.lower()

    groups: dict[str, list[str]] = defaultdict(list)
    for entry in entries:
        groups[normalize_key(entry.key)].append(entry.key)

    near_duplicate_groups = sum(1 for keys in groups.values() if len(set(keys)) > 1)

    return Report(
        total_keys=len(entries),
        locales=tuple(locales),
        missing_by_locale=dict(missing_by_locale),
        non_translated_by_locale=dict(non_translated_by_locale),
        same_as_source_by_locale=dict(same_as_source_by_locale),
        placeholder_mismatches=placeholder_mismatches,
        trailing_space_keys=trailing_space_keys,
        near_duplicate_groups=near_duplicate_groups,
    )


def report_markdown(xcstrings_path: Path) -> str:
    _, source_language, entries = _load_xcstrings(xcstrings_path)
    rep = _build_report(entries, source_language)

    lines: list[str] = []
    lines.append(f"# Localization report: {xcstrings_path}")
    lines.append("")
    lines.append(f"- Total keys: {rep.total_keys}")
    lines.append(f"- Locales seen: {', '.join(rep.locales) if rep.locales else '(none)'}")
    lines.append(f"- Placeholder mismatches: {rep.placeholder_mismatches}")
    lines.append(f"- Keys with leading/trailing whitespace: {rep.trailing_space_keys}")
    lines.append(f"- Near-duplicate key groups: {rep.near_duplicate_groups}")
    lines.append("")

    if rep.locales:
        lines.append("## Coverage")
        lines.append("")
        lines.append("| locale | missing | non-translated state | same-as-source |")
        lines.append("|---|---:|---:|---:|")
        for locale in rep.locales:
            lines.append(
                "| {loc} | {missing} | {non_translated} | {same} |".format(
                    loc=locale,
                    missing=rep.missing_by_locale.get(locale, 0),
                    non_translated=rep.non_translated_by_locale.get(locale, 0),
                    same=rep.same_as_source_by_locale.get(locale, 0),
                )
            )
        lines.append("")

    lines.append("## Notes")
    lines.append("")
    lines.append("- `same-as-source` excludes obvious tokens (handles/URLs/acronyms).")
    lines.append("- `placeholder mismatches` compares normalized placeholders (positional-safe) against the source-language value if present, else the key.")
    lines.append("")

    return "\n".join(lines)


def compare_tsv(targets: dict[str, Path], out_path: Path) -> None:
    per_target_keys: dict[str, set[str]] = {}
    for name, path in targets.items():
        _, _, entries = _load_xcstrings(path)
        per_target_keys[name] = {e.key for e in entries}

    all_keys: set[str] = set()
    for keys in per_target_keys.values():
        all_keys.update(keys)

    out_path.parent.mkdir(parents=True, exist_ok=True)
    with out_path.open("w", encoding="utf-8", newline="") as f:
        writer = csv.writer(f, delimiter="\t")
        header = ["key"] + [f"in.{name}" for name in targets.keys()]
        writer.writerow(header)
        for key in sorted(all_keys):
            row = [key]
            for name in targets.keys():
                row.append("1" if key in per_target_keys[name] else "0")
            writer.writerow(row)


def _parse_tsv(path: Path) -> tuple[list[str], list[dict[str, str]]]:
    with path.open("r", encoding="utf-8", newline="") as f:
        reader = csv.DictReader(f, delimiter="\t")
        if reader.fieldnames is None:
            raise ValueError(f"TSV has no header: {path}")
        rows = [dict(row) for row in reader]
        return list(reader.fieldnames), rows


def import_tsv(
    xcstrings_path: Path,
    tsv_path: Path,
    out_path: Path,
    *,
    add_keys: bool,
    fill_missing_only: bool,
    set_translated: bool,
    strict_placeholders: bool,
    dry_run: bool,
) -> None:
    doc, source_language, entries = _load_xcstrings(xcstrings_path)
    strings_obj = doc.setdefault("strings", {})
    if not isinstance(strings_obj, dict):
        raise ValueError(f"Expected 'strings' to be a dict in {xcstrings_path}")

    header, rows = _parse_tsv(tsv_path)
    if "key" not in header:
        raise ValueError("TSV must contain a 'key' column")

    locales: list[str] = []
    for col in header:
        if col.endswith(".value"):
            locales.append(col[: -len(".value")])

    changes = 0
    skipped_unsupported = 0
    placeholder_errors: list[str] = []

    for row in rows:
        key = (row.get("key") or "").strip("\ufeff")
        if not key:
            continue

        entry_obj = strings_obj.get(key)
        if entry_obj is None:
            if not add_keys:
                continue
            entry_obj = {}
            strings_obj[key] = entry_obj
        if not isinstance(entry_obj, dict):
            continue

        locs = entry_obj.setdefault("localizations", {})
        if not isinstance(locs, dict):
            continue

        # Baseline for placeholder validation: prefer source-language value, else key.
        baseline = key
        if source_language:
            try:
                locs_existing = entry_obj.get("localizations") if isinstance(entry_obj, dict) else None
                if isinstance(locs_existing, dict):
                    src_obj = locs_existing.get(source_language)
                    if isinstance(src_obj, dict):
                        su = src_obj.get("stringUnit")
                        if isinstance(su, dict) and isinstance(su.get("value"), str) and su.get("value"):
                            baseline = su["value"]
            except Exception:
                baseline = key

        baseline_placeholders = _placeholder_multiset(baseline)

        for locale in locales:
            value = row.get(f"{locale}.value")
            if value is None:
                continue

            if value == "":
                continue

            loc_obj = locs.get(locale)
            if loc_obj is None:
                loc_obj = {}
                locs[locale] = loc_obj

            if not isinstance(loc_obj, dict):
                continue

            # If this localization isn't a stringUnit, we avoid rewriting it.
            if "stringUnit" not in loc_obj and any(k in loc_obj for k in ("variations", "substitutions")):
                skipped_unsupported += 1
                continue

            string_unit = loc_obj.get("stringUnit")
            if string_unit is None:
                string_unit = {}
                loc_obj["stringUnit"] = string_unit
            if not isinstance(string_unit, dict):
                skipped_unsupported += 1
                continue

            current_value = string_unit.get("value")
            if fill_missing_only and isinstance(current_value, str) and current_value != "":
                continue

            if strict_placeholders:
                loc_placeholders = _placeholder_multiset(value)
                if baseline_placeholders != loc_placeholders:
                    placeholder_errors.append(
                        f"{key} [{locale}]: placeholders {sorted(loc_placeholders.elements())} != {sorted(baseline_placeholders.elements())}"
                    )
                    continue

            if isinstance(current_value, str) and current_value == value:
                continue

            string_unit["value"] = value
            if set_translated:
                string_unit["state"] = "translated"

            changes += 1

        # Keep top-level sourceLanguage consistent if present in file.
        if source_language and doc.get("sourceLanguage") != source_language:
            doc["sourceLanguage"] = source_language

    if placeholder_errors and strict_placeholders:
        msg = "\n".join(placeholder_errors[:50])
        raise ValueError(f"Placeholder mismatches (showing up to 50):\n{msg}")

    if dry_run:
        print(f"Dry-run: would apply {changes} change(s)")
        if skipped_unsupported:
            print(f"Skipped unsupported localizations: {skipped_unsupported}")
        return

    _write_json(out_path, doc)
    print(f"Wrote {out_path} (changes: {changes}, skipped unsupported: {skipped_unsupported})")


def _resolve_target_paths(all_targets: bool, target_names: list[str], file_paths: list[str]) -> dict[str, Path]:
    result: dict[str, Path] = {}

    if all_targets:
        result.update(DEFAULT_TARGETS)

    for name in target_names:
        if name not in DEFAULT_TARGETS:
            raise ValueError(f"Unknown target: {name}. Known: {', '.join(DEFAULT_TARGETS.keys())}")
        result[name] = DEFAULT_TARGETS[name]

    for i, p in enumerate(file_paths):
        result[f"file{i+1}"] = Path(p)

    if not result:
        raise ValueError("No input files: use --all, --target, or --file")

    return result


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        prog="l10n_xcstrings.py",
        description="Export/import Xcode .xcstrings localization files as TSV + generate reports.",
    )
    sub = parser.add_subparsers(dest="cmd", required=True)

    p_export = sub.add_parser("export", help="Export .xcstrings to TSV")
    p_export.add_argument("--all", action="store_true", help="Export all default targets (ios/macos/tvos)")
    p_export.add_argument("--target", action="append", default=[], help="Target name: ios|macos|tvos (repeatable)")
    p_export.add_argument("--file", action="append", default=[], help="Path to a .xcstrings file (repeatable)")
    p_export.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR, help="Output directory")
    p_export.add_argument(
        "--locales",
        help="Comma-separated locale list (default: auto-detect from file)",
    )

    p_report = sub.add_parser("report", help="Generate a Markdown report")
    p_report.add_argument("--all", action="store_true")
    p_report.add_argument("--target", action="append", default=[])
    p_report.add_argument("--file", action="append", default=[])
    p_report.add_argument("--out-dir", type=Path, default=DEFAULT_OUT_DIR)

    p_compare = sub.add_parser("compare", help="Compare keys across targets")
    p_compare.add_argument("--out", type=Path, default=DEFAULT_OUT_DIR / "compare.tsv")

    p_import = sub.add_parser("import", help="Import TSV back into a .xcstrings file")
    p_import.add_argument("--xcstrings", type=Path, required=True)
    p_import.add_argument("--tsv", type=Path, required=True)
    p_import.add_argument("--out", type=Path, help="Output path (required unless --in-place or --dry-run)")
    p_import.add_argument("--in-place", action="store_true", help="Overwrite the .xcstrings file")
    p_import.add_argument(
        "--add-keys",
        action="store_true",
        help="Allow creating brand-new keys that exist in TSV but not in the .xcstrings file",
    )
    p_import.add_argument("--fill-missing-only", action="store_true")
    p_import.add_argument("--set-translated", action="store_true", help="Set stringUnit.state=translated for updated cells")
    p_import.add_argument("--strict-placeholders", action="store_true", help="Fail/skip rows with placeholder mismatches")
    p_import.add_argument("--dry-run", action="store_true")

    args = parser.parse_args(argv)

    try:
        if args.cmd == "export":
            locales = args.locales.split(",") if args.locales else None
            targets = _resolve_target_paths(args.all, args.target, args.file)
            for name, path in targets.items():
                out_path = args.out_dir / f"{name}.tsv"
                export_tsv(path, out_path, locales)
                print(f"Exported {path} -> {out_path}")
            return 0

        if args.cmd == "report":
            targets = _resolve_target_paths(args.all, args.target, args.file)
            args.out_dir.mkdir(parents=True, exist_ok=True)
            for name, path in targets.items():
                md = report_markdown(path)
                out_path = args.out_dir / f"{name}.report.md"
                out_path.write_text(md + "\n", encoding="utf-8")
                print(f"Wrote {out_path}")
            return 0

        if args.cmd == "compare":
            compare_tsv(DEFAULT_TARGETS, args.out)
            print(f"Wrote {args.out}")
            return 0

        if args.cmd == "import":
            if args.in_place and args.out is not None:
                raise ValueError("Use either --in-place or --out, not both")
            if not args.dry_run and not args.in_place and args.out is None:
                raise ValueError("Provide --out, or use --in-place, or use --dry-run")

            out_path = args.xcstrings if args.in_place else (args.out or args.xcstrings)
            # Import implementation currently creates missing keys; gate that behind --add-keys.
            if not args.add_keys:
                # Remove rows whose keys don't exist to avoid accidental additions.
                doc_tmp = _read_json(args.xcstrings)
                existing = doc_tmp.get("strings")
                if isinstance(existing, dict):
                    _, rows_tmp = _parse_tsv(args.tsv)
                    missing_keys = [r.get("key") for r in rows_tmp if r.get("key") and r.get("key") not in existing]
                    if missing_keys:
                        print(
                            f"ERROR: TSV contains {len(missing_keys)} key(s) not present in {args.xcstrings}. Use --add-keys to allow creation.",
                            file=sys.stderr,
                        )
                        return 2

            import_tsv(
                args.xcstrings,
                args.tsv,
                out_path,
                add_keys=args.add_keys,
                fill_missing_only=args.fill_missing_only,
                set_translated=args.set_translated,
                strict_placeholders=args.strict_placeholders,
                dry_run=args.dry_run,
            )
            return 0

        raise ValueError(f"Unknown command: {args.cmd}")

    except Exception as e:
        print(f"ERROR: {e}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
