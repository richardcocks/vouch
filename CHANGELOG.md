# Changelog

## v1.0.0 - Unreleased

Initial release.

- gleeunit-compatible discovery: modules under `test/` ending in `_test`,
  public zero-arity functions ending in `_test`.
- Expected/actual failure reports decoded from `assert`, `let assert`,
  `panic` and `todo` payloads, with source quoting from the payload's byte
  offsets.
- Todo as its own outcome: a `todo` hit in code under test reports as todo
  (exit 1), a test body that is a `todo` is a skipped pending stub (exit 0).
- Process isolation on the Erlang target, with per-test `--timeout` and
  opt-in concurrency via `--parallel[=n]`.
- JavaScript target support (Node and Deno), sequential and in-process.
- Machine-readable output: `--format=json` (JSONL event stream),
  `--format=teamcity` (service messages), `--junit=path` (JUnit XML).
- Watch mode: `gleam run -m vouch -- watch [options]` reruns the suite on
  changes to `src/`, `test/`, or `gleam.toml`.
