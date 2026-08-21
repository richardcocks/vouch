# vouch

[![Package Version](https://img.shields.io/hexpm/v/vouch)](https://hex.pm/packages/vouch)
[![Hex Docs](https://img.shields.io/badge/hex-docs-ffaff3)](https://hexdocs.pm/vouch/)
[![CI](https://github.com/richardcocks/vouch/actions/workflows/ci.yml/badge.svg)](https://github.com/richardcocks/vouch/actions/workflows/ci.yml)

<img width="814" height="630" alt="image" src="https://github.com/user-attachments/assets/8a0a81bc-0641-4f32-890a-4bee560fa2e4" />


A gleeunit compatible test runner for Gleam.

- **Watch mode**
- **JSON, XML and Teamcity outputs**
- **Failures due to todo in code are a special category** 
- **Skip support with todo in test code**
- **Process isolation and parallel execution for erlang target**
- **Test Filtering**
- **Human readable assert messages**

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

Tests are discovered by the same heuristics that gleeunit uses, with tests as `module_tests.gleam`, and the usual conventions.

## Assertions: use `let assert`

Use `let assert`, or another `assert` based assertion library to assert. Vouch formats assert failures in 
the most human-friendly way I could manage.

## Example Usage

```sh
gleam test
gleam test -- --filter=parser
gleam test -- --test-name-filter=parser # alias for --filter for startest compatibility ( zed extension convention )
gleam test -- --format=json
gleam test -- --format=teamcity
gleam test -- --junit=report.xml
gleam test -- --timeout=1000            # Erlang target only
gleam test -- --parallel                # Erlang target only
gleam test -- --show-crash-reports      # Erlang target only, see below
gleam test -- --color=never             # console colour: auto | always | never
gleam run -m vouch -- watch             # rerun the suite on file change
```

### Watch mode

`gleam run -m vouch -- watch [options]` reruns the suite whenever there are changes in `src/`,
`test/`, or `gleam.toml`. It works on both targets, and the inner test runs follow the watcher's
own target — so `gleam run --target javascript -m vouch -- watch` watches JavaScript tests
without the BEAM installed. To run the watcher and the tests on different targets, pass
`--target=erlang|javascript` after the `--`; it applies to the inner runs:
`gleam run -m vouch -- watch --target=javascript` supervises JavaScript tests from the BEAM.

Keys depend on the host target:

- **Erlang**: press `q` then Enter to quit. It's a bit awkward, but Ctrl+C is captured by the
  BEAM and I couldn't get it to work properly and I don't have enough environments to test the
  specifics for trying to overcome that issue.
- **JavaScript**: the usual Jest/Vitest watch keys, single keypress, no Enter needed —
  `Enter` forces a rerun, `a` runs the whole suite (the same thing until test filtering
  exists), and `q` or Ctrl+C quits. If the keys can't be installed (stdin isn't a console),
  Ctrl+C still quits.

On Deno, watch mode also needs `allow_run = ["gleam"]` to spawn the inner runs (see
"Target differences" below).

## Outcomes

| Outcome | Meaning | Exit code contribution |
| --- | --- | --- |
| pass | ran without panic | 0 |
| fail | assert/panic/crash/timeout, or a process the test started crashed | 1 |
| todo | hit `todo` in code under test (directly or in a process it started) | 1 — unimplemented is still not done |
| skip | `todo` within test function | 0 |

## Crash reports

On the Erlang target, a process that dies *with* a test (a linked process crashing, an actor
the test is calling hitting a `todo`) is reported through the test's own outcome. A process
that dies *behind* a test — an unlinked worker, a fire-and-forget job nothing is monitoring —
would leave the test passing (this is what gleeunit does), with the BEAM's crash report as the
only trace. vouch traces each test's process tree, so a process it started that crashes is
caught and charged to that test, and the test fails:

```
  playground_test.background_job_test
    Background process crashed at src/playground.gleam:26
      background job crashed: queue is full
```

If the process died of a `todo`, the test is a todo instead. A crash from a process that
outlived its test, or that no test started, is reported at the end and fails the run. The
BEAM's own crash reports are kept off the output streams (they used to interleave with it on
stderr); pass `--show-crash-reports` to print them in full as one block after the summary.
Other logger output (a library's warnings) is not a crash and still goes to stderr.

## Target differences

Erlang target supports `--parallel`, `--timeout=n` and `--show-crash-reports`

Deno needs permissions in your project's `gleam.toml`.
You need `allow_read` for discovery and source quoting.
you need `allow_write` if you use `--junit` for XML report output
You need `allow_env` for detecting `NO_COLOR` environemnt variable
You need `allow_run` if you use watch mode, which spawns `gleam test` for each cycle

```toml
[javascript.deno]
allow_read = ["gleam.toml", "src", "test", "build"]
allow_write = ["."]
allow_env = ["NO_COLOR"]
allow_run = ["gleam"]
```
