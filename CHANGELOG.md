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
leave the test passing and the run green, with the BEAM's crash report on
stderr as the only trace. vouch now captures those crash reports and
charges each to the test whose process died (every process a test starts
inherits the test's group leader, which the report records, so attribution
is exact under `--parallel` too). The test fails:

    playground_test.background_job_test
      Background process crashed at src/playground.gleam:26
        background job crashed: queue is full

or is a todo, when the process died of a `todo`. A test that failed on its
own keeps its own failure. A report that arrives after its test finished,
or from a process no test started, is printed at the end and fails the
run. The JSONL stream carries it as `"kind":"background_crash"` with the
cause nested under `cause`; JUnit and TeamCity get a `background_crash`
failure with the same text. Other logger output (a library's warnings) is
not a crash and still goes to stderr. A new `--show-crash-reports` flag
additionally prints the full BEAM reports as one block on stderr after the
summary. JavaScript is unaffected: there are no processes to crash behind
a test there.

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
