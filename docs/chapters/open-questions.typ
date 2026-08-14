= Open questions <sec-open-questions>

The planning-phase assumptions and how each turned out. Kept as a record of
what was verified (and how), plus the genuinely still-open items at the end.

== Resolved during the walking skeleton (gleam 1.18.1, node 22)

- *Panic payload shapes, both targets.* As assumed: an Erlang map with atom
  keys, a JavaScript `Error` with the same data as properties. All shapes
  carry `gleam_error`, `message`, `file`, `module`, `function`, `line`;
  `assert` adds structured operand data. The `todo` site is present on
  *both* targets, so the Todo/Skipped split works everywhere.
- *`gleam test -- <args>` forwards arguments* — confirmed; all vouch flags
  ride on it.
- *`gleam new` still scaffolds gleeunit* — and its template test now uses
  the `assert` keyword, so new projects are assert-idiomatic.
- *gleeunit 1.11.0 architecture* — as assumed (EUnit delegation on Erlang,
  bespoke async loop in FFI on JavaScript, no configuration surface). Bonus
  finding: it ships an internal typed payload decoder
  (`gleeunit/internal/gleam_panic`), which served as a reference for
  vouch's — evidence the payload shapes are stable enough to type.
- *Async tests on JavaScript* — gleeunit awaits them, so suites may rely on
  it; vouch awaits too.

== Resolved during implementation

- *Exit-reason fidelity under process isolation* — the question dissolved:
  the test process catches its own panic and message-passes the payload
  back, so nothing depends on `DOWN`-reason fidelity for ordinary failures
  (@sec-execution). For genuine process deaths, the decoder's recursive
  search through nested exit-reason tuples recovers wrapped payloads —
  including todos raised inside OTP callbacks, verified against a real
  gen_server fixture.
- *Compiler floor* — `gleam >= 1.14`, verified empirically with podman
  containers on both targets. The `assert` keyword alone needs 1.11, but
  `gleam_stdlib` 1.x requires 1.14 (making anything lower unsatisfiable in
  practice), and the `Type$Constructor` prelude naming vouch's JavaScript
  FFI imports is confirmed working at 1.14.
- *Default per-test timeout* — 5000ms, `--timeout=ms` to change it;
  requesting a non-default timeout on JavaScript prints a stderr note.
- *JSONL schema* — field names settled (see @sec-output) but explicitly
  unstable until v2.
- *Stream hygiene* — BEAM crash reports from test-spawned processes went to
  stdout and could corrupt JSONL; the default logger handler is re-added
  pointing at stderr at run start. (`logger:update_handler_config` cannot
  change the handler type at runtime; the reports are asynchronous and often
  lost to `erlang:halt` — which made the bug appear nondeterministic.)

== Still open

+ *Payload stability across future Gleam versions.* Shapes are verified for
  1.14–1.18. The suite's permanently-skipped todo-bodied test doubles as a
  canary: if a compiler change breaks site decoding, the degradation rule
  flips it to Todo and the suite goes red on upgrade.
+ *Whether the toolchain grows a `gleam dev` entry point* — watch mode
  shipped under `gleam run -m vouch -- watch`; revisit the spelling only
  if upstream offers a better home.
+ *showtime / startest current state* — worth a look at startest's
  filtering UX before extending vouch's flags.
+ *JavaScript sequencing in Gleam* — evaluate promise bindings (likely
  `gleam_javascript`) against the near-zero-dependency budget (@sec-goals).
+ *Publish version* — 0.1.0 signals early-stage but gives users no semver
  protection; Gleam culture (and the `gleam publish` warning) favours
  1.0.0 with honest major bumps. Undecided; publishing is on hold.
