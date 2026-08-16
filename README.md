# vouch

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
| fail | assert/panic/crash/timeout | 1 |
| todo | hit `todo` in code under test | 1 — unimplemented is still not done |
| skip | `todo` within test function | 0 |

## Target differences

Erlang target supports `--parallel` and `--timeout=n`

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
