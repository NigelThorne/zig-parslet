"""Black-box authoring diagnostics against the built commands."""
import json
import pathlib
import subprocess
import tempfile
import unittest

BIN = pathlib.Path(__file__).resolve().parents[1] / "zig-out/bin"


class AuthoringTests(unittest.TestCase):
    def run_cli(self, command, grammar, input_text=None, *, stdin=False):
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "case.peg"
            path.write_text(grammar)
            args = [str(BIN / command), "--json", str(path)]
            if input_text is not None and not stdin:
                input_path = path.with_suffix(".txt")
                input_path.write_text(input_text)
                args.append(str(input_path))
            elif input_text is not None:
                args.append("-")
            process = subprocess.run(args, input=input_text if stdin else None,
                                     text=True, capture_output=True, timeout=10)
            return process.returncode, json.loads(process.stdout)

    def test_backtracked_success_and_partial_literal(self):
        grammar = 'root document\ndocument <- header (first / second)\nheader <- "Hi "\nfirst <- prefix "X"\nprefix <- "abc"\nsecond <- "ab" "Y"\n'
        code, data = self.run_cli("peg_test", grammar, "Hi abcZ", stdin=True)
        self.assertEqual(code, 1)
        summary = data["summary"]
        self.assertEqual(summary["furthest_attempt"]["rule"], "prefix")
        self.assertEqual(summary["furthest_attempt"]["furthest"], 6)
        self.assertEqual(summary["last_success"]["rule"], "prefix")
        self.assertEqual(summary["last_success"]["disposition"], "backtracked")
        self.assertEqual(data["error"]["offset"], 6)
        events = data["trace"]
        self.assertEqual(len({event["id"] for event in events}), len(events))
        ids = {event["id"] for event in events}
        self.assertTrue(all(event["parent_id"] is None or event["parent_id"] in ids for event in events))
        self.assertTrue(all(event["furthest"] >= event["start"] for event in events))
        self.assertTrue(all(event["end"] == event["start"] for event in events if not event["matched"]))
        self.assertTrue(all("grammar_end" in item and "attempt_id" in item for item in data["error"]["expected"]))
        self.assertIn("grammar_end", data["error"])

    def test_lookahead_and_synthetic_eof(self):
        code, data = self.run_cli("peg_test", 'root document\ndocument <- &probe "Z"\nprobe <- "abcdef"\n', "abcdef", stdin=True)
        self.assertEqual(code, 1)
        self.assertEqual(data["error"]["offset"], 0)
        self.assertEqual(data["summary"]["furthest_attempt"]["rule"], "probe")
        self.assertEqual(data["summary"]["furthest_attempt"]["disposition"], "lookahead")
        self.assertEqual(data["summary"]["final_failure"]["offset"], 0)
        code, data = self.run_cli("peg_test", 'root document\ndocument <- "Hi"\n', "Hi!")
        self.assertEqual(code, 1)
        self.assertEqual(data["error"]["offset"], 2)
        self.assertTrue(data["summary"]["final_failure"]["synthetic_eof"])
        self.assertTrue(data["trace"][0]["matched"])

    def test_truncation_counts_beyond_recorded_events(self):
        code, data = self.run_cli("peg_test", 'root document\ndocument <- part* "Z"\npart <- "a"\n', "a" * 1100 + "X", stdin=True)
        self.assertEqual(code, 1)
        summary = data["summary"]
        self.assertTrue(summary["trace_truncated"])
        self.assertEqual(summary["recorded_attempts"], 1024)
        self.assertEqual(summary["omitted_attempts"], summary["total_attempts"] - 1024)
        self.assertEqual(len(data["trace"]), 1024)
        self.assertGreater(summary["furthest_attempt"]["furthest"], 1024)

    def test_partial_literal_reports_progress_and_exact_token_span(self):
        grammar = 'root document\ndocument <- word\nword <- "abcdef"\n'
        code, data = self.run_cli("peg_test", grammar, "abcX")
        self.assertEqual(code, 1)
        word = next(event for event in data["trace"] if event["rule"] == "word")
        self.assertEqual((word["start"], word["end"], word["furthest"]), (0, 0, 3))
        expectation = data["error"]["expected"][0]
        self.assertEqual(grammar[expectation["grammar_offset"]:expectation["grammar_end"]], '"abcdef"')
        self.assertEqual(expectation["attempt_id"], word["id"])

    def test_repeated_invocations_have_distinct_ids(self):
        code, data = self.run_cli("peg_test", 'root document\ndocument <- word word\nword <- "a"\n', "aa")
        self.assertEqual(code, 0)
        words = [event for event in data["trace"] if event["rule"] == "word"]
        self.assertEqual(len(words), 2)
        self.assertNotEqual(words[0]["id"], words[1]["id"])
        self.assertEqual(words[0]["parent_id"], words[1]["parent_id"])
        self.assertEqual([event["start"] for event in words], [0, 1])

    def test_inherited_fd_and_document_mode_skip_assertions(self):
        grammar = 'root document\ndocument <- "Hi"\n@test(missing) "unfinished" { invalid assertions }\n'
        with tempfile.TemporaryDirectory() as directory, tempfile.TemporaryFile() as source:
            path = pathlib.Path(directory) / "case.peg"
            path.write_text(grammar)
            source.write(b"Hi")
            source.seek(0)
            fd = source.fileno()
            result = subprocess.run([str(BIN / "peg_test"), "--json", str(path), f"/dev/fd/{fd}"],
                                    pass_fds=(fd,), capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(result.stderr, "")
            self.assertEqual(json.loads(result.stdout)["value"], "Hi")

    def test_human_capture_mismatch_includes_summary(self):
        grammar = 'root document\ndocument <- "a"\n@test "wrong expectation" { input: "a" expect: "b" }\n'
        with tempfile.TemporaryDirectory() as directory:
            path = pathlib.Path(directory) / "case.peg"
            path.write_text(grammar)
            result = subprocess.run([str(BIN / "peg_test"), str(path)], capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 1)
            self.assertIn("capture tree mismatch", result.stdout)
            self.assertIn("Last local match:", result.stdout)
            self.assertIn("parent=", result.stdout)

    def test_embedded_metadata_and_parse_compatibility(self):
        grammar = '''root document
document <- word
word <- "a"
@test "default" { input: "a" expect: "a" }
@test(word) "named" { input: "a" expect: "a" }
@test(document) "explicit root" { input: "b" reject: true }
'''
        code, data = self.run_cli("peg_test", grammar)
        self.assertEqual(code, 0)
        self.assertEqual(data["root_rule"], "document")
        self.assertEqual([(t["rule"], t["assertion"], t["is_root"]) for t in data["tests"]],
                         [("document", "expect", True), ("word", "expect", False), ("document", "reject", True)])
        self.assertTrue(all(t["summary"] is not None and isinstance(t["trace"], list) for t in data["tests"]))
        for stdin in (False, True):
            code, value = self.run_cli("peg_parse", grammar, "a", stdin=stdin)
            self.assertEqual((code, value), (0, "a"))
            code, document = self.run_cli("peg_test", grammar, "a", stdin=stdin)
            self.assertEqual(code, 0)
            self.assertIsNotNone(document["summary"])


if __name__ == "__main__":
    unittest.main()
