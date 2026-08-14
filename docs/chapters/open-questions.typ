= Open questions <sec-open-questions>

Most of the original assumptions were verified empirically on 2026-08-14
against gleam 1.18.1 / node 22 during the walking-skeleton build. Findings
first; the genuinely still-open items are at the end.

== Verified: panic payloads

Both targets confirmed by catching real panics from the probe suite in
`test/vouch_test.gleam` (one test per failure shape).

*Erlang:* the error reason is a map with atom keys. All shapes carry
`gleam_error` (`assert` / `let_assert` / `panic` / `todo`), `message`, `file`,
`module`, `function`, `line`. `assert` adds `kind`
(`binary_operator` with `operator`/`left`/`right`, `function_call` with
`arguments`, or `expression`), each operand a map with `start`/`end`/`kind`
(`literal` / `expression` / `unevaluated`) and `value`. `let_assert` adds the
unmatched `value` and pattern spans.

*JavaScript:* the thrown value is an `Error` instance with the same data as
own properties (`gleam_error` as a string, and the same site and kind fields).

*Consequence confirmed:* the `todo` payload carries its site on _both_
targets, so the Todo/Skipped split of @sec-test-model works everywhere. The
probe run showed a deep todo reporting `module: "helpers"`,
`function: "unimplemented"` while the running test was
`vouch_test.todo_deep_test` — exactly the signal the rule needs.

*Bonus finding:* gleeunit 1.11.0 ships an internal typed decoder for these
payloads (`gleeunit/internal/gleam_panic`, with per-target FFI). It is
internal API and vouch must not depend on it, but it is a correct, current
reference for the decode module — and evidence the shapes are stable enough
for gleeunit to type them.

== Verified: toolchain behaviour

- *`gleam test -- <args>` forwards arguments*: confirmed;
  `argv.load().arguments` sees everything after `--`.
- *`gleam new` (1.18.1) still scaffolds gleeunit* — and the template test now
  uses the `assert` keyword, not `gleeunit/should`. The migration pitch holds;
  new projects are already assert-idiomatic.
- *Discovery mechanics*: source-file globbing works and is what gleeunit does
  (`filelib:wildcard/2` over `test/` on Erlang; a recursive directory walk on
  JavaScript, importing `../<package>/<module>.mjs` relative to the FFI
  module). vouch's skeleton does the same.
- *Async tests*: gleeunit `await`s every test function on JavaScript, so
  suites may rely on it. Decision adopted: vouch awaits too (the skeleton
  already does).
- *gleeunit 1.11.0 architecture*: Erlang still delegates to EUnit
  (with `ScaleTimeouts(10)` and a custom progress listener); JavaScript is a
  bespoke async loop entirely in FFI; no configuration surface. As assumed.

== Still open

+ *Exit-reason normalisation under process isolation.* When a test runs in a
  spawned BEAM process, the panic arrives as a monitor `DOWN` reason rather
  than a caught exception. Verify the payload map survives intact through
  that path before building isolation (@sec-execution).

+ *Payload stability across Gleam versions.* Shapes are verified for gleam
  1.18.1. Decide the minimum supported compiler version and whether the
  decoder should tolerate missing fields (it should — degrade per the rules
  in @sec-test-model).

+ *Whether `gleam dev` exists / where watch mode lives* — deferred with watch
  mode itself (v2).

+ *showtime / startest current state* — worth a look at startest's filtering
  UX before designing vouch's flags.

+ *Default per-test timeout value* on the BEAM (and its flag name).

+ *JSONL field-level schema* — settles during implementation; unstable in v1
  by policy.

+ *JavaScript sequencing in Gleam.* The skeleton drives the async test loop
  from FFI and calls back into Gleam. Evaluate pulling sequencing into Gleam
  with promise bindings (likely via `gleam_javascript`) against the
  near-zero-dependency budget (@sec-goals).
