//// Watch mode: a supervisor loop that lives outside the compile step,
//// because `gleam test` is compile-then-execute and nothing inside the
//// running test process can re-invoke the compiler. Each cycle snapshots
//// the watched paths, spawns a fresh `gleam test` subprocess (paying the
//// toolchain's compile check), streams its console output through
//// untouched, then polls mtimes until something changes and goes again.
////
//// The inner run's own reporter does all the rendering: the watcher
//// injects `--color=always` when its terminal will show colour (the inner
//// process only sees a pipe, so its auto-detection would strip it) and
//// otherwise stays out of the way.

import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/result
import gleam/string
import vouch/internal/config
import vouch/internal/runner
import vouch/internal/term

/// Paths polled for changes, relative to the project root.
const watched = ["gleam.toml", "src", "test"]

const poll_interval_ms = 250

pub fn run(args: List(String)) -> Nil {
  ensure_unicode_stdio()
  // The quit listener reads stdin, and on Windows that read crashes the
  // BEAM's io server outright when the console is redirected — taking
  // every later print down with it. Interactive terminals only. (On the
  // JavaScript target this installs the interactive key worker instead,
  // which applies its own stdin-is-a-console guard.)
  let interactive = term.is_stdout_tty()
  case interactive {
    True -> install_quit_hooks()
    False -> Nil
  }
  let color = term.should_use_color(config.Auto)
  case parse_watch_args(args, color, runner.target()) {
    Error(message) -> {
      io.println_error(message)
      runner.halt(2)
    }
    Ok(#(target, flags)) -> loop(target, flags, color, interactive, 1)
  }
}

/// The target is loop state rather than baked into the argument list,
/// because the `j` / `l` / `k` keys change it between cycles.
fn loop(
  target: String,
  flags: List(String),
  color: Bool,
  interactive: Bool,
  run_number: Int,
) -> Nil {
  // Snapshot before running, so edits made while tests execute still
  // trigger the next cycle.
  let before = snapshot(watched)
  clear_screen(color)
  io.println(paint(
    color,
    dim,
    "vouch watch · run " <> int.to_string(run_number) <> " · " <> target,
  ))
  case run_passthrough("gleam", build_inner(target, flags)) {
    Error(Nil) -> {
      io.println_error("vouch: could not find `gleam` on PATH")
      runner.halt(2)
    }
    Ok(code) -> {
      print_status(code, color, interactive)
      let next = wait_for_change(before, target)
      loop(next, flags, color, interactive, run_number + 1)
    }
  }
}

/// Block until the next cycle is due, returning the target it should run
/// on: the current one for a file change or a plain rerun, the chosen one
/// for the target keys.
fn wait_for_change(
  before: List(#(String, Int, Int)),
  current: String,
) -> String {
  sleep_ms(poll_interval_ms)
  case pending_command() {
    // Enter reruns with the current settings; `a` runs the full suite.
    // They do the same thing until test filtering exists — then `a` will
    // also clear the filter — but they are distinct commands on purpose,
    // mirroring the Jest/Vitest watch keys.
    ForceRerun -> current
    RunAll -> current
    UseJavaScript -> "javascript"
    UseErlang -> "erlang"
    ToggleTarget -> toggle_target(current)
    // Not runner.halt: on JavaScript that defers the exit to a callback
    // this loop never lets run, so it would fall through as a rerun.
    Quit -> {
      halt_now(0)
      current
    }
    NoCommand ->
      case snapshot(watched) == before {
        True -> wait_for_change(before, current)
        False -> current
      }
  }
}

type WatchCommand {
  NoCommand
  ForceRerun
  RunAll
  Quit
  UseJavaScript
  UseErlang
  ToggleTarget
}

/// Key commands arrive as integers (0 none, 1 Enter, 2 `a`, 3 quit,
/// 4 `j` javascript, 5 `l` erlang, 6 `k` switch target) — from the
/// JavaScript key worker as raw keypresses, from the Erlang stdin
/// listener as key + Enter lines.
fn pending_command() -> WatchCommand {
  case take_pending_key() {
    1 -> ForceRerun
    2 -> RunAll
    3 -> Quit
    4 -> UseJavaScript
    5 -> UseErlang
    6 -> ToggleTarget
    _ -> NoCommand
  }
}

/// The other target. Pure so the key handling is unit-testable.
pub fn toggle_target(target: String) -> String {
  case target {
    "erlang" -> "javascript"
    _ -> "erlang"
  }
}

fn print_status(code: Int, color: Bool, interactive: Bool) -> Nil {
  let verdict = case code {
    0 -> paint(color, green, "passing")
    _ -> paint(color, red, "failing (exit " <> int.to_string(code) <> ")")
  }
  // The hint only holds for an interactive terminal, and the mechanism
  // differs per target: the BEAM owns SIGINT (Ctrl+C opens its BREAK
  // menu), so its keys are a line-based stdin listener (key + Enter); on
  // JavaScript a key worker listens for raw Jest/Vitest-style keypresses,
  // and when it could not be installed the runtime's default SIGINT
  // disposition still quits.
  let quit_hint = case interactive, runner.target() {
    False, _ -> ""
    True, runner.Erlang ->
      " · j/l/k then Enter for javascript/erlang/switch · q then Enter to quit"
    True, runner.JavaScript ->
      case keys_active() {
        True ->
          " · Enter to rerun · a to run all · j/l for javascript/erlang · k to switch · q to quit"
        False -> " · Ctrl+C to quit"
      }
  }
  io.println("")
  io.println(
    verdict
    <> paint(
      color,
      dim,
      " · watching " <> string.join(watched, ", ") <> quit_hint,
    ),
  )
}

/// Build the argument list for the spawned `gleam` invocation: the
/// starting target and flags from `parse_watch_args`, assembled by
/// `build_inner`. Kept as one call for the tests and as the reference
/// for what a first cycle runs.
pub fn inner_args(
  args: List(String),
  color: Bool,
  host: runner.Target,
) -> Result(List(String), String) {
  use #(target, flags) <- result.try(parse_watch_args(args, color, host))
  Ok(build_inner(target, flags))
}

/// Resolve the watcher's arguments into the starting inner target and
/// the flags for the inner run. Separated from the loop so it is
/// unit-testable: hoists `--target=x` to the build tool's side of the
/// `--`, validates the remaining flags with the same parser the inner
/// run will use (so mistakes fail once, loudly, instead of on every
/// cycle), and appends `--color=always` when the watcher's terminal
/// renders colour and the user did not choose otherwise.
///
/// The inner target defaults to the watcher's own target, so
/// `gleam run --target javascript -m vouch -- watch` watches JavaScript
/// tests without saying "javascript" twice. An explicit `--target=x`
/// after the `--` still overrides — an Erlang-hosted watcher can drive
/// JavaScript runs and vice versa. The target is always passed to the
/// inner run explicitly: when neither flag was given, the watcher's
/// target is the project default anyway, so pinning it changes nothing —
/// and the target keys then swap it between cycles.
pub fn parse_watch_args(
  args: List(String),
  color: Bool,
  host: runner.Target,
) -> Result(#(String, List(String)), String) {
  use #(target, flags) <- result.try(split_target(args, None, []))
  let flags = case color && !has_color_flag(flags) {
    True -> list.append(flags, ["--color=always"])
    False -> flags
  }
  use _ <- result.try(config.from_args(flags))
  let target = case target, host {
    Some(t), _ -> t
    None, runner.Erlang -> "erlang"
    None, runner.JavaScript -> "javascript"
  }
  Ok(#(target, flags))
}

/// The `gleam` argument list for one cycle on the given target.
pub fn build_inner(target: String, flags: List(String)) -> List(String) {
  list.flatten([["test", "--target", target, "--"], flags])
}

// Both `--target=x` and `--target x` are accepted, matching the build
// tool's own flag — this is the one option that mirrors gleam's CLI
// rather than vouch's `=`-only vocabulary.
fn split_target(
  args: List(String),
  target: Option(String),
  acc: List(String),
) -> Result(#(Option(String), List(String)), String) {
  case args {
    [] -> Ok(#(target, list.reverse(acc)))
    ["--target=" <> t, ..rest] | ["--target", t, ..rest] ->
      case t, target {
        "erlang", None | "javascript", None -> split_target(rest, Some(t), acc)
        _, Some(_) -> Error("vouch: only one --target is supported")
        _, None ->
          Error("vouch: --target expects erlang or javascript, got: " <> t)
      }
    ["--target"] -> Error("vouch: --target expects erlang or javascript")
    [arg, ..rest] -> split_target(rest, target, [arg, ..acc])
  }
}

fn has_color_flag(flags: List(String)) -> Bool {
  list.any(flags, string.starts_with(_, "--color="))
}

fn clear_screen(color: Bool) -> Nil {
  // Reuses the colour decision as a decoration gate: a terminal that wants
  // no colour (piped output, NO_COLOR) gets no escape codes at all.
  case color {
    True -> io.print("\u{001B}[2J\u{001B}[3J\u{001B}[H")
    False -> Nil
  }
}

const green = "32"

const red = "31"

const dim = "2"

fn paint(color: Bool, code: String, text: String) -> String {
  case color {
    True -> "\u{001B}[" <> code <> "m" <> text <> "\u{001B}[0m"
    False -> text
  }
}

/// One row per watched file: path, mtime as a target-local integer
/// (gregorian seconds on Erlang, milliseconds on JavaScript — snapshots
/// are only ever compared for equality), size.
/// Public so the test suite can exercise change detection directly.
@external(erlang, "vouch_ffi", "file_snapshot")
@external(javascript, "../../vouch_ffi.mjs", "file_snapshot")
pub fn snapshot(roots: List(String)) -> List(#(String, Int, Int))

@external(erlang, "vouch_ffi", "run_passthrough")
@external(javascript, "../../vouch_ffi.mjs", "run_passthrough")
fn run_passthrough(command: String, args: List(String)) -> Result(Int, Nil)

@external(erlang, "vouch_ffi", "sleep_ms")
@external(javascript, "../../vouch_ffi.mjs", "sleep_ms")
fn sleep_ms(ms: Int) -> Nil

@external(erlang, "vouch_ffi", "install_quit_hooks")
@external(javascript, "../../vouch_ffi.mjs", "install_quit_hooks")
fn install_quit_hooks() -> Nil

@external(erlang, "vouch_ffi", "take_pending_key")
@external(javascript, "../../vouch_ffi.mjs", "take_pending_key")
fn take_pending_key() -> Int

@external(erlang, "vouch_ffi", "keys_active")
@external(javascript, "../../vouch_ffi.mjs", "keys_active")
fn keys_active() -> Bool

@external(erlang, "vouch_ffi", "halt_now")
@external(javascript, "../../vouch_ffi.mjs", "halt_now")
fn halt_now(code: Int) -> Nil

@external(erlang, "vouch_ffi", "ensure_unicode_stdio")
@external(javascript, "../../vouch_ffi.mjs", "ensure_unicode_stdio")
fn ensure_unicode_stdio() -> Nil
