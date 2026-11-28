#!/usr/bin/env python3
"""
CRAP (Change Risk Anti-Patterns) Score Analyzer for ClassicCommander
Calculates cyclomatic complexity, code coverage, and CRAP risk scores for all methods.

Formula:
  CRAP(m) = comp(m)^2 * (1 - cov(m))^3 + comp(m)

Where:
  comp(m) = cyclomatic complexity of method m
  cov(m)  = code coverage of method m (0.0 to 1.0)

Standard CRAP threshold is 30.0, but ClassicCommander targets a strict threshold of <= 6.0.
Methods with CRAP > 6.0 are errors, and 4.0 to 6.0 are warnings.
Reference: https://testing.googleblog.com/2011/02/this-code-is-crap.html
"""

import argparse
import datetime
import html
import json
import os
import re
import subprocess
import sys


def strip_comments_and_strings(source_text: str) -> str:
    """Removes comments and string literals to prevent false positives in complexity counting."""
    # Remove multi-line comments /* ... */
    text = re.sub(r"/\*.*?\*/", " ", source_text, flags=re.DOTALL)
    # Remove single-line comments // ...
    text = re.sub(r"//.*", " ", text)
    # Remove multi-line strings """ ... """
    text = re.sub(r'""".*?"""', " ", text, flags=re.DOTALL)
    # Remove single-line strings " ... "
    text = re.sub(r'"(?:\\.|[^"\\])*"', " ", text)
    return text


def calculate_cyclomatic_complexity(source_code: str) -> int:
    """
    Calculates cyclomatic complexity for a Swift function body.
    Base complexity is 1.
    Each decision point adds 1:
      - if, guard, for, while, repeat, catch, case
      - logical operators: &&, ||
      - nil-coalescing: ??
      - ternary conditional: ? :
    """
    clean = strip_comments_and_strings(source_code)
    # Control flow keywords
    kw_count = len(re.findall(r"\b(if|guard|for|while|repeat|catch)\b", clean))
    # Switch cases (excluding default)
    case_count = len(re.findall(r"\bcase\b", clean))
    # Logical & nil-coalescing operators
    ops_count = len(re.findall(r"(&&|\|\||\?\?)", clean))
    # Ternary operator: ? with spaces around it
    ternary_count = len(re.findall(r"(?<=\s)\?(?=\s)", clean))

    return 1 + kw_count + case_count + ops_count + ternary_count


def calculate_crap(complexity: int, coverage_fraction: float) -> float:
    """
    Computes CRAP score:
      CRAP = comp^2 * (1 - cov)^3 + comp
    """
    cov = max(0.0, min(1.0, coverage_fraction))
    comp = float(complexity)
    crap = (comp**2) * ((1.0 - cov) ** 3) + comp
    return round(crap, 2)


def demangle_symbols(symbols: list) -> list:
    """Batch-demangles Swift symbols using xcrun swift-demangle."""
    if not symbols:
        return []
    try:
        proc = subprocess.run(
            ["xcrun", "swift-demangle", "--simplified", "--compact"],
            input="\n".join(symbols),
            capture_output=True,
            text=True,
            check=True,
        )
        results = proc.stdout.splitlines()
        # If output line count matches, return; otherwise fallback
        if len(results) == len(symbols):
            cleaned = []
            for item in results:
                # Strip file path prefixes like "Sources/App/Foo.swift:"
                if ":" in item and "Sources/App/" in item:
                    item = item.split(":", 1)[1].strip()
                cleaned.append(item)
            return cleaned
    except Exception:
        pass
    return symbols


