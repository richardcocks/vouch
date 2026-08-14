//// vouch — a test runner for Gleam.

import argv
import gleam/io
import vouch/internal/config
import vouch/internal/report/console
import vouch/internal/report/jsonl
import vouch/internal/runner

pub fn main() -> Nil {
  case config.from_args(argv.load().arguments) {
    Error(message) -> {
      io.println(message)
      runner.halt(2)
    }
    Ok(cfg) ->
      case cfg.format {
        config.Console -> runner.run(console.reporter(), cfg.filter)
        config.Json -> runner.run(jsonl.reporter(), cfg.filter)
      }
  }
}
