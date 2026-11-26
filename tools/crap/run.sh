#!/usr/bin/env bash
# Runs offline CRAP scoring analysis for ClassicCommander.
# Usage:
#   tools/crap/run.sh              # Run CRAP analysis and compare against baseline
#   tools/crap/run.sh --baseline   # Generate/update tools/crap/baseline.json and baseline.html
#   tools/crap/run.sh --recompute  # Force recompilation and re-running test coverage first

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "${script_dir}/../.." && pwd)"
cd "$project_dir"

baseline_mode=false
recompute=false

for arg in "$@"; do
    case "$arg" in
    --baseline)
        baseline_mode=true
        ;;
    --recompute | --force)
        recompute=true
        ;;
    *)
        echo "Unknown option: $arg" >&2
        echo "Usage: $0 [--baseline] [--recompute]" >&2
        exit 1
        ;;
    esac
done

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
        --out-html "$out_html"
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
        --out-html "$out_html"
    printf '%s\n' "Saved CRAP analysis report:"
    printf '%s\n' "   JSON: ${out_json}"
    printf '%s\n' "   HTML: ${out_html}"
fi