def extract_function_data(
    export_json_path: str,
    project_dir: str,
    include_implicit: bool = False,
    threshold: float = 6.0,
    warning_threshold: float = 4.0,
) -> dict:
    """Parses llvm-cov export.json and computes CRAP scores for all functions in Sources/App/."""
    if not os.path.exists(export_json_path):
        raise FileNotFoundError(f"Export file not found: {export_json_path}")

    with open(export_json_path, "r", encoding="utf-8") as f:
        cov_data = json.load(f)

    root = os.path.abspath(project_dir) + "/"
    all_functions = cov_data.get("data", [{}])[0].get("functions", [])

    # Filter for functions belonging to Sources/App/
    app_funcs = []
    for fn in all_functions:
        filenames = fn.get("filenames", [])
        if filenames and "Sources/App/" in filenames[0]:
            app_funcs.append(fn)

    raw_symbols = [fn["name"] for fn in app_funcs]
    demangled = demangle_symbols(raw_symbols)

    file_cache = {}
    records = []
    skipped_implicit = 0

    for fn, dname in zip(app_funcs, demangled):
        if not include_implicit and "implicit closure" in dname:
            skipped_implicit += 1
            continue

        filepath = fn["filenames"][0]
        rel_path = filepath.replace(root, "")
        regions = [
            r for r in fn.get("regions", []) if len(r) <= 7 or r[7] == 0
        ]
        if not regions:
            continue

        start_line = regions[0][0]
        end_line = max(r[2] for r in regions)

        if filepath not in file_cache:
            try:
                with open(filepath, "r", encoding="utf-8", errors="replace") as sf:
                    file_cache[filepath] = sf.readlines()
            except IOError:
                file_cache[filepath] = []

        lines = file_cache[filepath]
        body = "".join(lines[max(0, start_line - 1) : min(len(lines), end_line)])
        complexity = calculate_cyclomatic_complexity(body)

        # Region coverage
        cov_regions = sum(1 for r in regions if r[4] > 0)
        tot_regions = len(regions)
        reg_cov_fraction = (
            (cov_regions / tot_regions)
            if tot_regions > 0
            else (1.0 if fn.get("count", 0) > 0 else 0.0)
        )

        # Line coverage
        line_hits = {}
        for r in regions:
            for ln in range(r[0], r[2] + 1):
                line_hits[ln] = line_hits.get(ln, 0) + r[4]
        tot_lines = len(line_hits)
        cov_lines = sum(1 for cnt in line_hits.values() if cnt > 0)
        line_cov_fraction = (cov_lines / tot_lines) if tot_lines > 0 else 1.0

        # We use region coverage as the primary metric for CRAP as it covers expression branches
        cov_fraction = reg_cov_fraction
        crap_score = calculate_crap(complexity, cov_fraction)
        is_crap = crap_score > threshold

        records.append(
            {
                "id": f"{rel_path}:{start_line}:{dname}",
                "file": rel_path,
                "line": start_line,
                "end_line": end_line,
                "name": dname,
                "raw_symbol": fn["name"],
                "call_count": fn.get("count", 0),
                "complexity": complexity,
                "coverage": round(cov_fraction * 100, 1),
                "line_coverage": round(line_cov_fraction * 100, 1),
                "covered_regions": cov_regions,
                "total_regions": tot_regions,
                "crap": crap_score,
                "is_crap": is_crap,
            }
        )

    # Sort descending by CRAP score
    records.sort(key=lambda r: (r["crap"], r["complexity"]), reverse=True)

    total_funcs = len(records)
    crap_funcs = sum(1 for r in records if r["is_crap"])
    warning_funcs = sum(
        1 for r in records if warning_threshold <= r["crap"] <= threshold
    )
    healthy_funcs = sum(1 for r in records if r["crap"] < warning_threshold)
    zero_cov_funcs = sum(1 for r in records if r["coverage"] == 0.0)

    avg_crap = (
        round(sum(r["crap"] for r in records) / total_funcs, 2)
        if total_funcs
        else 0.0
    )
    max_crap = max((r["crap"] for r in records), default=0.0)
    avg_comp = (
        round(sum(r["complexity"] for r in records) / total_funcs, 2)
        if total_funcs
        else 0.0
    )
    avg_cov = (
        round(sum(r["coverage"] for r in records) / total_funcs, 1)
        if total_funcs
        else 0.0
    )

    summary = {
        "total_functions": total_funcs,
        "crap_functions": crap_funcs,
        "crap_percentage": (
            round((crap_funcs / total_funcs) * 100, 2) if total_funcs else 0.0
        ),
        "warning_functions": warning_funcs,
        "healthy_functions": healthy_funcs,
        "zero_coverage_functions": zero_cov_funcs,
        "average_crap": avg_crap,
        "max_crap": max_crap,
        "average_complexity": avg_comp,
        "average_coverage": avg_cov,
        "skipped_implicit_closures": skipped_implicit,
    }

    return {
        "generated_at": datetime.datetime.now(datetime.timezone.utc).isoformat(),
        "threshold": threshold,
        "warning_threshold": warning_threshold,
        "summary": summary,
        "functions": records,
    }


def _risk_hotspots(functions: list, limit: int = 8) -> list:
    """Groups over-limit and warning functions by file, worst files first."""
    by_file = {}
    for fn in functions:
        entry = by_file.setdefault(
            fn["file"], {"file": fn["file"], "crap": 0, "total": 0, "worst": 0.0}
        )
        entry["total"] += 1
        entry["worst"] = max(entry["worst"], fn["crap"])
        if fn["is_crap"]:
            entry["crap"] += 1
    ranked = [e for e in by_file.values() if e["crap"] > 0]
    ranked.sort(key=lambda e: (e["crap"], e["worst"]), reverse=True)
    return ranked[:limit]


def _format_generated_at(stamp: str) -> str:
    """Formats an ISO timestamp as '28 Nov 2026, 09:29 UTC'."""
    try:
        moment = datetime.datetime.fromisoformat(stamp).astimezone(
            datetime.timezone.utc
        )
    except ValueError:
        return stamp
    return f"{moment.day} {moment:%b %Y, %H:%M} UTC"


def _hotspots_html(hotspots: list) -> str:
    """Renders the hotspot list items; each one filters the table to its file."""
    if not hotspots:
        return '<li class="hs-empty">No function is over the limit.</li>'
    top = hotspots[0]["crap"]
    items = []
    for spot in hotspots:
        path = spot["file"]
        directory, _, name = path.rpartition("/")
        width = round(spot["crap"] / top * 100, 1)
        items.append(
            f'<li><button type="button" class="hs" data-file="{html.escape(path)}" '
            f'title="Show functions in {html.escape(path)}">'
            f'<span class="hs-name">{html.escape(name)}</span>'
            f'<span class="hs-dir">{html.escape(directory.replace("Sources/App", "App", 1))}</span>'
            f'<span class="hs-bar"><span style="width:{width}%"></span></span>'
            f'<span class="hs-n">{spot["crap"]}<span class="hs-of">/{spot["total"]}</span></span>'
            f"</button></li>"
        )
    return "\n".join(items)


