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


def generate_html_report(data: dict) -> str:
    """Generates a modern, self-contained, offline HTML report with live filtering, sorting, and stats."""
    summary = data["summary"]
    threshold = data["threshold"]
    warning_threshold = data.get("warning_threshold", 4.0)
    funcs_json = json.dumps(data["functions"])

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>CRAP Score Analysis &amp; Baseline - ClassicCommander</title>
  <style>
    :root {{
      --bg: #f8fafc;
      --card-bg: #ffffff;
      --text: #0f172a;
      --text-muted: #64748b;
      --border: #e2e8f0;
      --crap: #ef4444;
      --crap-bg: #fee2e2;
      --warning: #f59e0b;
      --warning-bg: #fef3c7;
      --good: #10b981;
      --good-bg: #d1fae5;
      --primary: #2563eb;
      --primary-light: #eff6ff;
      --font-mono: ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, "Liberation Mono", "Courier New", monospace;
      --font-sans: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
    }}

    @media (prefers-color-scheme: dark) {{
      :root {{
        --bg: #0f172a;
        --card-bg: #1e293b;
        --text: #f1f5f9;
        --text-muted: #94a3b8;
        --border: #334155;
        --crap: #f87171;
        --crap-bg: #450a0a;
        --warning: #fbbf24;
        --warning-bg: #451a03;
        --good: #34d399;
        --good-bg: #064e3b;
        --primary: #3b82f6;
        --primary-light: #1e3a8a;
      }}
    }}

    * {{ box-sizing: border-box; margin: 0; padding: 0; }}
    body {{
      font-family: var(--font-sans);
      background: var(--bg);
      color: var(--text);
      line-height: 1.5;
      padding: 24px;
    }}

    .container {{
      max-width: 1440px;
      margin: 0 auto;
    }}

    header {{
      margin-bottom: 24px;
      padding-bottom: 20px;
      border-bottom: 1px solid var(--border);
      display: flex;
      justify-content: space-between;
      align-items: flex-start;
      flex-wrap: wrap;
      gap: 16px;
    }}

    h1 {{
      font-size: 26px;
      font-weight: 700;
      letter-spacing: -0.02em;
      display: flex;
      align-items: center;
      gap: 10px;
    }}

    .subtitle {{
      color: var(--text-muted);
      font-size: 14px;
      margin-top: 4px;
    }}

    .formula-tag {{
      background: var(--card-bg);
      border: 1px solid var(--border);
      padding: 6px 12px;
      border-radius: 6px;
      font-family: var(--font-mono);
      font-size: 13px;
      color: var(--text-muted);
    }}

    .kpis {{
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(170px, 1fr));
      gap: 14px;
      margin-bottom: 24px;
    }}

    .kpi-card {{
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 16px;
      box-shadow: 0 1px 3px rgba(0,0,0,0.05);
    }}

    .kpi-title {{
      font-size: 12px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: 0.05em;
      color: var(--text-muted);
    }}

    .kpi-value {{
      font-size: 28px;
      font-weight: 700;
      margin-top: 6px;
      line-height: 1.1;
    }}

    .kpi-sub {{
      font-size: 12px;
      color: var(--text-muted);
      margin-top: 4px;
    }}

    .kpi-crap {{ color: var(--crap); }}
    .kpi-warning {{ color: var(--warning); }}
    .kpi-good {{ color: var(--good); }}

    .toolbar {{
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 8px;
      padding: 16px;
      margin-bottom: 20px;
      display: flex;
      flex-direction: column;
      gap: 14px;
      box-shadow: 0 1px 3px rgba(0,0,0,0.05);
    }}

    .toolbar-row {{
      display: flex;
      gap: 12px;
      flex-wrap: wrap;
      align-items: center;
    }}

    .search-input {{
      flex: 1;
      min-width: 260px;
      padding: 9px 14px;
      border-radius: 6px;
      border: 1px solid var(--border);
      background: var(--bg);
      color: var(--text);
      font-size: 14px;
    }}
    .search-input:focus {{
      outline: none;
      border-color: var(--primary);
    }}

    .filter-btn {{
      padding: 7px 14px;
      border-radius: 6px;
      border: 1px solid var(--border);
      background: var(--bg);
      color: var(--text);
      font-size: 13px;
      font-weight: 500;
      cursor: pointer;
      display: inline-flex;
      align-items: center;
      gap: 6px;
      transition: all 0.15s ease;
    }}

    .filter-btn:hover {{
      border-color: var(--primary);
    }}

    .filter-btn.active {{
      background: var(--primary);
      color: #ffffff;
      border-color: var(--primary);
    }}

    .filter-badge {{
      background: rgba(0,0,0,0.1);
      padding: 2px 6px;
      border-radius: 10px;
      font-size: 11px;
    }}
    .active .filter-badge {{
      background: rgba(255,255,255,0.25);
    }}

    .control-group {{
      display: inline-flex;
      align-items: center;
      gap: 6px;
      font-size: 13px;
      color: var(--text-muted);
    }}

    .control-select, .control-input {{
      padding: 6px 10px;
      border-radius: 6px;
      border: 1px solid var(--border);
      background: var(--bg);
      color: var(--text);
      font-size: 13px;
    }}

    .table-container {{
      background: var(--card-bg);
      border: 1px solid var(--border);
      border-radius: 8px;
      overflow-x: auto;
      box-shadow: 0 1px 3px rgba(0,0,0,0.05);
    }}

    table {{
      width: 100%;
      border-collapse: collapse;
      font-size: 13px;
      text-align: left;
    }}

    th {{
      background: var(--bg);
      padding: 12px 14px;
      font-weight: 600;
      color: var(--text-muted);
      border-bottom: 1px solid var(--border);
      cursor: pointer;
      user-select: none;
      white-space: nowrap;
    }}

    th:hover {{
      color: var(--text);
    }}

    th.sorted-asc::after {{ content: " ▲"; color: var(--primary); font-size: 10px; }}
    th.sorted-desc::after {{ content: " ▼"; color: var(--primary); font-size: 10px; }}

    td {{
      padding: 10px 14px;
      border-bottom: 1px solid var(--border);
      vertical-align: middle;
    }}

    tr:last-child td {{
      border-bottom: none;
    }}

    tr:hover {{
      background: rgba(0,0,0,0.015);
    }}

    .badge {{
      display: inline-flex;
      align-items: center;
      padding: 3px 8px;
      border-radius: 4px;
      font-size: 11px;
      font-weight: 700;
      letter-spacing: 0.03em;
    }}

    .badge-crap {{
      background: var(--crap-bg);
      color: var(--crap);
    }}

    .badge-warning {{
      background: var(--warning-bg);
      color: var(--warning);
    }}

    .badge-good {{
      background: var(--good-bg);
      color: var(--good);
    }}

    .score-cell {{
      font-family: var(--font-mono);
      font-weight: 700;
      font-size: 14px;
    }}

    .score-crap {{ color: var(--crap); }}
    .score-warning {{ color: var(--warning); }}
    .score-good {{ color: var(--good); }}

    .func-name {{
      font-family: var(--font-mono);
      font-size: 13px;
      font-weight: 600;
      word-break: break-all;
    }}

    .func-file {{
      color: var(--text-muted);
      font-size: 12px;
      font-family: var(--font-mono);
      margin-top: 2px;
    }}

    .progress-bar {{
      width: 80px;
      height: 6px;
      background: var(--border);
      border-radius: 3px;
      overflow: hidden;
      display: inline-block;
      vertical-align: middle;
      margin-right: 6px;
    }}

    .progress-fill {{
      height: 100%;
      background: var(--good);
    }}
    .progress-fill.low {{ background: var(--crap); }}
    .progress-fill.mid {{ background: var(--warning); }}

    .pagination {{
      display: flex;
      justify-content: space-between;
      align-items: center;
      padding: 14px 16px;
      border-top: 1px solid var(--border);
      background: var(--bg);
      border-radius: 0 0 8px 8px;
      font-size: 13px;
      color: var(--text-muted);
    }}

    .page-buttons {{
      display: flex;
      gap: 6px;
    }}

    .page-btn {{
      padding: 5px 12px;
      border: 1px solid var(--border);
      background: var(--card-bg);
      color: var(--text);
      border-radius: 4px;
      font-size: 13px;
      cursor: pointer;
    }}

    .page-btn:disabled {{
      opacity: 0.5;
      cursor: not-allowed;
    }}

    .footer {{
      margin-top: 24px;
      font-size: 12px;
      color: var(--text-muted);
      text-align: center;
    }}
  </style>
