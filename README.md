# vouch

[![CI](https://github.com/richardcocks/vouch/actions/workflows/ci.yml/badge.svg)](https://github.com/richardcocks/vouch/actions/workflows/ci.yml)

A test runner for Gleam. Compatible with the gleeunit convention — swap one
line and your existing suite runs unchanged — with the internals a test
runner should have:

- **Rich failures.** `assert` payloads decode into left/right/operator
  detail; `let assert` shows the unmatched value; every failure carries its
  file and line.
- **Todo is an outcome, not a failure.** A test that hits `todo` in the code
  under test reports as `todo` (yellow, still exit 1): during TDD, "not
  implemented yet" reads differently from "implemented wrong". Tests blocked
  on the same todo site are grouped into one work item. A test whose *body*
  is `todo` is a pending stub: reported as skipped, exit 0. Todos inside OTP
  processes (e.g. a gen_server callback) are recognised too.
- **Machine-readable output.** `--format=json` emits a JSONL event stream;
  `--junit=path` writes JUnit XML alongside the console output for CI test
  reporting. No other general-purpose Gleam runner offers either.
- **Process isolation on the BEAM.** Each test runs in its own monitored
  process: crashes are contained, linked-process deaths are attributed, and
  a hung test becomes a timeout failure instead of hanging `gleam test`
  forever.
- **Honest edge cases.** Zero tests discovered is a loud failure. A filter
  that matches nothing says so. BEAM crash reports go to stderr, never into
  your piped output.

## Install

```sh
gleam add --dev vouch
```

```diff
 // test/my_project_test.gleam
-import gleeunit
+import vouch

 pub fn main() {
-  gleeunit.main()
+  vouch.main()
 }
```

That is the whole migration. Tests are discovered by the ecosystem
convention: modules under `test/` ending in `_test`, public zero-arity
functions ending in `_test`. Assertions need no library — `assert`,
`let assert`, `panic`, and `todo` are language features, and existing
`gleeunit/should` calls keep working (they are ordinary functions that
panic).

## Usage

```sh
gleam test                              # run everything
gleam test -- --filter=parser           # tests whose module.function contains "parser"
gleam test -- --format=json             # JSONL event stream on stdout
gleam test -- --junit=report.xml        # also write JUnit XML for CI
gleam test -- --timeout=1000            # per-test timeout in ms (Erlang target)
gleam test -- --color=never             # console colour: auto | always | never
gleam run -m vouch -- watch             # rerun the suite on file change
```

### Watch mode

`gleam run -m vouch -- watch [options]` reruns the suite whenever `src/`,
`test/`, or `gleam.toml` changes. Options after `watch` pass through to
each inner run (`--filter=…`, `--timeout=…`, …); `--target=javascript`
watches your JavaScript-target tests. The watcher itself is a BEAM
program that re-invokes `gleam test` per cycle, so each rerun includes the
toolchain's incremental compile check — a compile error shows up in the
loop like any other red result, and the watcher keeps waiting for the fix.

To quit, press `q` then Enter. Ctrl+C also exits cleanly on Unix-like
systems; on Windows the BEAM turns Ctrl+C into its BREAK menu (choose
`a` for abort there — or just use `q`).

## Outcomes

| Outcome | Meaning | Exit code contribution |
| --- | --- | --- |
| pass | ran without panicking | 0 |
| fail | assert/panic/crash/timeout | 1 |
| todo | hit `todo` in code under test | 1 — unimplemented is still not done |
| skip | test body is a `todo` (pending stub) | 0 |

## Target differences

Both targets (Erlang and JavaScript) are supported from the same suite.
On Erlang, tests run in isolated processes with timeouts. On JavaScript,
tests run sequentially in-process: async test functions are awaited, but a
test that never resolves cannot be interrupted and `--timeout` has no
effect (vouch says so rather than pretending).

## Not supported

Hand-written `.erl` EUnit test modules (generators, fixtures) that happen
to run under gleeunit's EUnit delegation are out of scope, permanently.
Keep running those with EUnit or rebar3.

## Development

Design documents live in `docs/` (Typst; `pwsh docs/build.ps1` renders PDF
and HTML). `examples/playground/` is a scratch consumer with one test per
outcome flavour — the place to see vouch's output on failing, slow, and
todo-blocked tests, and the fixture for the end-to-end tests.
