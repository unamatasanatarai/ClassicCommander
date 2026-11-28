#!/usr/bin/env python3
"""Tests for the CRAP analyzer. Run: python3 tools/crap/test_crap.py"""

import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import crap  # noqa: E402

cx = crap.calculate_cyclomatic_complexity


class ComplexityTests(unittest.TestCase):
    def test_straight_line_code_is_one(self):
        self.assertEqual(cx("let a = 1\nprint(a)"), 1)

    def test_each_branch_keyword(self):
        self.assertEqual(cx("if a {}"), 2)
        self.assertEqual(cx("guard a else { return }"), 2)
        self.assertEqual(cx("for x in xs {}"), 2)
        self.assertEqual(cx("while a {}"), 2)
        self.assertEqual(cx("do { try f() } catch {}"), 2)

    def test_repeat_while_counts_once(self):
        self.assertEqual(cx("repeat { } while a"), 2)

    def test_pattern_conditions_count_once(self):
        self.assertEqual(cx("if case .some(let x) = y {}"), 2)
        self.assertEqual(cx("guard case .a = y else { return }"), 2)
        self.assertEqual(cx("for case let x? in xs {}"), 2)

    def test_condition_lists_count_each_clause(self):
        self.assertEqual(cx("if let a = b, a > 1 {}"), 3)
        self.assertEqual(cx("guard let a = b, case .x = a, f(1, 2) else { return }"), 4)
        self.assertEqual(cx("if f([1, 2], (3, 4)) {}"), 2)

    def test_switch_counts_labels_not_default(self):
        self.assertEqual(cx("switch v { case 1, 2: break\n case 3: break\n default: break }"), 3)

    def test_logical_operators(self):
        self.assertEqual(cx("let x = a && b || c ?? d"), 4)

    def test_ternary_but_not_optionals(self):
        self.assertEqual(cx("let x = a ? 1 : 2"), 2)
        self.assertEqual(cx("let x = a?.b ?? c\nlet y = try? f()\nlet z = v as? Int\nlet w: Int? = nil"), 2)
        self.assertEqual(cx("let x = a ? -1 : 2"), 2)

    def test_strings_hide_code_but_interpolations_do_not(self):
        self.assertEqual(cx('let u = "ftp://host"\nif a {}\nlet v = "x"'), 2)
        self.assertEqual(cx('let s = "if a && b { } /* x"'), 1)
        self.assertEqual(cx('let s = "n: \\(a ? 1 : 2)"'), 2)
        self.assertEqual(cx('let s = "n: \\(f("x)", a && b))"'), 2)
        self.assertEqual(cx('let s = """\nif a && b\n"""\nif c {}'), 2)
        self.assertEqual(cx('let s = #"raw " if && \\(x) "#\nif c {}'), 2)
        self.assertEqual(cx('let s = #"raw \\#(a ? 1 : 2)"#'), 2)

    def test_comments(self):
        self.assertEqual(cx("// if a && b\n/* if /* nested */ if */ let x = 1"), 1)

    def test_directives_are_not_branches(self):
        self.assertEqual(cx("#if DEBUG || os(macOS)\nprint(1)\n#elseif X\n#else\n#endif"), 1)
        self.assertEqual(cx('if #available(macOS 12, *) {}\nlet s = #selector(f)'), 2)

    def test_keywords_as_member_names(self):
        self.assertEqual(cx("let a = Style.default\nlet b = x.`for`\nlet c = `if`"), 1)

    def test_crap_formula(self):
        self.assertEqual(crap.calculate_crap(5, 1.0), 5.0)
        self.assertEqual(crap.calculate_crap(5, 0.0), 30.0)
        self.assertEqual(crap.calculate_crap(4, 0.5), 6.0)


SWIFT = """func outer(a: Bool) -> Int {
    let xs = [1].map { v in v > 0 ? 1 : 2 }
    if a { return 1 }
    return xs.count
}
func ünïcode() -> String { let s = "żółć"; return s.isEmpty ? "a" : s }
"""


