= Roadmap <sec-roadmap>

== v1 scope

The organising principle: *gleeunit, but solid* — same authoring contract,
better internals, at most two visible differentiators (rich failure output,
machine-readable formats). Nothing that requires inventing new conventions.

Tier 1 — definitional:

+ Discovery by convention, both targets
+ Execution catching every failure shape; panic payload decoding
+ Console reporter with rich `assert` diffs; todo/skip classification and
  todo-site grouping
+ Correct exit codes, including zero-tests-found = loud failure
+ Per-test timing

Tier 2 — cheap because the architecture pays for them:

+ Name filtering: `gleam test -- <pattern>`
+ JSONL event stream + JUnit XML reporters (schemas marked unstable)
+ Process-per-test isolation on the BEAM
+ Per-test timeouts (BEAM; best-effort on JavaScript)

== Build order

+ *Walking skeleton first*: FFI contract on both targets — discover one
  module, invoke one trivial test, catch one panic, end-to-end on Erlang and
  JavaScript. This empirically answers the payload questions in
  @sec-open-questions before any design is locked.
+ Panic decoding (all shapes in the table in @sec-test-model).
+ The event model and outcome types.
+ Reporters on top of events: console, then JSONL, then JUnit.
+ Isolation and timeouts on the BEAM.
+ Filtering last — trivial once discovery returns data.

== Deferred, deliberately

- *Watch mode* — see the sketch below. Interim answer for users:
  `watchexec -e gleam gleam test`.
- *Tags, focus, fixtures, setup/teardown, parametrized tests* — all need a
  channel beyond the zero-arity convention (return type, registration API, or
  DSL). This is the central v2 design question; candidate directions include
  tests returning a result/description type, or a registration path coexisting
  with plain convention tests so suites migrate incrementally. Decide once,
  with v1 usage data.
- *Parallel execution* — process-per-test makes it nearly free on the BEAM;
  deterministic sequential output ships first, parallelism becomes a flag once
  reporting handles interleaving.
- *Published outcome SPI* for qcheck/birdie integration — the internal outcome
  type is designed as if it will be published, but publishing is a stability
  commitment (SPIs break every implementer when they change) made only after
  the design has survived real use.
- *Per-test stdout capture* — group-leader tricks on the BEAM make it
  plausible; JavaScript is harder; neither is v1.
- *Snapshot testing, TAP output* — v2+ if demanded.
- *EUnit `.erl` compat* — never; see @sec-compatibility.

== Watch mode sketch (v2)

`gleam test --watch` literally cannot exist without upstream toolchain
changes — flags before `--` belong to the build tool. More fundamentally,
`gleam test` is compile-then-execute: by the time runner code executes,
compilation already happened, and neither the compiler nor BEAM hot-reload is
callable from inside the running test process. A watcher therefore must live
outside the compile step and re-invoke the toolchain:

```text
watcher process (long-lived)
  └─ on change → spawn `gleam test` subprocess → parse its JSONL → report → wait
```

Two spellings for the same loop, not mutually exclusive:

+ `gleam run -m vouch watch` — the lustre_dev_tools pattern; the watcher is
  honestly a separate program. Preferred. (If the toolchain's `gleam dev` entry
  point is a better home, decide when building it.)
+ `gleam test -- --watch` — vouch's main detects the flag and becomes the
  supervisor, spawning inner `gleam test` runs with the flag stripped.

Implementation notes recorded from planning: poll mtimes rather than fight
native file-watching APIs (OTP has no built-in watcher; `fs.watch` quirks on
JavaScript are why chokidar exists) — polling every few hundred milliseconds is
fine for this. Each cycle pays full `gleam test` startup (compile check + VM
boot); Gleam's incremental compilation keeps it tolerable, but Vitest-style
instant re-runs are not achievable from outside the toolchain. The watcher
consumes vouch's own JSONL output from the inner run — the first in-house
consumer of the format.
