# Changelog

## Unreleased

Watch mode now runs on the JavaScript target (Node and Deno), so
`gleam run --target javascript -m vouch -- watch` works without the BEAM
installed. Quitting is Ctrl+C on JavaScript (q then Enter on Erlang stays
as it was). Deno projects using watch mode need `allow_run = ["gleam"]` in
their `gleam.toml`.

The inner test runs now follow the watcher's own target by default;
pass `--target=erlang|javascript` after the `--` to run them on a
different target than the watcher.

On the JavaScript host, watch mode now has the core Jest/Vitest keys:
Enter forces a rerun, `a` runs the whole suite, `q` (or Ctrl+C) quits —
single keypress, no Enter needed. When stdin is not an interactive
console the keys degrade away and Ctrl+C still quits.

## v1.1.0

Add --test-name-filter for startest compatibility to allow running in zed.

## v1.0.0

Initial release, gleeunit compatible test runner for gleam.
