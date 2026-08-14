//// vouch — a test runner for Gleam.

import argv
import gleam/io
import gleam/string
import vouch/internal/report/console
import vouch/internal/runner

pub fn main() -> Nil {
  case argv.load().arguments {
    [] -> Nil
    args -> io.println("forwarded args: " <> string.inspect(args))
  }
  runner.run(console.reporter())
}
