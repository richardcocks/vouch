# Changelog

## Unreleased

Crash reports now name what was being called. A test that dies with a
non-Gleam error (an undef from a stale or missing .beam, an FFI crash)
previously reported only the bare reason — "Crashed: Undef" — with the
failing call discarded. The stacktrace's top frame is now carried into the
report on the Erlang target:

    Crashed: Undef calling config_parser:parse/1

with an `at file:line` line when the frame carries one. The same site
reaches the TeamCity and JUnit failure messages, and the JSONL stream as
structured `site_module` / `site_function` / `site_arity` (plus
`site_file` / `site_line` when known) fields. JavaScript crashes are
unchanged: a JS stacktrace is an unparsed string, so there is no site to
extract.

A process that crashes behind a test now fails it. On the Erlang target, an
unlinked worker, a fire-and-forget job, an actor nothing is monitoring —
anything a test starts that dies without taking the test down — used to
leave the test passing and the run green (as it still does under gleeunit),
with the BEAM's crash report on stderr as the only trace. vouch now traces
each test's process tree, so a process it started that crashes is caught
and charged to that exact test — in a `--parallel` run as much as a
sequential one. The test fails:

    playground_test.background_job_test
      Background process crashed at src/playground.gleam:26
        background job crashed: queue is full

or is a todo, when the process died of a `todo`. A test that failed on its
own keeps its own failure. A crash from a process that outlived its test,
or that no test started, is reported at the end and fails the run. The
JSONL stream carries it as `"kind":"background_crash"` with the cause
nested under `cause`; JUnit and TeamCity get a `background_crash` failure
with the same text. The BEAM's own crash reports are kept off the output
streams; the new `--show-crash-reports` flag prints them in full as one
block on stderr after the summary. Other logger output (a library's
warnings) is not a crash and still goes to stderr. JavaScript is
unaffected: there are no processes to crash behind a test there.

Processes a test leaves running are now killed and reported. Nothing in the
BEAM tears down a test's process tree when the test ends, and a `normal`
exit does not kill a linked child, so a worker a test started kept running
into later tests and could crash long after its own test had been reported.
On the Erlang target the per-test trace now also names every process the
test started that is still alive when it ends. Those are killed there —
ancestors first, so a process restarting its children is gone before they
are touched — and listed after the summary:

    vouch: 1 leaked process killed after the test that started them:
    vouch: playground_test.leaky_worker_test left playground:start_long_worker/0 running

A leak does not fail the run. `--keep-leaked-processes` leaves them running
and only reports them, for a suite that deliberately shares a process across
tests or where a leaked process is linked to something outside the test's
tree. Processes started through an already-running supervisor or
`application:start` are spawned outside the test's tree and are unaffected.

## v1.2.0

Watch mode added for the JavaScript target, supporting both Node and Deno

The syntax for this is slightly awkward:
`gleam run --target javascript -m vouch -- watch` noting that
the `--target` has to come before the `--` not after!

This controls the target of the parent watcher, and defaults the 
inner runtime to that too. You can have the runtime of
the inner tests be different by specifying `--target=erlang` after 
the `--`.

On the javascript runner, you can re-run all manually with `a` and 
quitting will happen on `q`. On the erlang runner you have to press `q` 
and then hit `<enter>` sorry, I can't figure out how to get more responsive 
console in erlang. PRs welcome!

## v1.1.0

Add --test-name-filter for startest compatibility to allow running in zed.

## v1.0.0

Initial release, gleeunit compatible test runner for gleam.
