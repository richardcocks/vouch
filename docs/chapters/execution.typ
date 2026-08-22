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

A process that dies *behind* a test — an unlinked worker, a fire-and-forget
job nothing is linked to or monitoring — would leave the test passing, its
death known only to the BEAM's crash report. vouch traces each test's
process tree: `erlang:trace(TestPid, true, [procs, set_on_spawn, {tracer,
Collector}])` gives every process the test starts, transitively, a per-test
collector that receives a trace message for each abnormal exit. This is the
pass/fail signal, and it is race-free where the crash report is not: a trace
exit is delivered before the test can report its result, and
`erlang:trace_delivered/1` flushes any still in transit before the collector
is read. After each test the runner folds the collected crash reasons into
the outcome — a passing test whose worker crashed fails
(`BackgroundCrashDetail`), or is a todo if the worker died of a `todo`, the
test's own failure winning a tie. A crash a collector sees after its test
was claimed (a worker outliving its test) is recorded as unattributed;
those are reported at the end and fail the run. Nesting — vouch's own suite
runs tests that run tests — is handled by clearing the inherited trace
before setting each test's own, since a process may have only one tracer.

The BEAM's own crash reports (the emulator's "Error in process", proc_lib
crash reports, gen_\* terminate and supervisor child reports) are separately
diverted from the default logger handler into an ETS table by a capture
handler whose filter admits only crash-shaped events, purely to keep them
off the output streams and hand their raw text to `--show-crash-reports`;
they no longer drive any outcome. The default handler is re-added with
`type: standard_error` for everything else routed through logger, so it
stays visible but can never corrupt piped stdout.
(`logger:update_handler_config` silently ignores a runtime type change;
remove-and-re-add is required.)

The same trace closes the process half of that leak. A test's tree is not
torn down when the test ends — nothing in the BEAM does that, and a `normal`
exit is ignored by a non-trapping link — so a worker a test started outlives
it by default. At the claim the collector already knows which descendants
are still alive, from the `spawn` and `spawned` messages `procs` delivers
alongside the exits. Those are killed in spawn order, so an ancestor dies
before anything it would restart, and recorded as leaks for the end of the
run. Order matters throughout: the flush comes first, so every death the
test caused on its own is accounted for before the runner causes any; then
the collector is switched to discarding, so vouch's own kills are not
reported back as the test's crashes (the trap `killed` sets, since it is not
a clean exit); then the kill; then a second round only if the first killed
anything, in case a survivor restarted a child. With nothing left alive the
collector stops, which also retires the one lingering process per test.
`--keep-leaked-processes` reports without killing, for a suite that shares a
process across tests deliberately or where a leaked process is linked
outside its tree, since a kill propagates along that link.

Known limitation, accepted for v1: a test that registers global names or
mutates shared ETS tables can still leak state between tests, and a process
started through an already-running supervisor or `application:start` is
spawned outside the test's tree, so it is neither traced, reported, nor
killed. Process-per-test plus killing what a test spawned is the 90%
solution; full sandboxing is out of scope.

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
