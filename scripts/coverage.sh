#!/usr/bin/env bash
# Builds the test suite with code coverage, runs it and reports function / line coverage of Sources/App.
# Usage: scripts/coverage.sh [--check]   (--check: fail unless every function is covered)
#        make coverage                    (= --check)
# Report files: build/coverage/report.txt (per file) and build/coverage/uncovered.txt (functions never called).

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
project_dir="$(cd "${script_dir}/.." && pwd)"
cd "$project_dir"

check=false
[[ "${1:-}" == "--check" ]] && check=true

out="build/coverage"
rm -rf "$out"
mkdir -p "$out"

sources=()
while IFS= read -r file; do
    grep -q "@main" "$file" 2>/dev/null || sources+=("$file")
done < <(find Sources/App -type f -name "*.swift" | sort)
tests=()
while IFS= read -r file; do
    tests+=("$file")
done < <(find Tests/AppTests -type f -name "*.swift" | sort)

printf '%s\n' "Compiling the test suite with coverage instrumentation..."
swiftc -sdk "$(xcrun --show-sdk-path)" -profile-generate -profile-coverage-mapping \
    "${sources[@]}" "${tests[@]}" -o "$out/RunSwiftTests"

status=0
LLVM_PROFILE_FILE="$out/tests-%p.profraw" "$out/RunSwiftTests" || status=$?
xcrun llvm-profdata merge -sparse "$out"/tests-*.profraw -o "$out/tests.profdata"

ignore='Tests/|/usr/|\.build/'
xcrun llvm-cov report "$out/RunSwiftTests" -instr-profile "$out/tests.profdata" \
    -ignore-filename-regex="$ignore" "${sources[@]}" > "$out/report.txt"
# Every function with an execution count of 0, demangled, with its file and line.
xcrun llvm-cov export "$out/RunSwiftTests" -instr-profile "$out/tests.profdata" -format=text \
    -ignore-filename-regex="$ignore" -skip-expansions "${sources[@]}" > "$out/export.json"
python3 - "$out/export.json" "$project_dir" > "$out/uncovered.txt" <<'PY'
import json, sys, subprocess
data = json.load(open(sys.argv[1]))
root = sys.argv[2] + "/"
rows = []
sources = {}
def declared_unavailable(path, line):
    # `@available(*, unavailable)` declarations (AppKit's required init(coder:)) cannot be called at all.
    if path not in sources:
        sources[path] = open(root + path).read().splitlines()
    text = sources[path]
    return any("@available(*, unavailable)" in text[i] for i in range(max(0, line - 3), min(len(text), line)))
for f in data["data"][0]["functions"]:
    if f["count"] == 0 and f["filenames"]:
        path = f["filenames"][0].replace(root, "")
        line = f["regions"][0][0]
        if not path.startswith("Sources/App/") or declared_unavailable(path, line):
            continue
        rows.append((path, line, f["name"]))
names = subprocess.run(["xcrun", "swift-demangle", "--simplified", "--compact"], input="\n".join(r[2] for r in rows),
                       capture_output=True, text=True).stdout.splitlines() if rows else []
# Compiler-generated implicit closures (the right-hand side of ??, && and ||) are branch coverage,
# not functions anyone wrote: they go to a separate, informational list.
implicit = open(sys.argv[1].replace("export.json", "uncovered-implicit.txt"), "w")
for (path, line, _), name in sorted(zip(rows, names)):
    line_text = f"{path}:{line}  {name}"
    if "implicit closure" in name:
        implicit.write(line_text + "\n")
    else:
        print(line_text)
PY

printf '\n'
head -2 "$out/report.txt" | tail -1 >/dev/null
grep -E "^(Filename|TOTAL|-)" "$out/report.txt" | head -1
grep -E "^TOTAL" "$out/report.txt"
uncovered=$(grep -c . "$out/uncovered.txt" || true)
implicit=$(grep -c . "$out/uncovered-implicit.txt" || true)
printf '%s\n' "Functions and closures never called: ${uncovered}  (list: ${out}/uncovered.txt)"
printf '%s\n' "Short-circuit branches (??, &&, ||) never taken: ${implicit}  (informational: ${out}/uncovered-implicit.txt)"

[[ "$status" -eq 0 ]] || { printf '%s\n' "Error: tests failed (status ${status})" >&2; exit "$status"; }
if $check && [[ "$uncovered" -ne 0 ]]; then
    printf '%s\n' "Error: ${uncovered} function(s) are not covered by tests." >&2
    exit 1
fi
