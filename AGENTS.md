# Zig Parslet

Use Zig 0.16.0 with `mise exec -- zig ...`, not the Zig on PATH.

Commands are peg_parse, peg_test and peg_transform. Grammar files use .peg; transform files use .pegtx. Read SPEC.md for contracts.

Use test-first changes. Runtime code uses only the Zig standard library. Run `mise exec -- zig fmt --check build.zig src`, `mise exec -- zig build test`, `mise exec -- zig build`, and `python3 tests/cli_test.py` before declaring completion. Do not add npm tooling to this Zig project.

Workers own only assigned files. Do not change shared interfaces without parent agreement. Do not commit, push, create remote repositories, notify the user or change global toolchains. Report results and blockers to the parent.
