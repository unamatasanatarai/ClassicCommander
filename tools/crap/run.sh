#!/usr/bin/env bash
# Runs offline CRAP scoring analysis for ClassicCommander.
# Usage:
#   tools/crap/run.sh                       # Run CRAP analysis and compare against baseline
#   tools/crap/run.sh --baseline            # Generate/update tools/crap/baseline.json and baseline.html
#   tools/crap/run.sh --recompute           # Force recompilation and re-running test coverage first
#   tools/crap/run.sh --threshold 4         # Override CRAP threshold (or set CRAP_THRESHOLD)
# Without --baseline, exits 1 when a function over the threshold is new or worse than in the baseline.

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "${script_dir}/../.." && pwd)"
cd "$project_dir"

baseline_mode=false
recompute=false
threshold="${CRAP_THRESHOLD:-}"

while [[ $# -gt 0 ]]; do
    case "$1" in
    --baseline)
        baseline_mode=true
        shift
        ;;
    --recompute | --force)
        recompute=true
        shift
        ;;
    --threshold)
        threshold="${2:-}"
        shift 2
        ;;
    *)
        echo "Unknown option: $1" >&2
        echo "Usage: $0 [--baseline] [--recompute] [--threshold N]" >&2
        exit 1
        ;;
    esac
done

extra_args=()
if [[ -n "$threshold" ]]; then
    extra_args+=(--threshold "$threshold")
fi

export_json="build/coverage/export.json"

if [[ "$recompute" == "true" ]] || [[ ! -f "$export_json" ]]; then
    printf '%s\n' "==> Gathering code coverage data (running scripts/coverage.sh)..."
    ./scripts/coverage.sh
fi

if [[ "$baseline_mode" == "true" ]]; then
    out_json="tools/crap/baseline.json"
    out_html="tools/crap/baseline.html"
    printf '%s\n' "==> Generating CRAP baseline to ${out_json} and ${out_html}..."
    python3 tools/crap/crap.py \
        --export-json "$export_json" \
        --project-dir "$project_dir" \
        --out-json "$out_json" \
        --out-html "$out_html" \
        ${extra_args[@]+"${extra_args[@]}"}
    printf '%s\n' "✅ CRAP baseline successfully generated."
    printf '%s\n' "   JSON: ${out_json}"
    printf '%s\n' "   HTML: ${out_html}"
else
    out_dir="build/crap"
    mkdir -p "$out_dir"
    out_json="${out_dir}/report.json"
    out_html="${out_dir}/report.html"
    baseline_json="tools/crap/baseline.json"

    python3 tools/crap/crap.py \
        --export-json "$export_json" \
        --project-dir "$project_dir" \
        --baseline-json "$baseline_json" \
        --out-json "$out_json" \
        --out-html "$out_html" \
        ${extra_args[@]+"${extra_args[@]}"} || status=$?
    exit "${status:-0}"
fi
