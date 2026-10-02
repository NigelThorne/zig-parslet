#!/usr/bin/env python3
"""Bounded mutation/property tests of real binaries, not coverage-guided fuzzing.

Build first. Replay with PEG_FUZZ_SEED and PEG_FUZZ_CASES, optionally selecting
one unittest method. Each failure includes its seed, case and exact payload.
"""
import decimal
import json
import os
import pathlib
import random
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[1]
BIN = ROOT / "zig-out/bin"
SEED = int(os.environ.get("PEG_FUZZ_SEED", "8173"))
CASES = int(os.environ.get("PEG_FUZZ_CASES", "100"))
if not 1 <= CASES <= 10000:
    raise ValueError("PEG_FUZZ_CASES must be between 1 and 10000")


def mutate(rng, original):
    data = bytearray(original)
    alphabet = b'abc012<>/[]{}():,=!?*+\\\"\' \t\r\n\x00\x1b\x7f\x80\xff'
    for _ in range(rng.randint(1, 4)):
        pos = rng.randrange(len(data) + 1)
        operation = rng.randrange(3)
        if operation == 0:
            data[pos:pos] = bytes([rng.choice(alphabet)])
        elif operation == 1:
            del data[pos:pos + rng.randint(1, 3)]
        elif pos < len(data):
            data[pos] = rng.choice(alphabet)
    return bytes(data)


def peg_source(node):
    op, *args = node
    if op == "literal":
        return json.dumps(args[0])
    if op == "class":
        return "[ab]"
    if op == "any":
        return "."
    if op in ("seq", "choice"):
        return "(" + (" " if op == "seq" else " / ").join(map(peg_source, args)) + ")"
    if op in ("!", "&"):
        return op + "(" + peg_source(args[0]) + ")"
    return "(" + peg_source(args[0]) + ")" + op


def peg_match(node, text, pos=0):
    """Small independent recognition model; no captures, recursion or limits."""
    op, *args = node
    if op == "literal":
        return pos + len(args[0]) if text.startswith(args[0], pos) else None
    if op in ("class", "any"):
        return pos + 1 if pos < len(text) and (op == "any" or text[pos] in "ab") else None
    if op == "seq":
        for child in args:
            pos = peg_match(child, text, pos)
            if pos is None:
                return None
        return pos
    if op == "choice":
        for child in args:
            result = peg_match(child, text, pos)
            if result is not None:
                return result
        return None
    result = peg_match(args[0], text, pos)
    if op in ("!", "&"):
        return pos if (result is None) == (op == "!") else None
    if op == "?":
        return pos if result is None else result
    if op == "+" and result is None:
        return None
    while result is not None:
        if result == pos:
            raise AssertionError("test generator repeated a nullable expression")
        pos = result
        result = peg_match(args[0], text, pos)
    return pos


def expression(rng, depth=0):
    atom = lambda: rng.choice([("literal", "a"), ("literal", "ab"), ("class",), ("any",)])
    if depth >= 3 or rng.randrange(3) == 0:
        return atom()
    op = rng.choice(["seq", "choice", "?", "!", "&", "*", "+"])
    if op in ("seq", "choice"):
        return (op, expression(rng, depth + 1), expression(rng, depth + 1))
    # Only consuming atoms may be repeated; nullable repeat rejection is tested separately.
    return (op, atom() if op in ("*", "+") else expression(rng, depth + 1))


def strict_json(raw):
    def no_constant(value):
        raise ValueError(value)

    value = json.loads(raw.decode("utf-8"), parse_float=decimal.Decimal,
                       parse_constant=no_constant)

    def check_unicode(item):
        if isinstance(item, str):
            item.encode("utf-8")
        elif isinstance(item, list):
            for child in item:
                check_unicode(child)
        elif isinstance(item, dict):
            for key, child in item.items():
                check_unicode(key)
                check_unicode(child)
    check_unicode(value)
    return value


class FuzzTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.directory = pathlib.Path(self.temp.name)

    def file(self, name, data):
        path = self.directory / name
        path.write_bytes(data)
        return path

    def cli(self, name, *args, data=b""):
        result = subprocess.run([str(BIN / name), *map(str, args)], input=data,
                                capture_output=True, timeout=5)
        self.assertIn(result.returncode, (0, 1, 2), result.stderr)
        self.assertNotIn(b"\x1b", result.stderr, "raw terminal escape in diagnostic")
        if result.returncode:
            self.assertEqual(result.stdout, b"", result.stdout)
            self.assertTrue(result.stderr)
        else:
            strict_json(result.stdout)
        return result

    def test_peg_operator_combinations_match_reference(self):
        rng = random.Random(SEED)
        for case in range(CASES):
            tree = expression(rng)
            source = "root start\nstart <- " + peg_source(tree) + "\n"
            grammar = self.file("operators.peg", source.encode())
            # All a/b strings through length two, an outsider, and a longer random string.
            inputs = ["", "a", "b", "ab", "aa", "ba", "bb", "x",
                      "".join(rng.choices("abx", k=rng.randrange(3, 12)))]
            for text in inputs:
                with self.subTest(seed=SEED, case=case, grammar=source, input=text):
                    expected = peg_match(tree, text) == len(text)
                    result = self.cli("peg_parse", grammar, data=text.encode())
                    self.assertEqual(result.returncode, 0 if expected else 1, result.stderr)
                    if expected:
                        self.assertEqual(json.loads(result.stdout), text)
                    # The instrumented mode must agree with the production matcher.
                    author = subprocess.run([str(BIN / "peg_test"), "--json", str(grammar), "-"],
                                            input=text.encode(), capture_output=True, timeout=5)
                    self.assertEqual(author.returncode, result.returncode, author.stderr)
                    report = strict_json(author.stdout)
                    if expected:
                        self.assertEqual(report["value"], text)
                    else:
                        plain = subprocess.run([str(BIN / "peg_parse"), "--json", str(grammar), "-"],
                                               input=text.encode(), capture_output=True, timeout=5)
                        self.assertEqual(plain.returncode, result.returncode, plain.stderr)
                        error = strict_json(plain.stdout)["error"]
                        self.assertEqual(error["offset"], report["error"]["offset"])
                        self.assertEqual(error["message"], report["error"]["message"])
                        self.assertEqual(error["kind"], report["error"]["kind"])

    def test_mutated_grammar_definitions_do_not_crash(self):
        rng = random.Random(SEED + 1)
        seeds = [b'root s\ns <- value:[a-z]+\n', b'root s\ns <- ("a" / "ab")* !.\n',
                 b'root s\ns <- "a"\n@test "a" { input: "a" expect: "a" }\n',
                 b'root s\ns <- "a"\npart <- [a-z]+\n@test(part) "part" { input: "abc" expect: "abc" }\n']
        for case in range(CASES):
            source = mutate(rng, rng.choice(seeds))
            with self.subTest(seed=SEED, case=case, source=source):
                grammar = self.file("mutated.peg", source)
                self.cli("peg_parse", grammar, data=b"abc")
                # Exercise test-block parsing too; peg_test emits a JSON report on either path.
                result = subprocess.run([str(BIN / "peg_test"), "--json", str(grammar)],
                                        capture_output=True, timeout=5)
                self.assertIn(result.returncode, (0, 1, 2), result.stderr)
                strict_json(result.stdout)

    def test_mutated_transform_definitions_do_not_crash(self):
        rng = random.Random(SEED + 2)
        seeds = [b'{ x: simple(v) } => int(v)', b'{ x: subtree(v) } => { result: v }',
                 b'{ x: simple(v) } => concat("hi", v)', b'{ x: simple(v) } => require_equal(v, "1")']
        for case in range(CASES):
            source = mutate(rng, rng.choice(seeds))
            with self.subTest(seed=SEED, case=case, source=source):
                self.cli("peg_transform", self.file("mutated.pegtx", source), data=b'{"x":"1"}')

    def test_mutated_json_matches_strict_python(self):
        rng = random.Random(SEED + 3)
        seeds = [b'null', b'true', b'-12.50e+2', b'{"a":[1,false,null],"b":{}}',
                 b'"hello\\nworld"', '"café 😀"'.encode(), b'"\\uD83D\\uDE00"', b'[]']
        for case in range(CASES):
            document = mutate(rng, rng.choice(seeds))
            with self.subTest(seed=SEED, case=case, document=document):
                try:
                    expected = strict_json(document)
                    valid = True
                except (ValueError, UnicodeError):
                    valid = False
                parsed = self.cli("peg_parse", ROOT / "examples/json.peg", data=document)
                self.assertEqual(parsed.returncode, 0 if valid else 1, parsed.stderr)
                if valid:
                    actual = self.cli("peg_transform", ROOT / "examples/json.pegtx", data=parsed.stdout)
                    self.assertEqual(actual.returncode, 0, actual.stderr)
                    self.assertEqual(strict_json(actual.stdout), expected)

    def test_mutated_xml_successes_match_python(self):
        rng = random.Random(SEED + 4)
        seeds = [b'<a/>', b'<a><b/>hello &amp; world</a>', b'<a>left<b>inside</b>right</a>']

        def convert(element):
            children = [element.text] if element.text else []
            for child in element:
                children.append(convert(child))
                if child.tail:
                    children.append(child.tail)
            return {"tag": element.tag, "children": children}

        for case in range(CASES):
            document = mutate(rng, rng.choice(seeds))
            with self.subTest(seed=SEED, case=case, document=document):
                parsed = self.cli("peg_parse", ROOT / "examples/xml.peg", data=document)
                self.assertNotEqual(parsed.returncode, 2, parsed.stderr)
                if parsed.returncode:
                    continue  # XML features outside the subset are allowed to fail.
                actual = self.cli("peg_transform", ROOT / "examples/xml.pegtx", data=parsed.stdout)
                self.assertNotEqual(actual.returncode, 2, actual.stderr)
                if actual.returncode:
                    with self.assertRaises(ET.ParseError):
                        ET.fromstring(document)
                else:
                    self.assertEqual(json.loads(actual.stdout), convert(ET.fromstring(document)))

    def test_resource_guards_fail_without_hanging(self):
        grammars = [b'root s\ns <- s\n', b'root s\ns <- ("a"?)*\n',
                    b'root s\ns <- (&"a")+\n',
                    b'root s\ns <- ' + b'(' * 600 + b'"a"' + b')' * 600 + b'\n']
        for source in grammars:
            with self.subTest(source=source):
                result = self.cli("peg_parse", self.file("limit.peg", source), data=b"a")
                self.assertNotEqual(result.returncode, 0)
        # Small input with recursive exponential backtracking must hit the work cap.
        source = b'root s\ns <- "a" s "b" / "a" s "c" / ""\n'
        result = self.cli("peg_parse", self.file("work.peg", source), data=b"a" * 25 + b"x")
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(b"limit", result.stderr)
        result = self.cli("peg_parse", ROOT / "examples/json.peg", data=b"[" * 300 + b"0" + b"]" * 300)
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn(b"limit", result.stderr)


if __name__ == "__main__":
    print(f"Fuzz seed={SEED}, cases={CASES} per randomized test", flush=True)
    unittest.main(verbosity=2)
