//// Parses arguments forwarded by `gleam test -- ...`.

import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string

pub type Format {
  Console
  Json
}

pub type Config {
  Config(
    format: Format,
    filter: Option(String),
    junit: Option(String),
    timeout_ms: Int,
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
    ),
  )
}

fn parse(args: List(String), config: Config) -> Result(Config, String) {
  case args {
    [] -> Ok(config)
    ["--format=console", ..rest] ->
      parse(rest, Config(..config, format: Console))
    ["--format=json", ..rest] -> parse(rest, Config(..config, format: Json))
    ["--filter=" <> pattern, ..rest] ->
      case config.filter {
        None -> parse(rest, Config(..config, filter: Some(pattern)))
        Some(_) -> Error(usage("only one --filter is supported"))
      }
    ["--junit=" <> path, ..rest] ->
      parse(rest, Config(..config, junit: Some(path)))
    ["--timeout=" <> value, ..rest] ->
      case int.parse(value) {
        Ok(ms) -> parse(rest, Config(..config, timeout_ms: ms))
        Error(Nil) ->
          Error(usage("--timeout expects milliseconds, got: " <> value))
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

fn usage(problem: String) -> String {
  "vouch: "
  <> problem
  <> "\n\nUsage: gleam test -- [options]\n"
  <> "  --filter=text   run only tests whose module.function contains text\n"
  <> "  --format=json   emit a JSONL event stream instead of console output\n"
  <> "  --junit=path    also write a JUnit XML report to the given file\n"
  <> "  --timeout=ms    per-test timeout on the Erlang target (default 5000)"
}
