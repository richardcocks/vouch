# Changelog

## Unreleased

A process that crashes now fails the test:

    playground_test.background_job_test
      Background process crashed at src/playground.gleam:26
        background job crashed: queue is full

There is also a process leak detector. This doesn't fail the
run, and `--keep-leaked-processes` leaves them running instead.

Watch mode can now switch the inner target between runs, with keys 'j', 'k', and 'l' to switch to Javascript, toggle 
between them, and switch to Erlang respectively.

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