def generate_html_report(data: dict) -> str:
    """Generates a self-contained, offline HTML report with live filtering, sorting, and stats."""
    summary = data["summary"]
    threshold = data["threshold"]
    warning_threshold = data.get("warning_threshold", 4.0)
    functions = data["functions"]
    total = summary["total_functions"] or 1

    directories = sorted({os.path.dirname(fn["file"]) for fn in functions})
    dir_options = "\n".join(
        f'<option value="{html.escape(d)}/">{html.escape(d.replace("Sources/App", "App", 1))}</option>'
        for d in directories
    )

    def share(count: int) -> str:
        return f"{count / total * 100:.4g}"

    replacements = {
        "%%GENERATED%%": html.escape(_format_generated_at(data["generated_at"])),
        "%%TOTAL%%": f"{summary['total_functions']:,}",
        "%%CRAP_N%%": f"{summary['crap_functions']:,}",
        "%%CRAP_PCT%%": f"{summary['crap_percentage']:.1f}",
        "%%WARN_N%%": f"{summary['warning_functions']:,}",
        "%%OK_N%%": f"{summary['healthy_functions']:,}",
        "%%ZERO_N%%": f"{summary['zero_coverage_functions']:,}",
        "%%CRAP_W%%": share(summary["crap_functions"]),
        "%%WARN_W%%": share(summary["warning_functions"]),
        "%%OK_W%%": share(summary["healthy_functions"]),
        "%%MAX%%": f"{summary['max_crap']:.1f}",
        "%%AVG_CX%%": f"{summary['average_complexity']:.1f}",
        "%%AVG_COV%%": f"{summary['average_coverage']:.1f}",
        "%%SKIPPED%%": f"{summary.get('skipped_implicit_closures', 0):,}",
        "%%T%%": f"{threshold:g}",
        "%%W%%": f"{warning_threshold:g}",
        "%%DIR_OPTIONS%%": dir_options,
        "%%HOTSPOTS%%": _hotspots_html(_risk_hotspots(functions)),
        "%%T_JS%%": json.dumps(threshold),
        "%%W_JS%%": json.dumps(warning_threshold),
        # Escape "</" so no identifier can ever close the <script> element.
        "%%DATA%%": json.dumps(functions, separators=(",", ":")).replace("</", "<\\/"),
    }
    page = HTML_TEMPLATE
    for token, value in replacements.items():
        page = page.replace(token, value)
    return page


