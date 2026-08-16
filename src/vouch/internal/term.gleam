//// Terminal facts and the colour decision. The FFI supplies two primitives
//// (is stdout a TTY, read an environment variable); policy lives here.

import gleam/io
import vouch/internal/config

/// A one-line advisory on stderr, where it cannot contaminate a stdout
/// stream (JSONL, TeamCity).
pub fn warn(message: String) -> Nil {
  io.println_error("vouch: " <> message)
}

pub fn should_use_color(choice: config.ColorChoice) -> Bool {
  case choice {
    config.Always -> True
    config.Never -> False
    config.Auto ->
      // https://no-color.org: any non-empty value disables colour.
      case env("NO_COLOR") {
        Ok("") -> is_stdout_tty()
        Ok(_) -> False
        Error(Nil) -> is_stdout_tty()
      }
  }
}

/// Whether stdout is an interactive terminal, independent of the colour
/// decision (NO_COLOR suppresses colour on a terminal that is still
/// interactive).
@external(erlang, "vouch_ffi", "is_stdout_tty")
@external(javascript, "../../vouch_ffi.mjs", "is_stdout_tty")
pub fn is_stdout_tty() -> Bool

@external(erlang, "vouch_ffi", "env")
@external(javascript, "../../vouch_ffi.mjs", "env")
fn env(name: String) -> Result(String, Nil)
