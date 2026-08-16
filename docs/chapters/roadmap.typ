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
  running alongside the console via the reporter pair combinator);
  TeamCity service messages (`--format=teamcity`) followed post-v1
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

== Parallel execution (shipped post-v1)

`--parallel[=n]` on the Erlang target, opt-in (bare `--parallel` sizes the
pool to the scheduler count). Process-per-test isolation made execution
nearly free, as planned; the design work was reporting, resolved by not
interleaving it at all: a sliding window admits up to _n_ tests, each
started by a middleman process that runs the same `run_test` as the
sequential path (identical isolation and timeout semantics, duration
measured at the test), and the runner awaits the *oldest* in-flight test
before admitting more. Results therefore arrive at the reporters in
discovery order — the console, JSONL, and JUnit folds are untouched —
while execution overlaps behind the window. A slow head test lets the
rest of the window drain without refilling: a little throughput traded
for a deterministic event stream.

Decisions recorded from the build:

- Sequential stays the default. Convention-discovered tests promise
  nothing about sharing registered names, ets tables, files, or ports;
  making concurrency opt-in keeps existing suites correct by default.
- `TestStart` events are emitted at admission (when the test actually
  starts), so a JSONL consumer sees starts and results interleave; every
  event carries its test identity, so the stream stays self-describing.
- On JavaScript `--parallel` warns and does nothing — single-threaded,
  same honesty rule as `--timeout`.
- The e2e suite runs the playground under `--parallel` and asserts the
  outcome counts match the sequential runs; vouch's own suite proves
  overlap directly with two 300ms fixtures awaited together under a
  sequential-impossible deadline, and proves the timeout survives the
  parallel path.

== Watch mode (shipped post-v1)

Shipped as `gleam run -m vouch -- watch [options]` — the lustre_dev_tools
pattern: the watcher is honestly a separate program, hosted initially on
the BEAM and since ported to the JavaScript target too. Dispatch is on
the first positional argument, so `gleam test -- watch` reaches the same
loop. The inner runs follow the watcher's own target by default (saying
"javascript" twice to watch JavaScript tests proved an immediate
footgun: the outer flag alone left the inner runs on the project
default, surprising the first real user); an explicit `--target=x`
after the `--` is hoisted to the build tool's side of the inner
invocation, so either host can still watch either target's suites.

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
  sorted (path, mtime, size) rows; size participates so a rewrite within
  the mtime's granularity (one second on Erlang, one millisecond on
  JavaScript) still registers. The mtime is a target-local integer —
  snapshots are only ever compared for equality, so the units never need
  to agree across targets. The snapshot is taken *before* each run, so
  edits made while tests execute trigger the next cycle.
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
- Quitting on the Erlang host is a stdin listener on `q` + Enter, because
  that is the only clean quit the BEAM allows a long-running foreground
  program. Ctrl+C
  belongs to the emulator: SIGINT cannot be taken over at runtime
  (`os:set_signal(sigint, handle)` is badarg — verified, as was the
  tempting-but-wrong fix that catches the badarg and claims Ctrl+C
  works), and the `+Bd`/`+Bi` boot flags merely turn Ctrl+C into a
  no-op, which is worse than the BREAK menu. The inner runs never
  contend for stdin — their ports get pipes. An eof on stdin means the
  watcher is not interactive, and the listener retires rather than
  treating it as a quit.
- Each cycle pays full `gleam test` startup (compile check + VM boot);
  Gleam's incremental compilation keeps it tolerable, but Vitest-style
  instant re-runs are not achievable from outside the toolchain. A
  compile error is just a red cycle: the inner run exits non-zero with
  the compiler's diagnostics on stderr, and the watcher keeps waiting.

The JavaScript port (August 2026) is sync mimicry: the Gleam loop is
shared unchanged, and the four primitives block deliberately —
`spawnSync` with inherited output for the inner run, `Atomics.wait` on a
`SharedArrayBuffer` for the poll sleep, `readdirSync`/`statSync` for the
snapshot — all through `node:` compat APIs so Node and Deno share one
code path (Deno additionally needs `allow_run = ["gleam"]`). Quitting
there is Ctrl+C: the blocked event loop means a stdin listener could
never fire, and unlike the BEAM the runtime's default SIGINT disposition
terminates it even mid-block, so the mechanism the Erlang host fights is
exactly the one the JavaScript host gets for free.

The JavaScript host also carries the core Jest/Vitest watch keys (Enter
to force a rerun, `a` to run all — distinct commands even while they
coincide, so filtering can later hang off the difference — `q` to quit).
The blocked main thread still can't hear stdin, so a worker thread owns
the tty — a `tty.ReadStream` over fd 0 driven by the worker's own live
event loop — and posts one command byte into the same shared buffer the
poll sleep waits on; `Atomics.notify` wakes the watcher instantly. Raw
mode must belong to the worker's stream: flipping it from the main
thread's stream governs only that stream's reads on Windows, not the
worker's view of the console (found the hard way — q took two Enters).
Raw mode (single keypress, no Enter) is only engaged between runs —
during a run the console reverts, keeping native Ctrl+C's
kill-the-run-too behaviour; between runs the worker sees the raw 0x03
byte, hands the terminal back, and treats it as quit. Anything that blocks installation (stdin not
a console, worker gaps in a runtime) degrades back to Ctrl+C-only, and
the status line reports whichever mode actually engaged.

== TeamCity service messages (shipped post-v1)

`--format=teamcity`, detailed in @sec-output. The event stream was already
the whole job: the reporter is a pure map from events to lines, with the
open suite as its only state.

Decisions recorded from the build:

- Both halves of a test's `testStarted`/`testFinished` pair are emitted at
  `TestResult`. `TestStart` is emitted at admission under `--parallel`, so
  pairs opened there would interleave — which TeamCity forbids on a single
  flow. Emitting the pair closed sidesteps flow ids entirely, and costs
  nothing because `TestResult` already carries the duration.
- Todo is `testFailed`, matching JUnit and the exit code. TeamCity's
  `testIgnored` does not fail a build, so mapping Todo there would render
  green while vouch exits 1.
- `comparisonFailure` only for `==`. TeamCity's diff view over the operands
  of `<` or `!=` would assert a relationship the operator does not have.
- Zero tests emits `buildProblem`, so the loud-failure rule is legible in
  the UI and not just in the exit code.