HTML_TEMPLATE = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>CRAP report · ClassicCommander</title>
<style>
  :root {
    --paper: #f5f4f0;
    --surface: #ffffff;
    --ink: #1a1c1e;
    --ink-2: #53575c;
    --ink-3: #868a8f;
    --rule: #e2e0d9;
    --rule-2: #cdc9bf;
    --track: #ebe9e3;
    --crap: #b3261e;
    --crap-tint: #fbe8e5;
    --warn: #9a5b00;
    --warn-tint: #fcf0d9;
    --ok: #2e6b4c;
    --ok-tint: #e3f0e8;
    --ok-bar: #8fb9a1;
    --focus: #2357d9;
    --mono: ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace;
    --sans: -apple-system, BlinkMacSystemFont, "Inter", "Segoe UI", Helvetica, Arial, sans-serif;
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --paper: #131416;
      --surface: #1b1c1f;
      --ink: #ecebe7;
      --ink-2: #a8aaad;
      --ink-3: #74777b;
      --rule: #2a2c30;
      --rule-2: #3a3d42;
      --track: #2a2c30;
      --crap: #ff8a7a;
      --crap-tint: #3a1d1a;
      --warn: #f0b75a;
      --warn-tint: #36290f;
      --ok: #79c99e;
      --ok-tint: #17301f;
      --ok-bar: #3f7a5b;
      --focus: #7ea2ff;
    }
  }

  * { box-sizing: border-box; }
  html { -webkit-text-size-adjust: 100%; }
  body {
    margin: 0;
    background: var(--paper);
    color: var(--ink);
    font: 14px/1.45 var(--sans);
    font-variant-numeric: tabular-nums;
  }
  .page { max-width: 1240px; margin: 0 auto; padding: 28px 32px 48px; }
  :focus-visible { outline: 2px solid var(--focus); outline-offset: 2px; border-radius: 4px; }
  button, input, select { font: inherit; color: inherit; }
  .num { font-variant-numeric: tabular-nums; }

  /* Masthead */
  .mast {
    display: flex; align-items: baseline; justify-content: space-between;
    gap: 8px 24px; flex-wrap: wrap;
    padding-bottom: 14px; border-bottom: 1px solid var(--rule);
  }
  .mast h1 { margin: 0; font-size: 15px; font-weight: 600; letter-spacing: -0.005em; }
  .mast h1 span { color: var(--ink-3); font-weight: 400; margin: 0 6px; }
  .mast p { margin: 0; color: var(--ink-3); font-size: 13px; }

  /* Overview */
  .overview {
    display: grid; grid-template-columns: minmax(0, 1.35fr) minmax(0, 1fr);
    gap: 48px; padding: 32px 0 36px;
  }
  .eyebrow { margin: 0 0 10px; font-size: 13px; color: var(--ink-2); }
  .verdict-n { display: flex; align-items: baseline; gap: 14px; flex-wrap: wrap; }
  .verdict-n strong {
    font-size: 64px; line-height: 0.95; font-weight: 600; letter-spacing: -0.035em; color: var(--crap);
  }
  .verdict-n span { font-size: 17px; color: var(--ink-2); }
  .verdict-n span b { color: var(--ink); font-weight: 600; }

  .dist { display: flex; height: 10px; margin: 26px 0 10px; border-radius: 2px; overflow: hidden; gap: 2px; }
  .dist i { display: block; min-width: 2px; }
  .dist .d-ok { background: var(--ok-bar); }
  .dist .d-warn { background: var(--warn); opacity: .75; }
  .dist .d-crap { background: var(--crap); }
  .legend { display: flex; gap: 6px 22px; flex-wrap: wrap; margin: 0; padding: 0; list-style: none; font-size: 13px; color: var(--ink-2); }
  .legend li { display: flex; align-items: center; gap: 7px; }
  .legend b { color: var(--ink); font-weight: 600; }
  .sw { width: 8px; height: 8px; border-radius: 1px; display: inline-block; }

  .facts {
    display: grid; grid-template-columns: repeat(4, auto); justify-content: start;
    gap: 0 36px; margin: 30px 0 0; padding-top: 18px; border-top: 1px solid var(--rule);
  }
  .facts div { display: flex; flex-direction: column-reverse; gap: 2px; }
  .facts dt { font-size: 12px; color: var(--ink-3); }
  .facts dd { margin: 0; font-size: 20px; font-weight: 600; letter-spacing: -0.01em; }
  .facts dd small { font-size: 13px; font-weight: 400; color: var(--ink-3); margin-left: 1px; }

  .hotspots h2, .list-head h2 { margin: 0; font-size: 13px; font-weight: 600; }
  .hotspots header { display: flex; justify-content: space-between; align-items: baseline; margin-bottom: 8px; }
  .hotspots header p { margin: 0; font-size: 12px; color: var(--ink-3); }
  .hotspots ol { list-style: none; margin: 0; padding: 0; border-top: 1px solid var(--rule); }
  .hotspots li { border-bottom: 1px solid var(--rule); }
  .hs-empty { padding: 12px 0; color: var(--ink-3); }
  .hs {
    width: 100%; display: grid; grid-template-columns: minmax(0, 1fr) 72px 44px;
    grid-template-rows: auto auto; column-gap: 14px; align-items: center;
    padding: 8px 6px; margin: 0; border: 0; background: none; text-align: left; cursor: pointer;
    border-radius: 3px;
  }
  .hs:hover { background: var(--surface); }
  .hs[aria-pressed="true"] { background: var(--surface); box-shadow: inset 2px 0 0 var(--ink); }
  .hs-name { font-family: var(--mono); font-size: 12.5px; font-weight: 500; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
  .hs-dir { grid-row: 2; font-size: 11.5px; color: var(--ink-3); }
  .hs-bar { grid-column: 2; grid-row: 1 / span 2; height: 4px; background: var(--track); border-radius: 2px; overflow: hidden; }
  .hs-bar span { display: block; height: 100%; background: var(--crap); opacity: .85; }
  .hs-n { grid-column: 3; grid-row: 1 / span 2; text-align: right; font-weight: 600; }
  .hs-of { color: var(--ink-3); font-weight: 400; font-size: 12px; }

  /* Function list */
  .list { background: var(--surface); border: 1px solid var(--rule); border-radius: 6px; }
  .list-head { display: flex; justify-content: space-between; align-items: center; gap: 12px; padding: 16px 18px 0; flex-wrap: wrap; }
  .kbd { font-family: var(--mono); font-size: 11px; color: var(--ink-3); border: 1px solid var(--rule-2); border-radius: 3px; padding: 0 4px; }
  .toolbar { display: flex; flex-wrap: wrap; gap: 10px 12px; align-items: center; padding: 12px 18px 14px; border-bottom: 1px solid var(--rule); }
  .search { flex: 1 1 260px; position: relative; }
  .search input {
    width: 100%; height: 32px; padding: 0 10px 0 30px;
    border: 1px solid var(--rule-2); border-radius: 5px; background: var(--paper);
  }
  .search input::placeholder { color: var(--ink-3); }
  .search svg { position: absolute; left: 9px; top: 9px; width: 14px; height: 14px; color: var(--ink-3); }

  .seg { display: inline-flex; border: 1px solid var(--rule-2); border-radius: 5px; padding: 2px; background: var(--paper); flex-wrap: wrap; }
  .seg button {
    border: 0; background: none; height: 26px; padding: 0 10px; border-radius: 3px; cursor: pointer;
    color: var(--ink-2); font-size: 13px; display: inline-flex; align-items: center; gap: 6px; white-space: nowrap;
  }
  .seg button:hover { color: var(--ink); }
  .seg button[aria-pressed="true"] { background: var(--surface); color: var(--ink); box-shadow: 0 0 0 1px var(--rule-2); }
  .seg .c { color: var(--ink-3); font-size: 12px; }
  .field { display: inline-flex; align-items: center; gap: 6px; font-size: 13px; color: var(--ink-2); }
  .field select, .field input {
    height: 32px; border: 1px solid var(--rule-2); border-radius: 5px; background: var(--paper); padding: 0 8px;
  }
  .field input { width: 64px; }
  .chip {
    display: none; align-items: center; gap: 6px; height: 28px; padding: 0 4px 0 10px;
    border-radius: 14px; background: var(--ink); color: var(--paper); font-family: var(--mono); font-size: 12px;
  }
  .chip.on { display: inline-flex; }
  .chip button { border: 0; background: none; color: inherit; width: 20px; height: 20px; border-radius: 10px; cursor: pointer; font-size: 14px; line-height: 1; }
  .chip button:hover { background: rgba(127,127,127,.35); }

  table { width: 100%; border-collapse: collapse; }
  thead th {
    position: sticky; top: 0; z-index: 1; background: var(--surface);
    text-align: left; font-weight: 500; font-size: 12px; color: var(--ink-3);
    padding: 0; border-bottom: 1px solid var(--rule);
  }
  thead th button {
    border: 0; background: none; width: 100%; text-align: inherit; padding: 10px 12px; cursor: pointer;
    color: inherit; font-size: inherit; display: flex; gap: 4px; align-items: center; justify-content: inherit;
  }
  thead th:first-child button { padding-left: 18px; }
  thead th button:hover { color: var(--ink); }
  thead th[aria-sort] button { color: var(--ink); }
  thead th[aria-sort="ascending"] button::after { content: "↑"; }
  thead th[aria-sort="descending"] button::after { content: "↓"; }
  th.r, td.r { text-align: right; }
  th.r button { justify-content: flex-end; }
  tbody td { padding: 9px 12px; border-bottom: 1px solid var(--rule); vertical-align: top; }
  tbody td:first-child { padding-left: 18px; }
  tbody td:last-child { padding-right: 18px; }
  tbody tr:last-child td { border-bottom: 0; }
  tbody tr:hover td { background: color-mix(in srgb, var(--paper) 60%, transparent); }

  .score { display: flex; align-items: center; gap: 10px; }
  .score b { width: 34px; text-align: right; font-weight: 600; font-size: 14px; }
  .lvl-crap b { color: var(--crap); }
  .lvl-warn b { color: var(--warn); }
  .lvl-ok b { color: var(--ink-2); font-weight: 500; }
  .meter { position: relative; width: 72px; height: 4px; background: var(--track); border-radius: 2px; }
  .meter span { position: absolute; left: 0; top: 0; bottom: 0; border-radius: 2px; }
  .meter i { position: absolute; top: -3px; bottom: -3px; width: 2px; margin-left: -1px; background: var(--surface); box-shadow: inset 0 0 0 1px var(--rule-2); z-index: 1; }
  .lvl-crap .meter span { background: var(--crap); }
  .lvl-warn .meter span { background: var(--warn); }
  .lvl-ok .meter span { background: var(--ok-bar); }

  .cov-low { color: var(--crap); }
  .cov-zero { color: var(--crap); font-weight: 600; }
  .muted { color: var(--ink-3); }

  .fn, .loc { overflow-wrap: anywhere; }
  .fn { font-family: var(--mono); font-size: 12.5px; line-height: 1.5; }
  .fn .ctx { color: var(--ink-3); }
  .fn .typ { color: var(--ink-2); }
  .fn .mem { color: var(--ink); font-weight: 600; }
  .loc { margin-top: 2px; font-family: var(--mono); font-size: 11.5px; color: var(--ink-3); }
  .loc .m-only { display: none; }

  .empty td { padding: 48px 18px; text-align: center; color: var(--ink-2); }
  .empty button { margin-left: 8px; border: 1px solid var(--rule-2); background: var(--paper); border-radius: 5px; padding: 4px 10px; cursor: pointer; }

  .pager { display: flex; justify-content: space-between; align-items: center; gap: 12px; flex-wrap: wrap; padding: 12px 18px; border-top: 1px solid var(--rule); font-size: 13px; color: var(--ink-2); }
  .pager-nav { display: flex; align-items: center; gap: 6px; }
  .pager-nav button { height: 30px; min-width: 30px; border: 1px solid var(--rule-2); background: var(--surface); border-radius: 5px; cursor: pointer; padding: 0 10px; }
  .pager-nav button:disabled { opacity: .4; cursor: default; }

  .notes { margin-top: 28px; display: grid; grid-template-columns: repeat(3, minmax(0, 1fr)); gap: 28px; font-size: 12.5px; color: var(--ink-2); }
  .notes h3 { margin: 0 0 4px; font-size: 12px; font-weight: 600; color: var(--ink); }
  .notes p { margin: 0; }
  .notes code { font-family: var(--mono); font-size: 12px; color: var(--ink); }

  @media (max-width: 900px) {
    .overview { grid-template-columns: 1fr; gap: 36px; }
    .notes { grid-template-columns: 1fr; gap: 16px; }
  }
  @media (max-width: 640px) {
    .page { padding: 20px 16px 36px; }
    .overview { padding-top: 24px; }
    .verdict-n strong { font-size: 52px; }
    .facts { grid-template-columns: repeat(2, auto); gap: 14px 36px; }
    .list { border-radius: 0; border-left: 0; border-right: 0; margin: 0 -16px; }
    .list-head, .toolbar, .pager { padding-left: 16px; padding-right: 16px; }
    .kbd-hint { display: none; }
    table { table-layout: fixed; }
    thead th[data-col="crap"] { width: 64px !important; }
    thead th[data-col="coverage"] { width: 72px !important; }
    .col-cx { display: none; }
    .loc .m-only { display: inline; }
    .meter { display: none; }
    .score b { width: auto; }
    tbody td, thead th button { padding-left: 8px; padding-right: 8px; }
    tbody td:first-child, thead th:first-child button { padding-left: 16px; }
    tbody td:last-child { padding-right: 16px; }
  }
</style>
</head>
<body>
<div class="page">
  <header class="mast">
    <h1>ClassicCommander<span>/</span>CRAP report</h1>
    <p>Sources/App · generated %%GENERATED%%</p>
  </header>

  <section class="overview" aria-label="Summary">
    <div>
      <p class="eyebrow">Functions over the CRAP limit of %%T%%</p>
      <div class="verdict-n">
        <strong>%%CRAP_N%%</strong>
        <span>of <b>%%TOTAL%%</b> functions · %%CRAP_PCT%%%</span>
      </div>
      <div class="dist" aria-hidden="true">
        <i class="d-ok" style="flex-basis:%%OK_W%%%"></i>
        <i class="d-warn" style="flex-basis:%%WARN_W%%%"></i>
        <i class="d-crap" style="flex-basis:%%CRAP_W%%%"></i>
      </div>
      <ul class="legend">
        <li><span class="sw" style="background:var(--ok-bar)"></span><b>%%OK_N%%</b> healthy, below %%W%%</li>
        <li><span class="sw" style="background:var(--warn)"></span><b>%%WARN_N%%</b> warning, %%W%%–%%T%%</li>
        <li><span class="sw" style="background:var(--crap)"></span><b>%%CRAP_N%%</b> over limit</li>
      </ul>
      <dl class="facts">
        <div><dt>Worst score</dt><dd>%%MAX%%</dd></div>
        <div><dt>Average coverage</dt><dd>%%AVG_COV%%<small>%</small></dd></div>
        <div><dt>Average complexity</dt><dd>%%AVG_CX%%</dd></div>
        <div><dt>Never executed</dt><dd>%%ZERO_N%%</dd></div>
      </dl>
    </div>

    <aside class="hotspots" aria-labelledby="hs-title">
      <header>
        <h2 id="hs-title">Where the risk concentrates</h2>
        <p>over limit / all functions</p>
      </header>
      <ol>
%%HOTSPOTS%%
      </ol>
    </aside>
  </section>

  <section class="list" id="list" aria-labelledby="list-title">
    <div class="list-head">
      <h2 id="list-title">Functions</h2>
      <span class="kbd-hint muted" style="font-size:12px">Press <span class="kbd">/</span> to search</span>
    </div>
    <div class="toolbar">
      <label class="search">
        <svg viewBox="0 0 16 16" fill="none" stroke="currentColor" stroke-width="1.6" aria-hidden="true"><circle cx="7" cy="7" r="5"/><path d="m11 11 3.5 3.5"/></svg>
        <input type="search" id="q" placeholder="Function, type or file" aria-label="Search functions, types or files" autocomplete="off" spellcheck="false">
      </label>
      <div class="seg" role="group" aria-label="Risk level">
        <button type="button" data-risk="all" aria-pressed="true">All <span class="c">%%TOTAL%%</span></button>
        <button type="button" data-risk="crap" aria-pressed="false">Over limit <span class="c">%%CRAP_N%%</span></button>
        <button type="button" data-risk="warning" aria-pressed="false">Warning <span class="c">%%WARN_N%%</span></button>
        <button type="button" data-risk="healthy" aria-pressed="false">Healthy <span class="c">%%OK_N%%</span></button>
        <button type="button" data-risk="uncovered" aria-pressed="false">Untested <span class="c">%%ZERO_N%%</span></button>
      </div>
      <label class="field">Area
        <select id="dir">
          <option value="">All</option>
%%DIR_OPTIONS%%
        </select>
      </label>
      <label class="field">Score ≥
        <input type="number" id="min" min="0" step="1" value="0" inputmode="decimal">
      </label>
      <span class="chip" id="fileChip"><span id="fileChipText"></span><button type="button" id="fileClear" aria-label="Clear file filter">×</button></span>
    </div>

    <table>
      <thead>
        <tr>
          <th data-col="crap" style="width:150px"><button type="button">CRAP</button></th>
          <th data-col="complexity" class="r col-cx" style="width:96px"><button type="button">Complexity</button></th>
          <th data-col="coverage" class="r" style="width:96px"><button type="button">Coverage</button></th>
          <th data-col="name"><button type="button">Function</button></th>
        </tr>
      </thead>
      <tbody id="rows"></tbody>
    </table>

    <div class="pager">
      <span id="range" aria-live="polite"></span>
      <div class="pager-nav">
        <label class="field">Rows
          <select id="size">
            <option value="50" selected>50</option>
            <option value="100">100</option>
            <option value="250">250</option>
            <option value="all">All</option>
          </select>
        </label>
        <button type="button" id="prev" aria-label="Previous page">‹</button>
        <span id="pageNo" class="num"></span>
        <button type="button" id="next" aria-label="Next page">›</button>
      </div>
    </div>
  </section>

  <section class="notes" aria-label="Method">
    <div>
      <h3>Score</h3>
      <p><code>CRAP = cx² × (1 − cov)³ + cx</code>. Complexity that tests never reach grows the score fast; a fully covered function scores exactly its complexity.</p>
    </div>
    <div>
      <h3>Thresholds</h3>
      <p>Healthy below %%W%%, warning %%W%%–%%T%%, over the limit above %%T%%. The common industry limit is 30; this project uses %%T%%.</p>
    </div>
    <div>
      <h3>Inputs</h3>
      <p>Region coverage from <code>llvm-cov export</code>, cyclomatic complexity counted from source. %%SKIPPED%% compiler-generated implicit closures are left out.</p>
    </div>
  </section>
</div>

<script>
const DATA = %%DATA%%;
const LIMIT = %%T_JS%%;
const WARN = %%W_JS%%;
const SCALE = Math.max(LIMIT * 2, ...DATA.map(f => f.crap));

const $ = id => document.getElementById(id);
const state = { q: '', risk: 'all', dir: '', file: '', min: 0, col: 'crap', asc: false, size: 50, page: 1, rows: DATA };

const esc = s => String(s).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));

