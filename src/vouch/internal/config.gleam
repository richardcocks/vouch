//// Parses arguments forwarded by `gleam test -- ...`.

import gleam/option.{type Option, None, Some}
import gleam/string

pub type Format {
  Console
  Json
}

pub type Config {
  Config(format: Format, filter: Option(String), junit: Option(String))
}

pub fn from_args(args: List(String)) -> Result(Config, String) {
  parse(args, Config(format: Console, filter: None, junit: None))
}

fn parse(args: List(String), config: Config) -> Result(Config, String) {
  case args {
    [] -> Ok(config)
    ["--format=console", ..rest] ->
      parse(rest, Config(..config, format: Console))
    ["--format=json", ..rest] -> parse(rest, Config(..config, format: Json))
    ["--junit=" <> path, ..rest] ->
      parse(rest, Config(..config, junit: Some(path)))
    [arg, ..rest] ->
      case string.starts_with(arg, "-") {
        True -> Error(usage("unknown option: " <> arg))
        False ->
          case config.filter {
            None -> parse(rest, Config(..config, filter: Some(arg)))
            Some(_) -> Error(usage("only one filter pattern is supported"))
          }
      }
  }
}

fn usage(problem: String) -> String {
  "vouch: "
  <> problem
  <> "\n\nUsage: gleam test -- [pattern] [--format=console|json] [--junit=path]\n"
  <> "  pattern         run only tests whose module.function contains it\n"
  <> "  --format=json   emit a JSONL event stream instead of console output\n"
  <> "  --junit=path    also write a JUnit XML report to the given file"
}
