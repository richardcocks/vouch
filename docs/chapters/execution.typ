= Execution <sec-execution>

== Ordering

Tests run sequentially in deterministic order (module, then function) on
both targets. Parallelism is a later flag once reporting handles
interleaving (see @sec-roadmap).

== Erlang target: process-per-test isolation

Each test runs in its own spawned BEAM process. The implemented design is
stronger than the one originally planned: rather than decoding monitor
`DOWN` reasons, *the test process catches its own panic and sends the intact
payload back as a message*. Decoding therefore never depends on exit-reason
fidelity for ordinary failures. The runner waits on three possibilities:

- *The result message* — pass, or a caught panic with its raw payload.
- *Monitor `DOWN`* — the process died without reporting: an exit signal,
  e.g. a linked process crashing. The exit reason is handed to the same
  decoder, whose recursive search (@sec-test-model) means a linked Gleam
  panic still renders as a full panic rather than an opaque term.
- *Timeout* — the test outlived `--timeout=ms` (default 5000). It is
  killed and reported as a timeout failure. A hung test costs its timeout,
  not the whole run.

BEAM crash reports (a process the test started dying: the emulator's "Error
in process", proc_lib crash reports, gen_\* terminate and supervisor child
reports) are diverted at run start from the default logger handler into an
ETS table, by a capture handler whose filter admits only crash-shaped events.
Each test process runs under its own group leader — a proxy forwarding io to
the real one — which every process it starts inherits and every crash report
records, so after each test the runner claims the reports charged to it and
folds them into the outcome: a passing test whose worker crashed fails
(`BackgroundCrashDetail`), or is a todo if the worker died of a `todo`.
Reports nobody claimed (arrived after their test finished, or from outside
any test) are printed at the end and fail the run. The default handler is
re-added with `type: standard_error` for everything else routed through
logger, so it stays visible but can never corrupt piped stdout.
(`logger:update_handler_config` silently ignores a runtime type change;
remove-and-re-add is required.)

Known limitation, accepted for v1: a test that spawns unlinked long-lived
processes, registers global names, or mutates shared ETS tables can still
leak state between tests. Process-per-test is the 90% solution; full
sandboxing is out of scope.

== JavaScript target: sequential in-process

JavaScript has no cheap process primitive, so tests run sequentially in one
runtime with try/catch capture:

- A test that throws is contained (caught and reported).
- Async test functions (returning a promise) are awaited — gleeunit does
  the same, so convention-following suites may rely on it.
- A test that never resolves or hard-loops cannot be interrupted:
  `--timeout` has no effect, and vouch prints a stderr note when a
  non-default timeout is requested on this target rather than being
  silently ineffective.
- Worker-thread isolation is a possible future improvement, not v1.

The async sequencing lives in the FFI, which threads reporter state through
Gleam callbacks — decisions (filtering, classification, reporting, exit
codes) stay in shared Gleam code. Pulling the sequencing itself into Gleam
via promise bindings remains future work (@sec-open-questions).

== Timing

Per-test wall-clock duration via the monotonic clock FFI, collected always,
attached to every `TestResult` event.

== Halting

The exit code is computed in pure Gleam from the outcome tally
(see @sec-output) and applied via the FFI halt operation. `main()` returning
normally must not be relied on for success/failure — the toolchain does not
derive the exit code from the return value.
