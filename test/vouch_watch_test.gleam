//// Watch mode's testable parts: the inner-command construction (pure) and
//// filesystem snapshot change detection. The loop itself never returns, so
//// it is exercised manually against examples/playground rather than here.
//// Manual checks, run from examples/playground:
////   - `gleam run -m vouch -- watch`: cycles on file changes; q + Enter
////     quits; the status line shows the quit hint.
////   - `gleam run -m vouch -- watch > log.txt`: must keep cycling rather
////     than crash (a non-console stdin kills the BEAM io server if the
////     quit listener reads it), log.txt gets UTF-8 with no ANSI codes,
////     and the status line omits the quit hint.
////   - `gleam run --target javascript -m vouch -- watch --target=javascript`:
////     same cycling on the Node host; Ctrl+C quits, and the status line
////     says so.

import gleam/list
import vouch/internal/watch

pub fn inner_args_default_test() {
  assert watch.inner_args([], False) == Ok(["test", "--"])
}

pub fn inner_args_passes_flags_through_test() {
  assert watch.inner_args(["--filter=slow", "--timeout=100"], False)
    == Ok(["test", "--", "--filter=slow", "--timeout=100"])
}

pub fn inner_args_injects_color_for_tty_test() {
  // The inner run only sees a pipe, so a colour terminal must be pinned.
  assert watch.inner_args(["--filter=slow"], True)
    == Ok(["test", "--", "--filter=slow", "--color=always"])
}

pub fn inner_args_respects_explicit_color_test() {
  assert watch.inner_args(["--color=never"], True)
    == Ok(["test", "--", "--color=never"])
}

pub fn inner_args_hoists_target_test() {
  // --target belongs to the build tool, before the `--`.
  assert watch.inner_args(["--target=javascript", "--filter=x"], False)
    == Ok(["test", "--target", "javascript", "--", "--filter=x"])
}

pub fn inner_args_rejects_unknown_target_test() {
  let assert Error(_) = watch.inner_args(["--target=python"], False)
}

pub fn inner_args_rejects_repeated_target_test() {
  let assert Error(_) =
    watch.inner_args(["--target=erlang", "--target=javascript"], False)
}

pub fn inner_args_rejects_unknown_flag_test() {
  // Validated once at startup with the inner run's own parser, so a typo
  // fails loudly instead of on every cycle.
  let assert Error(_) = watch.inner_args(["--wibble"], False)
}

pub fn snapshot_walks_directories_test() {
  let entries = watch.snapshot(["src"])
  assert list.length(entries) > 5
}

pub fn snapshot_missing_root_is_empty_test() {
  assert watch.snapshot(["no_such_path_anywhere"]) == []
}

pub fn snapshot_detects_change_test() {
  // Size participates in the comparison, so a rewrite within the mtime's
  // granularity (one second on Erlang, one millisecond on JavaScript) is
  // still a change.
  let path = "build/vouch_watch_snapshot_probe.txt"
  let assert Ok(_) = write_file(path, "one")
  let before = watch.snapshot([path])
  assert list.length(before) == 1
  assert watch.snapshot([path]) == before
  let assert Ok(_) = write_file(path, "one, but longer")
  assert watch.snapshot([path]) != before
}

@external(erlang, "vouch_ffi", "write_file")
@external(javascript, "./vouch_ffi.mjs", "write_file")
fn write_file(path: String, content: String) -> Result(Nil, String)