def region(l1, c1, l2, c2, count, kind=0):
    return [l1, c1, l2, c2, count, 0, 0, kind]


class ExtractionTests(unittest.TestCase):
    def run_extract(self, functions):
        with tempfile.TemporaryDirectory() as tmp:
            src_dir = os.path.join(tmp, "Sources", "App")
            os.makedirs(src_dir)
            path = os.path.join(src_dir, "A.swift")
            with open(path, "w", encoding="utf-8") as f:
                f.write(SWIFT)
            for fn in functions:
                fn["filenames"] = [path]
            export = os.path.join(tmp, "export.json")
            with open(export, "w") as f:
                json.dump({"data": [{"functions": functions}]}, f)
            return crap.extract_function_data(export, tmp)

    def test_closures_are_cut_out_of_their_parent(self):
        data = self.run_extract([
            {"name": "outer", "count": 1, "regions": [region(1, 28, 5, 2, 1), region(3, 10, 3, 22, 0)]},
            {"name": "closure #1 in outer", "count": 1, "regions": [region(2, 20, 2, 44, 1)]},
        ])
        by = {r["name"]: r for r in data["functions"]}
        # outer: 1 + if (the closure's ternary belongs to the closure)
        self.assertEqual(by["outer"]["complexity"], 2)
        self.assertEqual(by["outer"]["coverage"], 50.0)
        self.assertEqual(by["closure #1 in outer"]["complexity"], 2)

    def test_utf8_byte_columns(self):
        # Line 6: the body starts at char col 26; "żółć" is 4 chars but 8 bytes.
        line = SWIFT.splitlines()[5]
        start_b = len(line[: line.index("{")].encode()) + 1
        end_b = len(line.encode()) + 1
        data = self.run_extract([
            {"name": "u", "count": 1, "regions": [region(6, start_b, 6, end_b, 1)]},
        ])
        self.assertEqual(data["functions"][0]["complexity"], 2)

    def test_duplicate_records_are_merged(self):
        regions = [region(1, 28, 5, 2, 0), region(3, 10, 3, 22, 0)]
        hit = [region(1, 28, 5, 2, 1), region(3, 10, 3, 22, 0)]
        data = self.run_extract([
            {"name": "outer", "count": 0, "regions": regions},
            {"name": "outer", "count": 1, "regions": hit},
        ])
        self.assertEqual(len(data["functions"]), 1)
        self.assertEqual(data["functions"][0]["coverage"], 50.0)

    def test_implicit_closures_stay_in_parent(self):
        data = self.run_extract([
            {"name": "outer", "count": 1, "regions": [region(1, 28, 5, 2, 1)]},
            {"name": "implicit closure #1 in outer", "count": 1, "regions": [region(3, 8, 3, 9, 1)]},
        ])
        self.assertEqual([r["name"] for r in data["functions"]], ["outer"])
        self.assertEqual(data["summary"]["skipped_implicit_closures"], 1)


class BaselineTests(unittest.TestCase):
    def fn(self, name, score, line=1):
        return {"file": "A.swift", "line": line, "name": name, "crap": score, "is_crap": score > 6}

    def test_gate(self):
        base = [self.fn("a", 10), self.fn("b", 8), self.fn("c", 9)]
        now = [self.fn("a", 10, line=40), self.fn("b", 9), self.fn("c", 2), self.fn("d", 7)]
        crap._assign_keys(base)
        crap._assign_keys(now)
        result = crap.compare_with_baseline({"functions": now}, {"functions": base})
        self.assertEqual([r["name"] for r in result["new"]], ["d"])
        self.assertEqual([r["name"] for r in result["worse"]], ["b"])
        self.assertEqual(result["fixed"], 1)

    def test_same_names_get_ordinals(self):
        rows = [self.fn("closure #1 in f", 1, line=9), self.fn("closure #1 in f", 1, line=3)]
        crap._assign_keys(rows)
        self.assertEqual(rows[1]["key"], "A.swift::closure #1 in f")
        self.assertEqual(rows[0]["key"], "A.swift::closure #1 in f#1")


if __name__ == "__main__":
    unittest.main()
