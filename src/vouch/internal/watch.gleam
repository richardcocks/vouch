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
  // JavaScript target install_quit_hooks is a no-op either way.)
  let interactive = term.is_stdout_tty()
  case interactive {
    True -> install_quit_hooks()
    False -> Nil
  }
  let color = term.should_use_color(config.Auto)
  case inner_args(args, color) {
    Error(message) -> {
      io.println_error(message)
      runner.halt(2)
    }
    Ok(inner) -> loop(inner, color, interactive, 1)
  }
}

fn loop(
  inner: List(String),
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
    "vouch watch · run " <> int.to_string(run_number),
  ))
  case run_passthrough("gleam", inner) {
    Error(Nil) -> {
      io.println_error("vouch: could not find `gleam` on PATH")
      runner.halt(2)
    }
    Ok(code) -> {
      print_status(code, color, interactive)
      wait_for_change(before)
      loop(inner, color, interactive, run_number + 1)
    }
  }
}

fn wait_for_change(before: List(#(String, Int, Int))) -> Nil {
  sleep_ms(poll_interval_ms)
  case snapshot(watched) == before {
    True -> wait_for_change(before)
    False -> Nil
  }
}

fn print_status(code: Int, color: Bool, interactive: Bool) -> Nil {
  let verdict = case code {
    0 -> paint(color, green, "passing")
    _ -> paint(color, red, "failing (exit " <> int.to_string(code) <> ")")
  }
  // The quit hint only holds for an interactive terminal, and the
  // mechanism differs per target: the BEAM owns SIGINT (Ctrl+C opens its
  // BREAK menu), so quitting there is a stdin listener; on JavaScript the
  // blocked event loop rules a listener out, and the runtime's default
  // SIGINT disposition quits.
  let quit_hint = case interactive, runner.target() {
    False, _ -> ""
    True, runner.Erlang -> " · q then Enter to quit"
    True, runner.JavaScript -> " · Ctrl+C to quit"
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

/// Build the argument list for the spawned `gleam` invocation. Separated
/// from the loop so it is unit-testable: hoists `--target=x` to the build
/// tool's side of the `--`, validates the remaining flags with the same
/// parser the inner run will use (so mistakes fail once, loudly, instead
/// of on every cycle), and appends `--color=always` when the watcher's
/// terminal renders colour and the user did not choose otherwise.
pub fn inner_args(
  args: List(String),
  color: Bool,
) -> Result(List(String), String) {
  use #(target, flags) <- result.try(split_target(args, None, []))
  let flags = case color && !has_color_flag(flags) {
    True -> list.append(flags, ["--color=always"])
    False -> flags
  }
  use _ <- result.try(config.from_args(flags))
  let target_args = case target {
    None -> []
    Some(t) -> ["--target", t]
  }
  Ok(list.flatten([["test"], target_args, ["--"], flags]))
}

fn split_target(
  args: List(String),
  target: Option(String),
  acc: List(String),
) -> Result(#(Option(String), List(String)), String) {
  case args {
    [] -> Ok(#(target, list.reverse(acc)))
    ["--target=" <> t, ..rest] ->
      case t, target {
        "erlang", None | "javascript", None -> split_target(rest, Some(t), acc)
        _, Some(_) -> Error("vouch: only one --target is supported")
        _, None ->
          Error("vouch: --target expects erlang or javascript, got: " <> t)
      }
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

@external(erlang, "vouch_ffi", "ensure_unicode_stdio")
@external(javascript, "../../vouch_ffi.mjs", "ensure_unicode_stdio")
fn ensure_unicode_stdio() -> Nil
