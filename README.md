# vouch

[![CI](https://github.com/richardcocks/vouch/actions/workflows/ci.yml/badge.svg)](https://github.com/richardcocks/vouch/actions/workflows/ci.yml)

A gleeunit compatible test runner for Gleam.

- **Failures that read like sentences.** `assert` payloads decode into an
  expected/actual report, phrased for the operator that failed — the
  wording NUnit, xUnit and Jest trained everyone to read — instead of a
  dump of raw operands. The payload's byte offsets are used to quote the
  failing code back, so a predicate names itself and a `let assert` names
  the pattern it wanted. Every failure carries its file and line.

  ```
  Failures:

    playground_test.failing_assert_test  (test/playground_test.gleam:28)
      Expected: 5
      But was:  4

    playground_test.failing_predicate_test  (test/playground_test.gleam:35)
      Expected: playground.within_budget(spend) to be True
      But was:  False
        spend = 250

    playground_test.failing_let_assert_test  (test/playground_test.gleam:40)
      Expected: a value matching Ok(n)
      But was:  Error("the port was closed")
  ```

- **Todo is an outcome, not a failure.** A test that hits `todo` in the code
  under test reports as `todo` (yellow, still exit 1): during TDD, "not
  implemented yet" reads differently from "implemented wrong". Tests blocked
  on the same todo site are grouped into one work item. A test whose *body*
  is `todo` is a pending stub: reported as skipped, exit 0. Todos inside OTP
  processes (e.g. a gen_server callback) are recognised too.
- **Machine-readable output.** `--format=json` emits a JSONL event stream;
  `--junit=path` writes JUnit XML alongside the console output for CI test
  reporting; `--format=teamcity` streams TeamCity service messages for CI
  servers that read results from stdout as they happen. No other
  general-purpose Gleam runner offers any of these.
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
functions ending in `_test`.

## Assertions: use `assert`

Assertions need no library. `assert`, `let assert`, `panic`, and `todo`
are language features, and vouch's rich failure output is decoded from
the payloads the compiler emits for them — that decoding is the whole
reason the expected/actual report exists.

Because the payload carries the operator, the report says what the
operator meant: `assert x < limit` reads `Expected: less than 10 / But
was: 12`. Because it carries byte offsets, the report can quote the
source: a failing predicate prints the call as you wrote it, plus the
value behind each argument that was not a literal. Source quoting is a
bonus on top of the payload — if the file cannot be read back (a panic
from a dependency, a runtime without read permission) the wording falls
back to the operands alone. No matcher library needed to get NUnit-grade
failure messages.

`gleeunit/should` is a different story. Those calls still *run* under
vouch: they are ordinary functions that panic, so a suite that keeps
gleeunit as a dev-dependency for them will pass and fail correctly. But
a `should.equal` failure reaches the runner as a bare panic carrying
only a message string. There are no operands to take apart, so it prints
as one flat line and you get none of the detail you switched runners
for. gleeunit's own documentation now says to use the `assert` keyword
instead of that module.

So convert first, then swap the runner:

```sh
gleam run -m asset update
```

[asset](https://github.com/gearsDatapacks/asset) rewrites `should` calls
into `assert` syntax across your `test/` directory.

vouch deliberately ships no `should` module of its own. Providing the
compatibility without the failure detail would make the swap look like
it changed nothing, which is worse than asking for one mechanical
conversion. There is no legacy cliff here either: vouch requires Gleam
>= 1.14 and `assert` arrived in 1.11, so every project that can compile
vouch at all already has the keyword.

## Usage

```sh
gleam test                              # run everything
gleam test -- --filter=parser           # tests whose module.function contains "parser"
gleam test -- --format=json             # JSONL event stream on stdout
gleam test -- --format=teamcity         # TeamCity service messages on stdout
gleam test -- --junit=report.xml        # also write JUnit XML for CI
gleam test -- --timeout=1000            # per-test timeout in ms (Erlang target)
gleam test -- --parallel                # concurrent tests (Erlang target); =n sets workers
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

To quit, press `q` then Enter. Ctrl+C is the BEAM's, not vouch's: it
opens the emulator's BREAK menu (choose `a` to abort there); SIGINT
cannot be reclaimed by a running program, so `q` is the clean exit.

## Outcomes

| Outcome | Meaning | Exit code contribution |
| --- | --- | --- |
| pass | ran without panicking | 0 |
| fail | assert/panic/crash/timeout | 1 |
| todo | hit `todo` in code under test | 1 — unimplemented is still not done |
| skip | test body is a `todo` (pending stub) | 0 |

## Target differences

Both targets (Erlang and JavaScript) are supported from the same suite.
On Erlang, tests run in isolated processes with timeouts, and `--parallel`
runs them concurrently (`--parallel=n` sets the worker count; bare
`--parallel` uses one per scheduler) while still reporting results in
deterministic discovery order. Sequential remains the default: tests that
share registered processes, files, or ports are not parallel-safe by
convention, so concurrency is opt-in. On JavaScript, tests run
sequentially in-process: async test functions are awaited, but a test
that never resolves cannot be interrupted, and `--timeout` and
`--parallel` have no effect (vouch says so rather than pretending).

Running under Deno needs permissions in your project's `gleam.toml`:
read access for discovery and source quoting, write access if you use
`--junit`, and `NO_COLOR` for colour detection.

```toml
[javascript.deno]
allow_read = ["gleam.toml", "src", "test", "build"]
allow_write = ["."]
allow_env = ["NO_COLOR"]
```

Without `allow_read` on `src`, failure reports for panics inside
application code lose their source quoting (the expected/actual lines
remain); without `allow_write`, `--junit` reports a write failure on
stderr.

## Not supported

Hand-written `.erl` EUnit test modules (generators, fixtures) that happen
to run under gleeunit's EUnit delegation are out of scope, permanently.
Keep running those with EUnit or rebar3.

## Development

Design documents live in `docs/` (Typst; `pwsh docs/build.ps1` renders PDF
and HTML). `examples/playground/` is a scratch consumer with one test per
outcome flavour — the place to see vouch's output on failing, slow, and
todo-blocked tests, and the fixture for the end-to-end tests.
