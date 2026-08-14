= Roadmap <sec-roadmap>

== v1: shipped

The organising principle held: *gleeunit, but solid* — same authoring
contract, better internals. Everything below is implemented, tested on both
targets, and exercised end-to-end:

- Discovery by convention; execution catching every failure shape; panic
  payload decoding including OTP-wrapped payloads
- Console reporter with assert left/right/operator detail, todo-site
  grouping with messages, colour (`--color`, `NO_COLOR`), per-test timing
- Outcome model with the Todo/Skipped site split; correct exit codes,
  including the loud zero-tests and nothing-matched-the-filter cases
- `--filter=text` (bare positional arguments are rejected with a hint)
- JSONL event stream (`--format=json`) and JUnit XML (`--junit=path`,
  running alongside the console via the reporter pair combinator)
- Process-per-test isolation and `--timeout=ms` on the BEAM; BEAM
  diagnostics routed to stderr so stdout stays machine-clean
- `examples/playground` — a path-dependency consumer with one test per
  outcome flavour — plus e2e tests that run it as a subprocess and assert
  on the JSONL stream and exit codes
- Compiler floor `gleam >= 1.14`, verified in containers on both targets

Beyond the original plan, v1 also grew: the discovered-vs-total distinction
in `RunStart`, the JavaScript `--timeout` warning, recursive OTP
exit-reason decoding, and the stderr diagnostics redirect — each prompted
by real use during development.

== Deferred, deliberately

- *Watch mode* — see the sketch below. Interim answer for users:
  `watchexec -e gleam gleam test`.
- *Tags, focus, fixtures, setup/teardown, parametrized tests* — all need a
  channel beyond the zero-arity convention (return type, registration API,
  or DSL). This is the central v2 design question; candidate directions
  include tests returning a result/description type, or a registration path
  coexisting with plain convention tests so suites migrate incrementally.
  Decide once, with v1 usage data.
- *Parallel execution* — process-per-test makes it nearly free on the BEAM;
  deterministic sequential output shipped first, parallelism becomes a flag
  once reporting handles interleaving.
- *Published outcome SPI* for qcheck/birdie integration — the internal
  outcome type is designed as if it will be published, but publishing is a
  stability commitment (SPIs break every implementer when they change) made
  only after the design has survived real use.
- *Per-test stdout capture* — group-leader tricks on the BEAM make it
  plausible; JavaScript is harder; neither is v1.
- *JavaScript sequencing in Gleam* — the async run loop lives in FFI,
  calling back into Gleam; promise bindings could pull it into Gleam at the
  cost of a dependency.
- *Snapshot testing, TAP output* — v2+ if demanded.
- *EUnit `.erl` compat* — never; see @sec-compatibility.

== Watch mode sketch (v2)

`gleam test --watch` literally cannot exist without upstream toolchain
changes — flags before `--` belong to the build tool. More fundamentally,
`gleam test` is compile-then-execute: by the time runner code executes,
compilation already happened, and neither the compiler nor BEAM hot-reload
is callable from inside the running test process. A watcher therefore must
live outside the compile step and re-invoke the toolchain:

```text
watcher process (long-lived)
  └─ on change → spawn `gleam test` subprocess → parse its JSONL → report → wait
```

Two spellings for the same loop, not mutually exclusive:

+ `gleam run -m vouch watch` — the lustre_dev_tools pattern; the watcher is
  honestly a separate program. Preferred. (If the toolchain's `gleam dev`
  entry point is a better home, decide when building it.)
+ `gleam test -- --watch` — vouch's main detects the flag and becomes the
  supervisor, spawning inner `gleam test` runs with the flag stripped.

Implementation notes recorded from planning: poll mtimes rather than fight
native file-watching APIs (OTP has no built-in watcher; `fs.watch` quirks on
JavaScript are why chokidar exists) — polling every few hundred milliseconds
is fine for this. Each cycle pays full `gleam test` startup (compile check +
VM boot); Gleam's incremental compilation keeps it tolerable, but
Vitest-style instant re-runs are not achievable from outside the toolchain.
The watcher consumes vouch's own JSONL output from the inner run — the e2e
tests already parse that stream the same way.
