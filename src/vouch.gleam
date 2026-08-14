//// vouch — a test runner for Gleam.

import argv
import gleam/io
import gleam/option.{None, Some}
import vouch/internal/config
import vouch/internal/report/console
import vouch/internal/report/jsonl
import vouch/internal/report/junit
import vouch/internal/reporter
import vouch/internal/runner

pub fn main() -> Nil {
  case config.from_args(argv.load().arguments) {
    Error(message) -> {
      io.println(message)
      runner.halt(2)
    }
    Ok(cfg) ->
      case cfg.format, cfg.junit {
        config.Console, None -> runner.run(console.reporter(), cfg.filter, cfg.timeout_ms)
        config.Console, Some(path) ->
          runner.run(
            reporter.pair(console.reporter(), junit.reporter(path)),
            cfg.filter,
            cfg.timeout_ms,
          )
        config.Json, None -> runner.run(jsonl.reporter(), cfg.filter, cfg.timeout_ms)
        config.Json, Some(path) ->
          runner.run(
            reporter.pair(jsonl.reporter(), junit.reporter(path)),
            cfg.filter,
            cfg.timeout_ms,
          )
      }
  }
}
