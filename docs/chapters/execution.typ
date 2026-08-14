= Execution <sec-execution>

== Ordering

v1 runs tests sequentially in a deterministic order (module, then function).
Deterministic output first; parallelism is a later flag once reporting handles
interleaving (see @sec-roadmap).

== Erlang target: process-per-test isolation

Each test runs in its own spawned BEAM process, monitored by the runner:

- *Crashes are contained.* A test that exits, throws, or takes down linked
  processes kills only its own process tree. The runner observes the exit
  reason and reports a Fail; the run continues.
- *Timeouts are possible.* The runner waits on the monitor with a per-test
  timeout (default value to be chosen; configurable). A hung test becomes a
  failed test with a timeout message instead of hanging `gleam test` forever.
- *The exit reason is the payload.* A panic in the spawned process arrives as
  the monitor's `DOWN` reason; normalisation of that term is part of the FFI
  `invoke` contract, same as a caught exception.

This addresses a real gleeunit weakness and is the natural way to write the
executor on the BEAM anyway — it is not extra machinery.

Known limitation, accepted for v1: a test that spawns _unlinked_ long-lived
processes, registers global names, or mutates ETS tables it doesn't own can
still leak state between tests. Full sandboxing is out of scope;
process-per-test is the 90% solution.

== JavaScript target: sequential in-process

JavaScript has no cheap process primitive, so tests run sequentially in one
runtime with `try`/`catch` capture. Stated honestly as a target difference:

- A test that throws is contained (caught and reported).
- A test that never resolves, hard-loops, or calls `process.exit` itself can
  still wedge or kill the run. Best-effort timeout only, and only for async
  shapes that can be raced against a timer.
- Worker-thread isolation is a possible future improvement, not v1.

The runner must not pretend the targets are equivalent; the docs and output
say which guarantees apply where.

== Async tests

Open design point, JavaScript-first: a zero-arity test function that returns a
`Promise` (e.g. Gleam code using JavaScript FFI) should be awaited, not
reported as passing at call-return. Erlang has no equivalent shape — a test
blocks until done. The walking skeleton should establish what gleeunit does
here and what convention-following suites actually contain. Listed in
@sec-open-questions.

== Timing

Per-test wall-clock duration via the monotonic clock FFI, collected always,
attached to every outcome. Near-free now, painful to retrofit, needed by every
reporter and by any future flaky-test or slowest-tests feature.

== Halting

The exit code is computed in pure Gleam from the outcome tally
(see @sec-output) and applied via the FFI halt operation. `main()` returning
normally must not be relied on for success/failure — the toolchain does not
derive the exit code from the return value.
