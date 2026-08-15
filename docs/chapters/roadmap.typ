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

== Watch mode (shipped post-v1)

Shipped as `gleam run -m vouch -- watch [options]` — the lustre_dev_tools
pattern: the watcher is honestly a separate program, hosted on the BEAM.
Dispatch is on the first positional argument, so `gleam test -- watch`
reaches the same loop; a `--target=javascript` argument is hoisted to the
build tool's side of the inner invocation, so JavaScript suites are
watched from the Erlang-hosted supervisor (on the JavaScript target,
`watch` says it is unsupported and points at that spelling).

`gleam test --watch` literally cannot exist without upstream toolchain
changes — flags before `--` belong to the build tool. More fundamentally,
`gleam test` is compile-then-execute: by the time runner code executes,
compilation already happened, and neither the compiler nor BEAM hot-reload
is callable from inside the running test process. The watcher therefore
lives outside the compile step and re-invokes the toolchain:

```text
watcher process (long-lived)
  └─ on change → spawn `gleam test` subprocess → stream its output → wait
```

Decisions recorded from the build:

- Polling, not native file watching (OTP has no built-in watcher;
  `fs.watch` quirks on JavaScript are why chokidar exists). Every 250ms
  the watched roots — `gleam.toml`, `src/`, `test/` — are snapshotted as
  sorted (path, mtime, size) rows; size participates so a same-second
  rewrite still registers despite mtime's one-second granularity. The
  snapshot is taken *before* each run, so edits made while tests execute
  trigger the next cycle.
- One deviation from the planning sketch, which had the watcher parsing
  the inner run's JSONL: the watcher instead streams the inner run's own
  console output through untouched, pinning `--color=always` when the
  watcher's terminal renders colour (the inner process only sees a pipe,
  so its auto-detection would strip it). Re-rendering from JSONL would
  duplicate the console reporter for no benefit today; it becomes worth
  it when the watcher needs semantic knowledge of results — rerun-only-
  failures, notifications — none of which exists yet.
- Passthrough flags are validated once at startup with the same parser
  the inner run uses, so a typo fails loudly before the loop starts
  instead of on every cycle.
- Quitting needs two paths, because a foreground BEAM turns Ctrl+C into
  the emulator's BREAK menu rather than an exit. On Unix-like systems
  SIGINT is taken over via `os:set_signal` and halts with 130; that API
  is unsupported on Windows, so a stdin listener quits on `q` + Enter
  everywhere (the inner runs never contend for stdin — their ports get
  pipes). An eof on stdin means the watcher is not interactive, and the
  listener retires rather than treating it as a quit.
- Each cycle pays full `gleam test` startup (compile check + VM boot);
  Gleam's incremental compilation keeps it tolerable, but Vitest-style
  instant re-runs are not achievable from outside the toolchain. A
  compile error is just a red cycle: the inner run exits non-zero with
  the compiler's diagnostics on stderr, and the watcher keeps waiting.
