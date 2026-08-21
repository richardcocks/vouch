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

On the Erlang target, BEAM diagnostics (crash reports from processes the
tests spawned, and anything else routed through OTP's logger) are now
captured during the run and reprinted as a single block on stderr after
the summary, instead of interleaving with test output mid-run. This also
stops reports being lost entirely when the VM halted before an
asynchronous report arrived.

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
