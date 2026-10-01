#!/usr/bin/env python3
"""Black-box acceptance tests. Build first: mise exec -- zig build."""
import csv
import io
import json
import pathlib
import random
import subprocess
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out" / "bin"
GREETING = '''root greeting
greeting <- "Hi " who:[a-zA-Z]+
@test "captures name" { input: "Hi World" expect: { who: "World" } }
@test "missing name" { input: "Hi " reject: true }
'''


class CliTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = pathlib.Path(self.temp.name)

    def file(self, name, text):
        path = self.directory / name
        path.write_text(text)
        return str(path)

    def run_cli(self, command, *args, data=None):
        binary = BIN / command
        self.assertTrue(binary.is_file(), f"{command} has not been built")
        return subprocess.run([str(binary), *map(str, args)], input=data,
                              text=True, capture_output=True, timeout=10)

    def test_help(self):
        for command in ("peg_parse", "peg_test", "peg_transform"):
            with self.subTest(command=command):
                result = self.run_cli(command, "--help")
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn(command, result.stdout)
                self.assertIn("--json", result.stdout)

    def test_unknown_flag_fails_before_opening_files(self):
        for command in ("peg_parse", "peg_test", "peg_transform"):
            result = self.run_cli(command, "nonexistent", "--bogus")
            self.assertEqual(result.returncode, 2)
            self.assertIn("unknown flag", result.stderr)
            self.assertIn("--help", result.stderr)

    def test_missing_arguments_are_usage_errors(self):
        for command in ("peg_parse", "peg_test", "peg_transform"):
            result = self.run_cli(command)
            self.assertEqual(result.returncode, 2)
            self.assertIn("usage", result.stderr.lower())

    def test_parse_stdin_capture(self):
        grammar = self.file("g.peg", GREETING)
        result = self.run_cli("peg_parse", grammar, data="Hi World")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"who": "World"})
        self.assertEqual(result.stderr, "")

    def test_parse_named_input(self):
        grammar = self.file("g.peg", GREETING)
        source = self.file("input.txt", "Hi Nigel")
        result = self.run_cli("peg_parse", grammar, source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"who": "Nigel"})

    def test_parse_rejects_trailing_input(self):
        grammar = self.file("g.peg", GREETING)
        result = self.run_cli("peg_parse", grammar, data="Hi World!")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "")
        self.assertIn("^", result.stderr)
        self.assertIn("1:9", result.stderr)
        result = self.run_cli("peg_parse", "--json", grammar, data="Hi World!")
        error = json.loads(result.stdout)["error"]
        self.assertEqual(len(error["expected"]), 1)
        self.assertEqual(error["expected"][0]["message"], "expected end of input")

    def test_parse_structured_error(self):
        grammar = self.file("g.peg", GREETING)
        result = self.run_cli("peg_parse", "--json", grammar, data="Hi ")
        self.assertEqual(result.returncode, 1)
        report = json.loads(result.stdout)
        self.assertEqual(report["error"]["line"], 1)
        self.assertEqual(report["error"]["column"], 4)
        self.assertIn("[a-zA-Z]", report["error"]["message"])

    def test_parse_skips_invalid_test_contents(self):
        grammar = self.file("g.peg", 'root r\nr <- "ok"\n@test "unfinished" { nonsense: [42] }\n')
        result = self.run_cli("peg_parse", grammar, data="ok")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), "ok")
        result = self.run_cli("peg_test", grammar)
        self.assertEqual(result.returncode, 2)

    def test_embedded_tests(self):
        result = self.run_cli("peg_test", self.file("g.peg", GREETING))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("captures name", result.stdout)
        self.assertIn("missing name", result.stdout)
        self.assertIn("2 passed", result.stdout)

    def test_embedded_test_structured_report(self):
        result = self.run_cli("peg_test", "--json", self.file("g.peg", GREETING))
        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["passed"], 2)
        self.assertEqual(report["failed"], 0)
        self.assertEqual(len(report["tests"]), 2)

    def test_tree_mismatch(self):
        grammar = self.file("g.peg", GREETING.replace('expect: { who: "World" }', 'expect: { who: "Wrong" }'))
        result = self.run_cli("peg_test", grammar)
        self.assertEqual(result.returncode, 1)
        self.assertIn("expected", result.stdout.lower())
        self.assertIn("actual", result.stdout.lower())
        self.assertIn("Wrong", result.stdout)
        self.assertIn("World", result.stdout)

    def test_unexpected_success(self):
        grammar = self.file("g.peg", 'root r\nr <- "ok"\n@test "rejects" { input: "ok" reject: true }')
        result = self.run_cli("peg_test", grammar)
        self.assertEqual(result.returncode, 1)
        self.assertIn("unexpected", result.stdout.lower())

    def test_no_tests_is_explicit(self):
        result = self.run_cli("peg_test", self.file("g.peg", 'root r\nr <- "ok"'))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("no embedded tests", result.stdout.lower())

    def test_author_feedback_has_both_sources(self):
        grammar = self.file("g.peg", 'root r\nr <- "Hi " name\nname <- [a-z]+')
        source = self.file("bad.txt", "Hi 123")
        result = self.run_cli("peg_test", grammar, source)
        self.assertEqual(result.returncode, 1)
        self.assertIn("bad.txt:1:4", result.stdout)
        self.assertIn("g.peg:", result.stdout)
        self.assertIn("name", result.stdout)
        self.assertIn("^", result.stdout)
        self.assertIn("attempt", result.stdout.lower())

    def test_author_json_includes_trace_and_grammar_location(self):
        grammar = self.file("g.peg", 'root r\nr <- "Hi " name\nname <- [a-z]+')
        result = self.run_cli("peg_test", "--json", grammar, "-", data="Hi 123")
        self.assertEqual(result.returncode, 1)
        report = json.loads(result.stdout)
        self.assertIn("trace", report)
        self.assertTrue(report["trace"])
        self.assertEqual(report["error"]["grammar_location"]["line"], 3)

    def test_peg_operators(self):
        cases = [
            ('("a" / "b")+', "abba", "abba"),
            ('&"a" .', "a", "a"),
            ('!"x" .', "a", "a"),
            ('[^x]+', "abc", "abc"),
            ('(item:[a-z])+', "ab", [{"item": "a"}, {"item": "b"}]),
            ('name:[a-z]+', "ab", {"name": "ab"}),
            ('(name:"a")?', "a", {"name": "a"}),
            ('""?', "", ""),
            ('a:"a" " " b:"b"', "a b", {"a": "a", "b": "b"}),
            ('outer:(inner:"x")', "x", {"outer": {"inner": "x"}}),
            ('"\\u0061"', "a", "a"),
            ('[\\t\\n]+', "\t\n", "\t\n"),
            ('"😀"', "😀", "😀"),
        ]
        for expression, text, expected in cases:
            with self.subTest(expression=expression):
                grammar = self.file("g.peg", "root r\nr <- " + expression)
                result = self.run_cli("peg_parse", grammar, data=text)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), expected)

    def test_literal_error_identifies_first_differing_byte(self):
        grammar = self.file("g.peg", 'root r\nr <- "Hello"')
        result = self.run_cli("peg_parse", "--json", grammar, data="Hellu")
        self.assertEqual(result.returncode, 1)
        report = json.loads(result.stdout)
        self.assertEqual(report["error"]["column"], 5)
        self.assertIn("expected", report["error"]["message"].lower())
        self.assertEqual(report["error"]["rule"], "r")

    def test_choice_error_lists_all_tied_expectations(self):
        grammar = self.file("g.peg", 'root r\nr <- yes / no\nyes <- "yes"\nno <- "no"')
        result = self.run_cli("peg_parse", "--json", grammar, data="maybe")
        self.assertEqual(result.returncode, 1)
        error = json.loads(result.stdout)["error"]
        self.assertIn('"yes"', error["message"])
        self.assertIn('"no"', error["message"])
        self.assertEqual([item["rule"] for item in error["expected"]], ["yes", "no"])
        self.assertFalse(error["expected_truncated"])
        author = self.run_cli("peg_test", grammar, "-", data="maybe")
        self.assertEqual(author.returncode, 1)
        self.assertIn("g.peg:3:", author.stdout)
        self.assertIn("g.peg:4:", author.stdout)

    def test_choice_errors_keep_only_farthest_failure(self):
        grammar = self.file("g.peg", 'root r\nr <- "ab" / "x"')
        result = self.run_cli("peg_parse", "--json", grammar, data="ac")
        error = json.loads(result.stdout)["error"]
        self.assertEqual(error["column"], 2)
        self.assertEqual(len(error["expected"]), 1)
        self.assertIn('"ab"', error["message"])
        self.assertNotIn('"x"', error["message"])

    def test_successful_choice_does_not_pollute_later_failure(self):
        grammar = self.file("g.peg", 'root r\nr <- ("abcd" / "a") "z"')
        result = self.run_cli("peg_parse", "--json", grammar, data="abcX")
        error = json.loads(result.stdout)["error"]
        self.assertEqual(error["column"], 2)
        self.assertIn('"z"', error["message"])
        self.assertNotIn('"abcd"', error["message"])

    def test_probe_failures_do_not_add_expectations(self):
        grammar = self.file("g.peg", 'root r\nr <- !"x" "a"? "b"* ("yes" / "no")')
        result = self.run_cli("peg_parse", "--json", grammar, data="maybe")
        error = json.loads(result.stdout)["error"]
        self.assertEqual(len(error["expected"]), 2)
        self.assertIn('"yes"', error["message"])
        self.assertIn('"no"', error["message"])
        for ignored in ('"x"', '"a"', '"b"'):
            self.assertNotIn(ignored, error["message"])

    def test_expected_alternatives_are_bounded_and_deduplicated(self):
        choices = " / ".join(json.dumps(str(i)) for i in range(20))
        grammar = self.file("g.peg", "root r\nr <- " + choices)
        result = self.run_cli("peg_parse", "--json", grammar, data="")
        error = json.loads(result.stdout)["error"]
        self.assertEqual(len(error["expected"]), 16)
        self.assertTrue(error["expected_truncated"])
        grammar = self.file("g.peg", 'root r\nr <- "x" / "x" / "y"')
        result = self.run_cli("peg_parse", "--json", grammar, data="")
        error = json.loads(result.stdout)["error"]
        self.assertEqual(len(error["expected"]), 2)

    def test_numeric_literals_require_json_number_syntax(self):
        for number in ("01", "1.", "-.5", "1.e2", "1e+", "-", "00"):
            with self.subTest(number=number):
                rules = self.file("r.pegtx", '"x" => ' + number)
                result = self.run_cli("peg_transform", rules, data='"x"')
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                grammar = self.file("g.peg", 'root r\nr <- "x"\n@test "bad number" { input: "x" expect: ' + number + ' }')
                result = self.run_cli("peg_test", grammar)
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                # Production parsing still ignores the malformed assertion.
                result = self.run_cli("peg_parse", grammar, data="x")
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_canonical_numeric_literals_still_work(self):
        for number in ("0", "-0", "42", "-42", "1.5", "-0.5", "1e2", "1E-2", "1e+2"):
            with self.subTest(number=number):
                rules = self.file("r.pegtx", '"x" => ' + number)
                result = self.run_cli("peg_transform", rules, data='"x"')
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(json.loads(result.stdout), json.loads(number))

    def test_left_recursion_does_not_hang(self):
        grammar = self.file("g.peg", 'root r\nr <- r / "a"')
        result = self.run_cli("peg_parse", grammar, data="a")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("recurs", result.stderr.lower())

    def test_nullable_repetition_does_not_hang(self):
        grammar = self.file("g.peg", 'root r\nr <- ""*')
        result = self.run_cli("peg_parse", grammar, data="")
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(any(s in result.stderr.lower() for s in ("progress", "empty", "zero", "nullable")))

    def test_unknown_rule_is_diagnosed(self):
        result = self.run_cli("peg_parse", self.file("g.peg", "root r\nr <- missing"), data="a")
        self.assertEqual(result.returncode, 2)
        self.assertIn("missing", result.stderr)
        self.assertIn("g.peg:", result.stderr)

    def test_transform_stdin(self):
        rules = self.file("r.pegtx", '{ word: simple(w) } => w\n{ words: sequence(ws) } => join(ws, " ")')
        result = self.run_cli("peg_transform", rules, data='{"words":[{"word":"Hi"},{"word":"World"}]}')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), "Hi World")

    def test_transform_output_objects_and_conversion(self):
        rules = self.file("r.pegtx", '{ count: simple(n) } => { count: int(n), valid: true }')
        result = self.run_cli("peg_transform", rules, data='{"count":"42"}')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {"count": 42, "valid": True})

    def test_transform_bad_json(self):
        result = self.run_cli("peg_transform", self.file("r.pegtx", 'simple(x) => x'), data="not-json")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(result.stdout, "")
        self.assertIn("JSON", result.stderr)

    def test_transform_invalid_conversion(self):
        rules = self.file("r.pegtx", '{ n: simple(n) } => int(n)')
        result = self.run_cli("peg_transform", rules, data='{"n":"nope"}')
        self.assertEqual(result.returncode, 1)
        self.assertIn("r.pegtx:", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_transform_unknown_binding_is_diagnosed(self):
        rules = self.file("r.pegtx", '{ n: simple(n) } => missing')
        result = self.run_cli("peg_transform", rules, data='{"n":"1"}')
        self.assertEqual(result.returncode, 2)
        self.assertIn("missing", result.stderr)

    def test_transform_malformed_rules_exit_code(self):
        rules = self.file("r.pegtx", '{ n: simple(n) => n')
        for flags in ([], ["--json"]):
            result = self.run_cli("peg_transform", *flags, rules, data='null')
            self.assertEqual(result.returncode, 2)
            if flags:
                self.assertIn("error", json.loads(result.stdout))
            else:
                self.assertEqual(result.stdout, "")

    def test_transform_first_rule_only(self):
        rules = self.file("r.pegtx", '"a" => "b"\n"b" => "c"')
        result = self.run_cli("peg_transform", rules, data='"a"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), "b")

    def test_transform_integer_overflow_is_error_not_crash(self):
        rules = self.file("r.pegtx", 'simple(n) => int(n)')
        result = self.run_cli("peg_transform", rules, data='9.223372036854776e18')
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertNotIn("panic", result.stderr)

    def test_transform_nonfinite_float_is_error(self):
        for expression in ('float(n)', '1e999'):
            rules = self.file("r.pegtx", f'simple(n) => {expression}')
            result = self.run_cli("peg_transform", rules, data='"nan"')
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertNotIn("panic", result.stderr)

    def test_transform_unicode_surrogate_pair(self):
        rules = self.file("r.pegtx", '"face" => "\\ud83d\\ude00"')
        result = self.run_cli("peg_transform", rules, data='"face"')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), "😀")

    def test_email_diagnostic_renders_deep_rule_trace(self):
        result = self.run_cli("peg_test", ROOT / "examples/email.peg", "-", data="a@!")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Rule attempts", result.stdout)
        self.assertIn("FAIL", result.stdout)
        self.assertIn("word", result.stdout)
        self.assertNotIn("panic", result.stderr)

    def test_end_to_end_email(self):
        result = self.run_cli("peg_parse", ROOT / "examples/email.peg", data="a dot b at gmail dot com")
        self.assertEqual(result.returncode, 0, result.stderr)
        clean = self.run_cli("peg_transform", ROOT / "examples/email.pegtx", data=result.stdout)
        self.assertEqual(clean.returncode, 0, clean.stderr)
        self.assertEqual(json.loads(clean.stdout), "a.b@gmail.com")

    def test_unquote_rejects_json_byte_arrays(self):
        rules = self.file("r.pegtx", '{ x: simple(v) } => unquote(v)')
        for value in ('[65]', '[65,66]', '[]', '{}', 'true', '42', 'null'):
            with self.subTest(value=value):
                result = self.run_cli("peg_transform", rules, data=json.dumps({"x": value}))
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(result.stdout, "")
                self.assertIn("JSON string", result.stderr)

    def json_round_trip(self, document):
        parsed = self.run_cli("peg_parse", ROOT / "examples/json.peg", data=document)
        self.assertEqual(parsed.returncode, 0, parsed.stderr)
        transformed = self.run_cli("peg_transform", ROOT / "examples/json.pegtx", data=parsed.stdout)
        self.assertEqual(transformed.returncode, 0, transformed.stderr)
        return transformed.stdout

    def test_json_round_trip_values_and_containers(self):
        documents = [
            'null', 'true', 'false', '0', '-42', '3.125', '1e+3',
            '""', '"hello"', '[]', '{}', '[1]', '[[1]]', '[[[]]]',
            '[{}, [], [1, 2], {"nested": [false, null]}]',
            '{"single": [1]}', '{"a":1,"b":2}',
            '{"key\\n": "line\\nquote\\\"slash\\\\tab\\t"}',
            '{"é": "😀", "escaped": "\\ud83d\\ude00"}',
            '{"duplicate": 1, "duplicate": 2}',
            '{"json_number":"not a number","json_array":{"element":1},"json_empty_array":"","entry":{"key":"x","value":3}}',
        ]
        for document in documents:
            with self.subTest(document=document):
                output = self.json_round_trip(document)
                self.assertEqual(json.loads(output), json.loads(document))

    def test_json_round_trip_preserves_number_tokens(self):
        for number in ('-0', '1234567890123456789012345678901234567890',
                       '0.123456789012345678901234567890', '1e400', '1e-400', '1E+003'):
            with self.subTest(number=number):
                self.assertEqual(self.json_round_trip(number).strip(), number)

    def test_json_unicode_boundaries_and_escaped_controls(self):
        codepoints = [0x20, 0x7f, 0x80, 0x7ff, 0x800, 0xd7ff, 0xe000, 0xffff, 0x10000, 0x10ffff]
        value = {"nul\x00key": "\x00\b\f\n\r\t", "boundaries": "".join(map(chr, codepoints))}
        for ascii_only in (True, False):
            document = json.dumps(value, ensure_ascii=ascii_only)
            self.assertEqual(json.loads(self.json_round_trip(document)), value)

    def test_json_generated_corpus_matches_python(self):
        rng = random.Random(87213)
        scalars = [None, True, False, 0, -1, 2**80, 3.125, "", "text", "é😀", "line\n", "\\\""]
        def value(depth):
            kind = rng.randrange(3) if depth else 0
            if kind == 0:
                return rng.choice(scalars)
            if kind == 1:
                return [value(depth - 1) for _ in range(rng.randrange(4))]
            return {key: value(depth - 1) for key in rng.sample(["a", "b", "json_number", "line\n", "😀"], rng.randrange(4))}
        for index in range(60):
            expected = value(3)
            document = json.dumps(expected, ensure_ascii=index % 2 == 0, indent=2 if index % 3 == 0 else None)
            with self.subTest(index=index, document=document):
                self.assertEqual(json.loads(self.json_round_trip(document)), expected)

    def test_json_missing_value_diagnostic_points_after_colon(self):
        for document in ('{"count":}', '[{"a":}]'):
            result = self.run_cli("peg_parse", "--json", ROOT / "examples/json.peg", data=document)
            self.assertEqual(result.returncode, 1)
            error = json.loads(result.stdout)["error"]
            self.assertEqual(error["offset"], document.index('}'))
            self.assertIn('"null"', error["message"])

    def test_json_rejects_malformed_documents(self):
        documents = ['', '[1,]', '{"a":1,}', '[1 2]', '{"a" 1}',
                     '{a:1}', '01', '-01', '+1', '1.', '.1', '1e', '1e+',
                     'NaN', 'Infinity', 'true false', '/*comment*/null',
                     '"bad\\q"', '"\\uZZZZ"', '"\\ud800"', '"\\udc00"',
                     '"\\ud800\\u0041"', '"line\nfeed"', '"nul\x00byte"']
        for document in documents:
            with self.subTest(document=document):
                result = self.run_cli("peg_parse", "--json", ROOT / "examples/json.peg", data=document)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                error = json.loads(result.stdout)["error"]
                self.assertEqual(error["kind"], "input")
                self.assertTrue(error["message"])

    def test_json_rejects_invalid_utf8_in_strings(self):
        for raw in (b'"\x80"', b'"\xc0\xaf"', b'"\xed\xa0\x80"', b'"\xf4\x90\x80\x80"', b'"\xe2\x82"'):
            result = subprocess.run([str(BIN / "peg_parse"), "--json", str(ROOT / "examples/json.peg")],
                                    input=raw, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 1, result.stderr)
            self.assertEqual(json.loads(result.stdout)["error"]["kind"], "input")

    def test_json_example_document_round_trip(self):
        document = (ROOT / "examples/json.json").read_text()
        self.assertEqual(json.loads(self.json_round_trip(document)), json.loads(document))

    def csv_rows(self, document):
        parsed = self.run_cli("peg_parse", ROOT / "examples/csv.peg", data=document)
        self.assertEqual(parsed.returncode, 0, parsed.stderr)
        transformed = self.run_cli("peg_transform", ROOT / "examples/csv.pegtx", data=parsed.stdout)
        self.assertEqual(transformed.returncode, 0, transformed.stderr)
        return json.loads(transformed.stdout)

    def test_csv_empty_fields_rows_and_line_endings(self):
        documents = ['', '\n', '\r\n', '\r', '\n\n', ',', ',,', '""',
                     'a', 'a\n', 'a,b\r\nc,d', 'a\rb\r', 'a\n\nb\n',
                     '  a  ,00123,false,null', 'a,b,', '\ufeffname,value\n']
        for document in documents:
            with self.subTest(document=document):
                expected = list(csv.reader(io.StringIO(document, newline=''), strict=True))
                self.assertEqual(self.csv_rows(document), expected)

    def test_csv_quoted_commas_quotes_and_multiline_cells(self):
        documents = ['"a,b",c', '"say ""hello""",x', '""""',
                     '"line one\nline two",end\n', '"a\r\nb",c\r\n',
                     '"é😀",00123', '"a\rb",c', 'x,"",y']
        for document in documents:
            with self.subTest(document=document):
                expected = list(csv.reader(io.StringIO(document, newline=''), strict=True))
                self.assertEqual(self.csv_rows(document), expected)

    def test_csv_generated_corpus_matches_python(self):
        rng = random.Random(149031)
        cells = ['', 'plain', '00123', 'false', 'null', ' a ', ',', '"',
                 'a,b', 'say "hello"', 'line\nnext', 'line\r\nnext', 'é😀']
        for index in range(60):
            rows = [[rng.choice(cells) for _ in range(rng.randrange(5))]
                    for _ in range(rng.randrange(7))]
            stream = io.StringIO(newline='')
            csv.writer(stream, lineterminator='\r\n' if index % 2 else '\n').writerows(rows)
            document = stream.getvalue()
            with self.subTest(index=index, rows=rows):
                self.assertEqual(self.csv_rows(document), rows)

    def test_csv_rejects_invalid_quoting(self):
        for document in ('"unterminated', 'a,"unterminated', '"a"x,b',
                         'unquoted"quote,b', '"a" "b"', '"""'):
            with self.subTest(document=document):
                result = self.run_cli("peg_parse", "--json", ROOT / "examples/csv.peg", data=document)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertEqual(json.loads(result.stdout)["error"]["kind"], "input")

    def test_csv_unterminated_quote_points_to_eof(self):
        document = 'name,"unfinished'
        result = self.run_cli("peg_parse", "--json", ROOT / "examples/csv.peg", data=document)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(json.loads(result.stdout)["error"]["offset"], len(document))

    def test_csv_rejects_invalid_utf8_in_cells(self):
        for document in (b'a,\x80', b'"a\xff"', b'\xc0\xaf,b', b'"\xed\xa0\x80"'):
            result = subprocess.run([str(BIN / "peg_parse"), "--json", str(ROOT / "examples/csv.peg")],
                                    input=document, capture_output=True, timeout=10)
            self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
            self.assertEqual(json.loads(result.stdout)["error"]["kind"], "input")

    def test_csv_example_document(self):
        document = (ROOT / "examples/csv.csv").read_text()
        expected = list(csv.reader(io.StringIO(document, newline=''), strict=True))
        actual = self.csv_rows(document)
        self.assertEqual(actual, expected)
        self.assertIn('00123', actual[1])

    def test_shipped_embedded_tests(self):
        grammars = sorted((ROOT / "examples").glob("*.peg"))
        self.assertGreaterEqual(len(grammars), 2)
        for grammar in grammars:
            result = self.run_cli("peg_test", grammar)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertIn("passed", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
