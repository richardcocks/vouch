//// Terminal facts and the colour decision. The FFI supplies two primitives
//// (is stdout a TTY, read an environment variable); policy lives here.

import vouch/internal/config

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

@external(erlang, "vouch_ffi", "is_stdout_tty")
@external(javascript, "../../vouch_ffi.mjs", "is_stdout_tty")
fn is_stdout_tty() -> Bool

@external(erlang, "vouch_ffi", "env")
@external(javascript, "../../vouch_ffi.mjs", "env")
fn env(name: String) -> Result(String, Nil)