function level(f) {
  if (f.is_crap) return 'crap';
  return f.crap >= WARN ? 'warn' : 'ok';
}

// "closure #1 in static Foo.bar(_:)" -> context, type, member
function splitName(name) {
  const cut = Math.max(name.lastIndexOf(' in '), name.lastIndexOf(' of '));
  let ctx = cut >= 0 ? name.slice(0, cut + 4) : '';
  let main = cut >= 0 ? name.slice(cut + 4) : name;
  const mod = main.match(/^(static |class )/);
  if (mod) { ctx += mod[1]; main = main.slice(mod[1].length); }
  const paren = main.indexOf('(');
  const head = paren >= 0 ? main.slice(0, paren) : main;
  const dot = paren >= 0 ? head.lastIndexOf('.') : head.indexOf('.');
  return { ctx, typ: dot >= 0 ? main.slice(0, dot + 1) : '', mem: dot >= 0 ? main.slice(dot + 1) : main };
}

function matches(f) {
  if (state.risk === 'crap' && !f.is_crap) return false;
  if (state.risk === 'warning' && (f.is_crap || f.crap < WARN)) return false;
  if (state.risk === 'healthy' && f.crap >= WARN) return false;
  if (state.risk === 'uncovered' && f.coverage > 0) return false;
  if (f.crap < state.min) return false;
  if (state.file && f.file !== state.file) return false;
  if (state.dir && !(f.file.startsWith(state.dir) && f.file.indexOf('/', state.dir.length) < 0)) return false;
  if (state.q) {
    const q = state.q;
    return f.name.toLowerCase().includes(q) || f.file.toLowerCase().includes(q) || String(f.line) === q;
  }
  return true;
}

