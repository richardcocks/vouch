= Architecture <sec-architecture>

== Distribution model

The only entry point `gleam test` offers is `main()` in the user's test module.
A runner must therefore be ordinary Gleam code callable from that function,
which means: a Hex package, added as a dev dependency.

```sh
gleam add --dev vouch
```

```gleam
// test/my_project_test.gleam
import vouch

pub fn main() {
  vouch.main()
}
```

That one-line swap from `gleeunit.main()` is the entire migration for
convention-following projects.

"Written in Gleam" does not mean pure Gleam: Hex packages ship whatever is in
`src/`, including `.erl` and `.mjs` files bound via `@external`. The design
question is not whether to have FFI but where the boundary sits.

== The boundary rule

#quote(block: true)[
  Target-specific code may do only what genuinely requires the target.
  It returns plain data. All decisions live in Gleam.
]

The FFI contract, in full:

#table(
  columns: (1.2fr, 1fr, 1fr),
  table.header([Operation], [Erlang], [JavaScript]),
  [Enumerate candidate test files],
  [`filelib:wildcard/2` over `test/`],
  [recursive directory walk of `test/`],
  [Enumerate a module's exported zero-arity functions],
  [`Module:module_info(exports)`],
  [dynamic import, inspect exports],
  [Run one test],
  [spawned monitored process with timeout (@sec-execution)],
  [async loop awaiting each test, threading reporter state through Gleam
    callbacks],
  [Catch a panic from a directly-held function],
  [`try`/`catch`],
  [`try`/`catch`],
  [Decode a panic payload],
  [match the error map, searching nested exit-reason tuples],
  [read the thrown Error's properties],
  [Monotonic clock],
  [`erlang:monotonic_time/1`],
  [`performance.now()`],
  [Write a file (JUnit reports)],
  [`file:write_file/2`],
  [`writeFileSync`],
  [Terminal facts (TTY, env vars)],
  [`io:columns/0`, `os:getenv/1`],
  [`isTTY` / `Deno.stdout.isTerminal`, env lookup],
  [Catch a crash behind a test / keep BEAM reports off the streams],
  [`erlang:trace` a per-test process tree; capture logger handler],
  [not needed (no processes)],
  [Halt with exit code],
  [`erlang:halt/1`],
  [`process.exit` / `Deno.exit`],
  [Read CLI arguments],
  [via the `argv` package],
  [via the `argv` package],
)

Everything else — name filtering, scheduling, the outcome model, panic payload
decoding, event emission, and every reporter — is pure Gleam, written once,
identical on both targets.

Two consequences worth stating explicitly:

- *Adding a reporter is a new Gleam module.* TAP, or a future format, costs one
  file and zero FFI. In gleeunit the equivalent change is two implementations,
  one of them inside an EUnit listener. (Concretely: the long-open gleeunit PR
  adding a todo category has to patch `gleeunit_progress.erl` and would need a
  second, separate implementation for the JavaScript target.)
- *Panic normalisation is the hardest FFI code and the only hard FFI code.*
  The two `run` implementations must produce the same shape for the same
  logical failure. This is where the walking skeleton earns its keep — see
  @sec-open-questions.

The JavaScript side must tolerate runtime differences (node/deno/bun) in
filesystem and process APIs; that variance stays inside `vouch_ffi.mjs`.

== Package layout

```text
vouch/
  gleam.toml                       # deps: stdlib + argv, nothing else
  src/
    vouch.gleam                    # public API: main()
    vouch/internal/config.gleam    # flags parsed from argv
    vouch/internal/gleam_panic.gleam  # typed panic payloads + decode external
    vouch/internal/outcome.gleam   # Invocation, TestOutcome, classification
    vouch/internal/event.gleam     # RunStart / TestStart / TestResult / RunEnd
    vouch/internal/reporter.gleam  # Reporter(state) fold + pair combinator
    vouch/internal/runner.gleam    # per-target loops, tally, exit codes
    vouch/internal/term.gleam      # colour decision (TTY, NO_COLOR)
    vouch/internal/json.gleam      # minimal JSON encoding (no dependency)
    vouch/internal/report/console.gleam
    vouch/internal/report/jsonl.gleam
    vouch/internal/report/junit.gleam
    vouch_ffi.erl                  # the FFI contract, Erlang
    vouch_ffi.mjs                  # the FFI contract, JavaScript
  test/
    vouch_test.gleam               # unit suite (vouch runs itself)
    vouch_e2e_test.gleam           # spawns gleam test in the playground
    helpers.gleam, *.erl           # fixtures, never discovered
  examples/playground/             # scratch consumer; e2e fixture project
  docs/                            # this document
```

Modules under `vouch/internal/` are hidden from generated documentation by
Gleam's path convention; nothing under it is public API. (Naming lesson
recorded for posterity: `panic`, `todo`, and `test` are reserved words and
cannot be module names, field labels, or parameter names — hence
`gleam_panic`.)

== Data flow

```text
argv ──► Config
                 FFI: enumerate           pure Gleam                FFI: invoke
candidates ────────────────► discover/filter ──► ordered test list ──► run each
                                                                        │
                                              (per test: raw panic data or ok)
                                                                        ▼
                                                            decode ──► TestOutcome
                                                                        │
                                                                        ▼
                                                              Event stream (spine)
                                                        ┌───────────┼───────────┐
                                                        ▼           ▼           ▼
                                                    console       jsonl       junit
                                                        │
                                                        ▼
                                                  exit code ──► FFI: halt
```

The event stream is the spine: every reporter, including the console, is a fold
over the same events. JUnit XML is not a special path — it is a fold that
buffers until `RunEnd`. See @sec-output.

== CLI growth path

`gleam run -m vouch` can execute a module's main from a dependency (the pattern
lustre_dev_tools uses). Watch mode lives there — `gleam run -m vouch -- watch`
— and any future scaffolding commands follow, without changing the
distribution model. The core stays a library. See @sec-roadmap for the
as-built watch loop and why it must re-exec `gleam test` rather than re-run
in-process.