</head>
<body>
  <div class="container">
    <header>
      <div>
        <h1>ClassicCommander CRAP Score Analysis</h1>
        <div class="subtitle">Change Risk Anti-Patterns analysis generated on {html.escape(data['generated_at'])}</div>
      </div>
      <div class="formula-tag">
        CRAP(m) = comp(m)² × (1 - cov(m))³ + comp(m) [Target: ≤ {threshold:g} | Warning: {warning_threshold:g}–{threshold:g} | Error: &gt; {threshold:g}]
      </div>
    </header>

    <div class="kpis">
      <div class="kpi-card">
        <div class="kpi-title">Total Functions</div>
        <div class="kpi-value">{summary['total_functions']:,}</div>
        <div class="kpi-sub">Sources/App code</div>
      </div>
      <div class="kpi-card">
        <div class="kpi-title">CRAP Errors</div>
        <div class="kpi-value kpi-crap">{summary['crap_functions']:,}</div>
        <div class="kpi-sub">{summary['crap_percentage']}% of total (&gt; {threshold:g})</div>
      </div>
      <div class="kpi-card">
        <div class="kpi-title">Warning ({warning_threshold:g}–{threshold:g})</div>
        <div class="kpi-value kpi-warning">{summary['warning_functions']:,}</div>
        <div class="kpi-sub">Approaching target limit</div>
      </div>
      <div class="kpi-card">
        <div class="kpi-title">Healthy (&lt; {warning_threshold:g})</div>
        <div class="kpi-value kpi-good">{summary['healthy_functions']:,}</div>
        <div class="kpi-sub">Target goal satisfied</div>
      </div>
      <div class="kpi-card">
        <div class="kpi-title">Max CRAP Score</div>
        <div class="kpi-value kpi-crap">{summary['max_crap']:.1f}</div>
        <div class="kpi-sub">Highest risk function</div>
      </div>
      <div class="kpi-card">
        <div class="kpi-title">Avg Complexity</div>
        <div class="kpi-value">{summary['average_complexity']:.1f}</div>
        <div class="kpi-sub">Avg decisions / method</div>
      </div>
      <div class="kpi-card">
        <div class="kpi-title">Avg Coverage</div>
        <div class="kpi-value kpi-good">{summary['average_coverage']:.1f}%</div>
        <div class="kpi-sub">Region execution coverage</div>
      </div>
    </div>

    <div class="toolbar">
      <div class="toolbar-row">
        <input type="text" id="searchInput" class="search-input" placeholder="Search functions, classes, files (e.g. CommanderView, ZipArchive, .swift)...">
        <div class="control-group">
          <label for="filterDir">Directory:</label>
          <select id="filterDir" class="control-select">
            <option value="">All Directories</option>
            <option value="Sources/App/Core">Sources/App/Core</option>
            <option value="Sources/App/Presentation">Sources/App/Presentation</option>
            <option value="Sources/App/Core/FTP">Sources/App/Core/FTP</option>
          </select>
        </div>
      </div>
      <div class="toolbar-row">
        <div style="display:flex; gap:8px; flex-wrap:wrap;">
          <button class="filter-btn active" data-filter="all">All <span class="filter-badge" id="badgeAll">{summary['total_functions']}</span></button>
          <button class="filter-btn" data-filter="crap">CRAP Only <span class="filter-badge" id="badgeCrap">{summary['crap_functions']}</span></button>
          <button class="filter-btn" data-filter="warning">Warning <span class="filter-badge" id="badgeWarning">{summary['warning_functions']}</span></button>
          <button class="filter-btn" data-filter="healthy">Healthy <span class="filter-badge" id="badgeHealthy">{summary['healthy_functions']}</span></button>
          <button class="filter-btn" data-filter="uncovered">0% Coverage <span class="filter-badge" id="badgeUncovered">{summary['zero_coverage_functions']}</span></button>
        </div>
        <div style="margin-left:auto; display:flex; gap:12px; align-items:center;">
          <div class="control-group">
            <label for="minCrapInput">Min CRAP:</label>
            <input type="number" id="minCrapInput" class="control-input" style="width:70px;" min="0" step="5" value="0">
          </div>
          <div class="control-group">
            <label for="pageSizeSelect">Show:</label>
            <select id="pageSizeSelect" class="control-select">
              <option value="50" selected>50</option>
              <option value="100">100</option>
              <option value="250">250</option>
              <option value="all">All</option>
            </select>
          </div>
        </div>
      </div>
    </div>

    <div class="table-container">
      <table id="crapTable">
        <thead>
          <tr>
            <th data-col="status" style="width: 100px;">Status</th>
            <th data-col="crap" class="sorted-desc" style="width: 110px;">CRAP Score</th>
            <th data-col="complexity" style="width: 110px;">Complexity</th>
            <th data-col="coverage" style="width: 150px;">Coverage</th>
            <th data-col="name">Function / Method</th>
            <th data-col="file" style="width: 320px;">Location</th>
          </tr>
        </thead>
        <tbody id="tableBody">
          <!-- Rows inserted via JS -->
        </tbody>
      </table>
      <div class="pagination">
        <div id="pageInfo">Showing 0-0 of 0</div>
        <div class="page-buttons">
          <button id="prevBtn" class="page-btn">Previous</button>
          <span id="pageCurrent" style="padding: 5px 8px; font-weight:600;">1</span>
          <button id="nextBtn" class="page-btn">Next</button>
        </div>
      </div>
    </div>

    <div class="footer">
      ClassicCommander Code Risk Baseline &bull; Generated offline with standard xcrun llvm-cov and swift-demangle &bull; Target CRAP &le; {threshold:g} (Warning: {warning_threshold:g}&ndash;{threshold:g}, Error: &gt; {threshold:g})
    </div>
  </div>

  <script>
    const RAW_DATA = {funcs_json};
    const THRESHOLD = {threshold};
    const WARN_THRESHOLD = {warning_threshold};

    let state = {{
      data: RAW_DATA,
      filtered: [...RAW_DATA],
      filterMode: 'all',
      search: '',
      dirFilter: '',
      minCrap: 0,
      sortCol: 'crap',
      sortAsc: false,
      pageSize: 50,
      currentPage: 1
    }};

    function applyFilters() {{
      const q = state.search.toLowerCase().trim();
      const dir = state.dirFilter;
      const minC = state.minCrap;

      state.filtered = state.data.filter(item => {{
        // Filter button
        if (state.filterMode === 'crap' && !item.is_crap) return false;
        if (state.filterMode === 'warning' && (item.crap < WARN_THRESHOLD || item.crap > THRESHOLD)) return false;
        if (state.filterMode === 'healthy' && item.crap >= WARN_THRESHOLD) return false;
        if (state.filterMode === 'uncovered' && item.coverage > 0) return false;

        // Min CRAP
        if (item.crap < minC) return false;

        // Directory
        if (dir && !item.file.startsWith(dir)) return false;

        // Search
        if (q) {{
          const inName = item.name.toLowerCase().includes(q);
          const inFile = item.file.toLowerCase().includes(q);
          const inLine = String(item.line).includes(q);
          if (!inName && !inFile && !inLine) return false;
        }}

        return true;
      }});

      // Sort
      state.filtered.sort((a, b) => {{
        let vA = a[state.sortCol];
        let vB = b[state.sortCol];
        if (state.sortCol === 'status') {{
          vA = a.crap;
          vB = b.crap;
        }}
        if (typeof vA === 'string') {{
          const cmp = vA.localeCompare(vB);
          return state.sortAsc ? cmp : -cmp;
        }}
        return state.sortAsc ? (vA - vB) : (vB - vA);
      }});

      state.currentPage = 1;
      render();
    }}

    function render() {{
      const tbody = document.getElementById('tableBody');
      const total = state.filtered.length;
      const pageSize = state.pageSize === 'all' ? total : parseInt(state.pageSize, 10);
      const totalPages = Math.max(1, Math.ceil(total / pageSize));

      if (state.currentPage > totalPages) state.currentPage = totalPages;
      const startIdx = (state.currentPage - 1) * pageSize;
      const endIdx = Math.min(startIdx + pageSize, total);
      const pageItems = state.filtered.slice(startIdx, endIdx);

      let htmlRows = '';
      for (const item of pageItems) {{
        let statusBadge = '<span class="badge badge-good">OK</span>';
        let scoreClass = 'score-good';
        if (item.is_crap) {{
          statusBadge = '<span class="badge badge-crap">CRAP</span>';
          scoreClass = 'score-crap';
        }} else if (item.crap >= WARN_THRESHOLD) {{
          statusBadge = '<span class="badge badge-warning">WARN</span>';
          scoreClass = 'score-warning';
        }}

        let covFillClass = '';
        if (item.coverage < 40) covFillClass = 'low';
        else if (item.coverage < 80) covFillClass = 'mid';

        htmlRows += `<tr>
          <td>${{statusBadge}}</td>
          <td class="score-cell ${{scoreClass}}">${{item.crap.toFixed(1)}}</td>
          <td><span class="badge" style="background:var(--bg); border:1px solid var(--border); font-family:var(--font-mono);">${{item.complexity}}</span></td>
          <td>
            <div class="progress-bar"><div class="progress-fill ${{covFillClass}}" style="width:${{Math.min(100, item.coverage)}}%;"></div></div>
            <span style="font-family:var(--font-mono); font-size:12px;">${{item.coverage.toFixed(1)}}%</span>
          </td>
          <td>
            <div class="func-name">${{escapeHtml(item.name)}}</div>
          </td>
          <td>
            <div class="func-file">${{escapeHtml(item.file)}}:${{item.line}}</div>
          </td>
        </tr>`;
      }}

      if (total === 0) {{
        htmlRows = '<tr><td colspan="6" style="text-align:center; padding:30px; color:var(--text-muted);">No matching functions found</td></tr>';
      }}

      tbody.innerHTML = htmlRows;

      // Update Pagination info
      document.getElementById('pageInfo').textContent = total > 0
        ? `Showing ${{startIdx + 1}}-${{endIdx}} of ${{total}}`
        : 'Showing 0-0 of 0';
      document.getElementById('pageCurrent').textContent = `${{state.currentPage}} / ${{totalPages}}`;
      document.getElementById('prevBtn').disabled = state.currentPage <= 1;
      document.getElementById('nextBtn').disabled = state.currentPage >= totalPages;

      // Update Header Sort Arrows
      document.querySelectorAll('th').forEach(th => {{
        th.classList.remove('sorted-asc', 'sorted-desc');
        if (th.getAttribute('data-col') === state.sortCol) {{
          th.classList.add(state.sortAsc ? 'sorted-asc' : 'sorted-desc');
        }}
      }});
    }}

    function escapeHtml(str) {{
      return String(str).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
    }}

    // Event listeners
    document.getElementById('searchInput').addEventListener('input', e => {{
      state.search = e.target.value;
      applyFilters();
    }});

    document.getElementById('filterDir').addEventListener('change', e => {{
      state.dirFilter = e.target.value;
      applyFilters();
    }});

    document.getElementById('minCrapInput').addEventListener('input', e => {{
      state.minCrap = parseFloat(e.target.value) || 0;
      applyFilters();
    }});

    document.getElementById('pageSizeSelect').addEventListener('change', e => {{
      state.pageSize = e.target.value;
      applyFilters();
    }});

    document.querySelectorAll('.filter-btn').forEach(btn => {{
      btn.addEventListener('click', () => {{
        document.querySelectorAll('.filter-btn').forEach(b => b.classList.remove('active'));
        btn.classList.add('active');
        state.filterMode = btn.getAttribute('data-filter');
        applyFilters();
      }});
    }});

    document.querySelectorAll('th').forEach(th => {{
      th.addEventListener('click', () => {{
        const col = th.getAttribute('data-col');
        if (state.sortCol === col) {{
          state.sortAsc = !state.sortAsc;
        }} else {{
          state.sortCol = col;
          state.sortAsc = (col === 'name' || col === 'file');
        }}
        applyFilters();
      }});
    }});

    document.getElementById('prevBtn').addEventListener('click', () => {{
      if (state.currentPage > 1) {{
        state.currentPage--;
        render();
      }}
    }});

    document.getElementById('nextBtn').addEventListener('click', () => {{
      state.currentPage++;
      render();
    }});

    // Initial render
    applyFilters();
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