function update() {
  const { col, asc } = state;
  state.rows = DATA.filter(matches).sort((a, b) => {
    const d = typeof a[col] === 'string' ? a[col].localeCompare(b[col]) : a[col] - b[col];
    return (asc ? d : -d) || b.crap - a.crap;
  });
  state.page = 1;
  render();
}

function row(f) {
  const lvl = level(f);
  const n = splitName(f.name);
  const fill = Math.min(100, f.crap / SCALE * 100);
  const covCls = f.coverage === 0 ? 'cov-zero' : f.coverage < 50 ? 'cov-low' : '';
  const label = lvl === 'crap' ? 'over limit' : lvl === 'warn' ? 'warning' : 'healthy';
  return `<tr>
    <td><div class="score lvl-${lvl}" title="${label}"><b>${f.crap.toFixed(1)}</b><span class="meter"><span style="width:${fill}%"></span><i style="left:${WARN / SCALE * 100}%"></i><i style="left:${LIMIT / SCALE * 100}%"></i></span></div></td>
    <td class="r col-cx">${f.complexity}</td>
    <td class="r ${covCls}">${f.coverage.toFixed(f.coverage % 1 ? 1 : 0)}<span class="muted">%</span></td>
    <td><div class="fn"><span class="ctx">${esc(n.ctx)}</span><span class="typ">${esc(n.typ)}</span><span class="mem">${esc(n.mem)}</span></div>
      <div class="loc">${esc(f.file.replace(/^Sources\/App\//, ''))}:${f.line}<span class="m-only"> · cx ${f.complexity}</span></div></td>
  </tr>`;
}

