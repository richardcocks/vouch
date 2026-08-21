//// vouch: a gleeunit compatible test runner for Gleam.
////
//// Tests are discovered as usual, by files in `test/` ending in `_test`
//// public zero-arity functions ending in `_test` 
//// See README.md for more information.

import argv
import gleam/io
import gleam/option.{None, Some}
import vouch/internal/config
import vouch/internal/report/console
import vouch/internal/report/jsonl
import vouch/internal/report/junit
import vouch/internal/report/teamcity
import vouch/internal/reporter
import vouch/internal/runner
import vouch/internal/term
import vouch/internal/watch

/// Run the test suite, honouring the options given after `--` on the
/// `gleam test` command line. The entire migration from gleeunit is
/// swapping it in:
///
/// ```gleam
/// import vouch
///
/// pub fn main() {
///   vouch.main()
/// }
/// ```
///
/// Exits 0 when every test passed or was skipped, 1 when any test failed
/// or was blocked on a todo (and when no tests were found), 2 on a usage
/// error.
pub fn main() -> Nil {
  case argv.load().arguments {
    ["watch", ..rest] -> watch.run(rest)
    args -> run_tests(args)
  }
}

fn run_tests(args: List(String)) -> Nil {
  case config.from_args(args) {
    Error(message) -> {
      io.println_error(message)
      runner.halt(2)
    }
    Ok(cfg) -> {
      let color = term.should_use_color(cfg.color)
      case cfg.format, cfg.junit {
        config.Console, None ->
          runner.run(
            console.reporter(cfg.filter, color),
            cfg.filter,
            cfg.timeout_ms,
            cfg.parallel,
          )
        config.Console, Some(path) ->
          runner.run(
            reporter.pair(
              console.reporter(cfg.filter, color),
              junit.reporter(path),
            ),
            cfg.filter,
            cfg.timeout_ms,
            cfg.parallel,
          )
        config.Json, None ->
          runner.run(jsonl.reporter(), cfg.filter, cfg.timeout_ms, cfg.parallel)
        config.Json, Some(path) ->
          runner.run(
            reporter.pair(jsonl.reporter(), junit.reporter(path)),
            cfg.filter,
            cfg.timeout_ms,
            cfg.parallel,
          )
        config.TeamCity, None ->
          runner.run(
            teamcity.reporter(),
            cfg.filter,
            cfg.timeout_ms,
            cfg.parallel,
          )
        config.TeamCity, Some(path) ->
          runner.run(
            reporter.pair(teamcity.reporter(), junit.reporter(path)),
            cfg.filter,
            cfg.timeout_ms,
            cfg.parallel,
          )
      }
    }
  }
}
