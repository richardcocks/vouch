//// TeamCity service-message reporter: results are reported to the CI server
//// on stdout as the run progresses, with no report file in between. TeamCity
//// has read this format since 2006; JetBrains IDEs understand it too.
////
//// Each test is reported as a started/finished pair emitted together at
//// TestResult, rather than opening the pair at TestStart. Under --parallel
//// tests overlap, and TeamCity requires started/finished pairs on a single
//// flow to nest rather than interleave, so closing each pair immediately
//// keeps the stream valid without flow ids. Nothing is lost by reporting
//// after the fact: the duration is carried explicitly.
////
//// Outcome mapping: Todo is testFailed (consistent with the non-zero exit
//// code and with the JUnit reporter — CI must not render green while the
//// build fails); Skipped is testIgnored. A failed `assert` on == becomes a
//// comparisonFailure so TeamCity renders its side-by-side diff; other
//// operators stay plain failures, because a diff of `<` operands is
//// nonsense.

import gleam/int
import gleam/io
import gleam/list
import gleam/option.{type Option, None, Some}
import gleam/string
import vouch/internal/describe
import vouch/internal/event.{type Event}
import vouch/internal/gleam_panic.{type GleamPanic}
import vouch/internal/outcome.{type TestOutcome}
import vouch/internal/reporter.{type Reporter, Reporter}

/// The module whose suite is currently open, if any.
pub type State =
  Option(String)

pub fn reporter() -> Reporter(State) {
  Reporter(init: None, handle: fn(state, e) {
    let #(state, lines) = step(state, e)
    list.each(lines, io.println)
    state
  })
}

/// Pure core: the lines a single event produces, and the suite state after
/// it. Separated from printing so the message shapes are directly testable.
pub fn step(state: State, e: Event) -> #(State, List(String)) {
  case e {
    event.RunStart(total, _) -> #(state, [
      message("testCount", [#("count", int.to_string(total))]),
    ])
    // Suites are opened from TestResult instead, so that a parallel run
    // never reports a test as started before an earlier one has finished.
    event.TestStart(_, _) -> #(state, [])
    event.TestResult(module, function, out, duration) -> {
      let #(state, opening) = open_suite(state, module)
      #(state, list.append(opening, test_lines(function, out, duration)))
    }
    event.RunEnd(tally, _) -> {
      let total = tally.passed + tally.failed + tally.todos + tally.skipped
      let problem = case total {
        // Zero tests is a loud failure in vouch, so say why: the exit code
        // alone leaves TeamCity showing an empty, unexplained red step.
        0 -> [
          message("buildProblem", [
            #("description", "vouch ran no tests"),
            #("identity", "vouch_no_tests"),
          ]),
        ]
        _ -> []
      }
      #(None, list.append(close_suite(state), problem))
    }
  }
}

fn open_suite(state: State, module: String) -> #(State, List(String)) {
  case state {
    Some(current) if current == module -> #(state, [])
    Some(current) -> #(Some(module), [
      message("testSuiteFinished", [#("name", current)]),
      message("testSuiteStarted", [#("name", module)]),
    ])
    None -> #(Some(module), [message("testSuiteStarted", [#("name", module)])])
  }
}

fn close_suite(state: State) -> List(String) {
  case state {
    Some(current) -> [message("testSuiteFinished", [#("name", current)])]
    None -> []
  }
}

fn test_lines(
  function: String,
  out: TestOutcome,
  duration_us: Int,
) -> List(String) {
  let started = message("testStarted", [#("name", function)])
  let finished =
    message("testFinished", [
      #("name", function),
      #("duration", int.to_string(duration_us / 1000)),
    ])
  let middle = case out {
    outcome.Pass -> []
    outcome.Skipped(p) -> [
      message("testIgnored", [#("name", function), #("message", p.message)]),
    ]
    outcome.Todo(p) -> [
      failed(function, "todo at " <> site(p), p.message),
    ]
    outcome.Failed(detail) -> [failure(function, detail)]
  }
  [started, ..list.append(middle, [finished])]
}

fn failure(function: String, detail: outcome.FailureDetail) -> String {
  case detail {
    outcome.PanicDetail(p) -> panic_failure(function, p)
    outcome.UnknownDetail(raw, site) ->
      failed(function, describe.crash(raw, site), "")
    outcome.TimeoutDetail(ms) ->
      failed(function, "timed out after " <> int.to_string(ms) <> "ms", "")
    outcome.ExitDetail(raw, site) ->
      failed(function, "test process died", describe.crash(raw, site))
  }
}

fn panic_failure(function: String, p: GleamPanic) -> String {
  let where = describe.location(p)
  case p.kind {
    gleam_panic.Assert(
      kind: gleam_panic.BinaryOperator(operator: "==", left: l, right: r),
      ..,
    ) -> {
      // Oriented by describe.orient, so the diff agrees with the console
      // about which operand was the expectation.
      let #(actual, expected) = describe.orient(l, r)
      message("testFailed", [
        #("name", function),
        #("type", "comparisonFailure"),
        #("message", p.message),
        #("expected", expected),
        #("actual", actual),
        #("details", where),
      ])
    }
    // The same expected/actual wording the console reporter prints, as the
    // details block TeamCity shows under a failed test.
    _ ->
      failed(
        function,
        p.message,
        string.join([where, ..describe.panic_detail(p)], "\n"),
      )
  }
}

fn failed(function: String, message_text: String, detail: String) -> String {
  message("testFailed", [
    #("name", function),
    #("message", message_text),
    #("details", detail),
  ])
}

fn message(name: String, attributes: List(#(String, String))) -> String {
  let rendered =
    list.map(attributes, fn(a) { " " <> a.0 <> "='" <> escape(a.1) <> "'" })
  "##teamcity[" <> name <> string.concat(rendered) <> "]"
}

/// TeamCity's escaping. The pipe substitution must come first, or the pipes
/// introduced by the later rules would be escaped a second time.
fn escape(s: String) -> String {
  s
  |> string.replace("|", "||")
  |> string.replace("'", "|'")
  |> string.replace("\n", "|n")
  |> string.replace("\r", "|r")
  |> string.replace("[", "|[")
  |> string.replace("]", "|]")
}

fn site(p: GleamPanic) -> String {
  p.module <> "." <> p.function <> ":" <> int.to_string(p.line)
}
