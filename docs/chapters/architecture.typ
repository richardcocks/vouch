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
  [Enumerate candidate test modules],
  [scan compiled modules in the build directory],
  [glob compiled `.mjs` under `build/dev/javascript/`],
  [Enumerate a module's exported zero-arity functions],
  [`Module:module_info(exports)`],
  [dynamic import, inspect exports],
  [Invoke a function, capturing any panic as data],
  [`try`/`catch`, normalise the error term],
  [`try`/`catch`, normalise the thrown value],
  [Monotonic clock],
  [`erlang:monotonic_time/1`],
  [`performance.now()`],
  [Halt with exit code],
  [`erlang:halt/1`],
  [`process.exit` / target equivalent],
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
  gleam.toml              # deps: stdlib + argv, ideally nothing else
  src/
    vouch.gleam            # public API: main(), run(Config)
    vouch/config.gleam     # flags parsed from argv (filter, format)
    vouch/discover.gleam   # pure: filter candidate modules/functions by convention
    vouch/outcome.gleam    # TestOutcome and failure detail types
    vouch/event.gleam      # RunStart / TestStart / TestResult / RunEnd
    vouch/decode.gleam     # panic payload -> structured failure detail
    vouch/report/console.gleam
    vouch/report/jsonl.gleam
    vouch/report/junit.gleam
    vouch_ffi.erl          # the FFI contract, Erlang
    vouch_ffi.mjs          # the FFI contract, JavaScript
  test/
    vouch_test.gleam       # vouch tests itself
  docs/                   # this document
```

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
lustre_dev_tools uses). Watch mode and any future scaffolding commands live
there, without changing the distribution model. The core stays a library.
See @sec-roadmap for the watch mode sketch and why it must re-exec
`gleam test` rather than re-run in-process.