function render() {
  const total = state.rows.length;
  const size = state.size === 'all' ? Math.max(total, 1) : state.size;
  const pages = Math.max(1, Math.ceil(total / size));
  state.page = Math.min(state.page, pages);
  const start = (state.page - 1) * size;
  const end = Math.min(start + size, total);

  $('rows').innerHTML = total
    ? state.rows.slice(start, end).map(row).join('')
    : '<tr class="empty"><td colspan="4">No functions match these filters.<button type="button" id="reset">Clear filters</button></td></tr>';
  if (!total) $('reset').addEventListener('click', resetFilters);

  $('range').textContent = total ? `${(start + 1).toLocaleString()}–${end.toLocaleString()} of ${total.toLocaleString()}` : '0 results';
  $('pageNo').textContent = `${state.page} / ${pages}`;
  $('prev').disabled = state.page <= 1;
  $('next').disabled = state.page >= pages;

  document.querySelectorAll('thead th').forEach(th => {
    if (th.dataset.col === state.col) th.setAttribute('aria-sort', state.asc ? 'ascending' : 'descending');
    else th.removeAttribute('aria-sort');
  });
  document.querySelectorAll('[data-risk]').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.risk === state.risk)));
  document.querySelectorAll('.hs').forEach(b => b.setAttribute('aria-pressed', String(b.dataset.file === state.file)));
  $('fileChip').classList.toggle('on', !!state.file);
  $('fileChipText').textContent = state.file.split('/').pop();
}

function resetFilters() {
  Object.assign(state, { q: '', risk: 'all', dir: '', file: '', min: 0 });
  $('q').value = ''; $('dir').value = ''; $('min').value = 0;
  update();
}

$('q').addEventListener('input', e => { state.q = e.target.value.trim().toLowerCase(); update(); });
$('q').addEventListener('keydown', e => { if (e.key === 'Escape' && e.target.value) { e.target.value = ''; state.q = ''; update(); } });
$('dir').addEventListener('change', e => { state.dir = e.target.value; update(); });
$('min').addEventListener('input', e => { state.min = parseFloat(e.target.value) || 0; update(); });
$('size').addEventListener('change', e => { state.size = e.target.value === 'all' ? 'all' : +e.target.value; update(); });
$('prev').addEventListener('click', () => { state.page--; render(); });
$('next').addEventListener('click', () => { state.page++; render(); });
$('fileClear').addEventListener('click', () => { state.file = ''; update(); });
document.querySelectorAll('[data-risk]').forEach(b => b.addEventListener('click', () => { state.risk = b.dataset.risk; update(); }));
document.querySelectorAll('.hs').forEach(b => b.addEventListener('click', () => {
  state.file = state.file === b.dataset.file ? '' : b.dataset.file;
  update();
  if (state.file) $('list').scrollIntoView({ behavior: 'smooth', block: 'start' });
}));
document.querySelectorAll('thead th').forEach(th => th.querySelector('button').addEventListener('click', () => {
  const col = th.dataset.col;
  state.asc = state.col === col ? !state.asc : col === 'name' || col === 'coverage';
  state.col = col;
  update();
}));
document.addEventListener('keydown', e => {
  if (e.key === '/' && !/^(INPUT|SELECT|TEXTAREA)$/.test(document.activeElement.tagName)) {
    e.preventDefault();
    $('q').focus();
  }
});

