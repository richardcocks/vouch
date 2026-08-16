//// Parses arguments forwarded by `gleam test -- ...`.

import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Format {
  Console
  Json
  TeamCity
}

pub type ColorChoice {
  Auto
  Always
  Never
}

/// Sequential is the default: tests that share external resources
/// (registered processes, files, ports) are not parallel-safe by
/// convention, so concurrency is opt-in. AutoParallel sizes the worker
/// pool to the scheduler count at runtime.
pub type Parallelism {
  Sequential
  AutoParallel
  Workers(Int)
}

pub type Config {
  Config(
    format: Format,
    filter: Option(String),
    junit: Option(String),
    timeout_ms: Int,
    color: ColorChoice,
    parallel: Parallelism,
  )
}

pub const default_timeout_ms = 5000

pub fn from_args(args: List(String)) -> Result(Config, String) {
  parse(
    args,
    Config(
      format: Console,
      filter: None,
      junit: None,
      timeout_ms: default_timeout_ms,
      color: Auto,
      parallel: Sequential,
    ),
  )
}

fn parse(args: List(String), config: Config) -> Result(Config, String) {
  case args {
    [] -> Ok(config)
    ["--format=console", ..rest] ->
      parse(rest, Config(..config, format: Console))
    ["--format=json", ..rest] -> parse(rest, Config(..config, format: Json))
    ["--format=teamcity", ..rest] ->
      parse(rest, Config(..config, format: TeamCity))
    ["--filter=" <> pattern, ..rest] -> set_filter(rest, config, pattern)
    // Alias for --filter. Zed's Gleam extension runs the test under the
    // cursor as `gleam test -- --test-name-filter=<function>` (Startest's
    // flag name), so accepting it makes Zed's click-to-run work.
    ["--test-name-filter=" <> pattern, ..rest] ->
      set_filter(rest, config, pattern)
    ["--color=auto", ..rest] -> parse(rest, Config(..config, color: Auto))
    ["--color=always", ..rest] -> parse(rest, Config(..config, color: Always))
    ["--color=never", ..rest] -> parse(rest, Config(..config, color: Never))
    ["--junit=" <> path, ..rest] ->
      parse(rest, Config(..config, junit: Some(path)))
    ["--timeout=" <> value, ..rest] ->
      case int.parse(value) {
        Ok(ms) if ms >= 1 -> parse(rest, Config(..config, timeout_ms: ms))
        _ ->
          Error(usage(
            "--timeout expects milliseconds of at least 1, got: " <> value,
          ))
      }
    ["--parallel", ..rest] ->
      parse(rest, Config(..config, parallel: AutoParallel))
    ["--parallel=" <> value, ..rest] ->
      case int.parse(value) {
        Ok(n) if n >= 1 -> parse(rest, Config(..config, parallel: Workers(n)))
        _ ->
          Error(usage(
            "--parallel expects a worker count of at least 1, got: " <> value,
          ))
      }
    [arg, ..] ->
      case string.starts_with(arg, "-") {
        True -> Error(usage("unknown option: " <> arg))
        False ->
          Error(usage(
            "unexpected argument: "
            <> arg
            <> " (did you mean --filter="
            <> arg
            <> "?)",
          ))
      }
  }
}

fn set_filter(
  rest: List(String),
  config: Config,
  pattern: String,
) -> Result(Config, String) {
  case config.filter {
    None -> parse(rest, Config(..config, filter: Some(pattern)))
    Some(_) -> Error(usage("only one --filter/--test-name-filter is supported"))
  }
}

fn usage(problem: String) -> String {
  "vouch: "
  <> problem
  <> "\n\nUsage: gleam test -- [options]\n"
  <> "  --filter=text   run only tests whose module.function contains text\n"
  <> "  --test-name-filter=text\n"
  <> "                  alias for --filter, as sent by Zed's run-test task\n"
  <> "  --format=json   emit a JSONL event stream instead of console output\n"
  <> "  --format=teamcity\n"
  <> "                  emit TeamCity service messages instead of console\n"
  <> "                  output, for CI servers that read them from stdout\n"
  <> "  --junit=path    also write a JUnit XML report to the given file\n"
  <> "  --timeout=ms    per-test timeout on the Erlang target (default 5000)\n"
  <> "  --parallel[=n]  run tests concurrently on the Erlang target with n\n"
  <> "                  workers (default: one per scheduler)\n"
  <> "  --color=mode    console colour: auto (default), always, never;\n"
  <> "                  auto respects NO_COLOR and non-TTY output\n"
  <> "\n"
  <> "Watch mode (rerun on file change):\n"
  <> "  gleam run -m vouch -- watch [options] [--target=erlang|javascript]"
}