update();
</script>
</body>
</html>
"""


def print_terminal_summary(data: dict, baseline_data: dict = None) -> None:
    """Prints a styled terminal summary of CRAP scores and comparison against baseline."""
    s = data["summary"]
    thresh = data["threshold"]
    warn_thresh = data.get("warning_threshold", 4.0)

    print("\n" + "=" * 70)
    print("                    CRAP SCORE RISK ANALYSIS")
    print("=" * 70)
    print(f"Evaluated Functions : {s['total_functions']:,}")
    print(
        f"CRAP Errors (> {thresh:g})  : \033[1;31m{s['crap_functions']:,} ({s['crap_percentage']}%)\033[0m"
    )
    print(
        f"Warning Functions   : \033[1;33m{s['warning_functions']:,}\033[0m ({warn_thresh:g} ≤ CRAP ≤ {thresh:g})"
    )
    print(
        f"Healthy Functions   : \033[1;32m{s['healthy_functions']:,}\033[0m (CRAP < {warn_thresh:g})"
    )
    print(f"Zero Coverage Count : {s['zero_coverage_functions']:,}")
    print(
        f"Max CRAP Score      : \033[1;31m{s['max_crap']:.1f}\033[0m (Comp² × (1-cov)³ + Comp)"
    )
    print(f"Average CRAP Score  : {s['average_crap']:.2f}")
    print(f"Average Complexity  : {s['average_complexity']:.1f}")
    print(f"Average Coverage    : {s['average_coverage']:.1f}%")

    if baseline_data:
        bs = baseline_data.get("summary", {})
        b_crap = bs.get("crap_functions", 0)
        diff_crap = s["crap_functions"] - b_crap
        diff_str = (
            f"+{diff_crap}"
            if diff_crap > 0
            else (f"{diff_crap}" if diff_crap < 0 else "0")
        )
        color = "\033[1;31m" if diff_crap > 0 else "\033[1;32m"
        print(f"Baseline Comparison : {color}{diff_str} CRAP functions vs baseline\033[0m")

    print("-" * 70)
    print(f"TOP HIGH-RISK FUNCTIONS (CRAP > {thresh:g}):")
    print("  CRAP   COMP    COV%  LOCATION & FUNCTION")
    print("-" * 70)

    crap_list = [f for f in data["functions"] if f["is_crap"]]
    for item in crap_list[:15]:
        loc = f"{item['file']}:{item['line']}"
        name = item["name"]
        if len(name) > 42:
            name = name[:39] + "..."
        print(
            f" \033[1;31m{item['crap']:6.1f}\033[0m  {item['complexity']:4d}  {item['coverage']:5.1f}%  {loc} ({name})"
        )

    if len(crap_list) > 15:
        print(f"  ... and {len(crap_list) - 15} more high-risk functions.")
    print("=" * 70 + "\n")


def main():
    parser = argparse.ArgumentParser(
        description="CRAP Score Analyzer for ClassicCommander"
    )
    parser.add_argument(
        "--export-json",
        default="build/coverage/export.json",
        help="Path to llvm-cov export.json",
    )
    parser.add_argument(
        "--project-dir", default=".", help="Root project directory"
    )
    parser.add_argument(
        "--baseline-json",
        default="tools/crap/baseline.json",
        help="Baseline JSON file for comparison",
    )
    parser.add_argument(
        "--out-json",
        help="Path where output JSON should be saved (e.g. tools/crap/baseline.json)",
    )
    parser.add_argument(
        "--out-html",
        help="Path where output HTML report should be saved (e.g. tools/crap/baseline.html)",
    )
    parser.add_argument(
        "--threshold",
        type=float,
        default=6.0,
        help="CRAP error threshold (default: 6.0)",
    )
    parser.add_argument(
        "--warning-threshold",
        type=float,
        default=4.0,
        help="CRAP warning threshold (default: 4.0)",
    )
    parser.add_argument(
        "--include-implicit",
        action="store_true",
        help="Include compiler-generated closures",
    )
    parser.add_argument(
        "--silent", action="store_true", help="Suppress terminal report"
    )
    args = parser.parse_args()

    project_dir = os.path.abspath(args.project_dir)
    export_json = os.path.abspath(args.export_json)

    if not os.path.exists(export_json):
        sys.stderr.write(
            f"Error: Coverage export file not found at {export_json}\n"
        )
        sys.stderr.write("Run scripts/coverage.sh first.\n")
        sys.exit(1)

    data = extract_function_data(
        export_json_path=export_json,
        project_dir=project_dir,
        include_implicit=args.include_implicit,
        threshold=args.threshold,
        warning_threshold=args.warning_threshold,
    )

    baseline_data = None
    if os.path.exists(args.baseline_json) and args.baseline_json != args.out_json:
        try:
            with open(args.baseline_json, "r", encoding="utf-8") as bf:
                baseline_data = json.load(bf)
        except Exception:
            pass

    # Save JSON output if requested
    if args.out_json:
        out_json_path = os.path.abspath(args.out_json)
        os.makedirs(os.path.dirname(out_json_path), exist_ok=True)
        with open(out_json_path, "w", encoding="utf-8") as f:
            json.dump(data, f, indent=2)
        print(f"Saved CRAP JSON data: {out_json_path}")

    # Save HTML output if requested
    if args.out_html:
        out_html_path = os.path.abspath(args.out_html)
        os.makedirs(os.path.dirname(out_html_path), exist_ok=True)
        html_content = generate_html_report(data)
        with open(out_html_path, "w", encoding="utf-8") as f:
            f.write(html_content)
        print(f"Saved CRAP HTML report: {out_html_path}")

    if not args.silent:
        print_terminal_summary(data, baseline_data=baseline_data)


if __name__ == "__main__":
    main()
