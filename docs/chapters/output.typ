= Output <sec-output>

== The event stream is the spine

Every reporter — console included — is a consumer of the same internal event
sequence:

```text
RunStart   { total, discovered }   // discovered = count before filtering
TestStart  { module, function }
TestResult { module, function, outcome, duration_microseconds }
RunEnd     { tally: { passed, failed, todos, skipped }, duration_microseconds }
```

Carrying the pre-filter `discovered` count lets reporters distinguish
"nothing exists" from "nothing matched the filter", and print
`Running 5 of 28 tests` under a filter.

This makes streaming the default posture and turns document formats into
folds: JUnit XML buffers events until `RunEnd`; the console prints as events
arrive; JSONL serialises events one per line. Adding a format is one pure-Gleam
module.

== Console reporter

The default, and the most visible differentiator. Requirements:

- *Rich failure rendering from the `assert` payload*: the failing expression's
  source, subexpression values, expected/actual diff where derivable.
  `should.*` failures render the pre-formatted string gleeunit produced — the
  output floor, not the target.
- Todo grouping: tests blocked on the same `todo` site collapse into one
  work item under an "Unimplemented code:" section, carrying the todo's own
  message: `todo at src/limiter.gleam:41 — "..." (5 tests)`.
- Summary line with all four outcome counts:
  `12 passed, 1 failed, 3 todo, 2 skipped (1.2s)`.
- Colour: green/red/yellow/dim per the outcome table in @sec-test-model,
  controlled by `--color=auto|always|never`; auto colours only when stdout
  is a TTY and `NO_COLOR` is unset (empty counts as unset).
- Failure details grouped at the end, after the progress output, so the last
  screenful is the useful one.

=== Failure wording

A failure is rendered as an expectation and an outcome — `Expected:` /
`But was:`, the shape NUnit, xUnit and Jest have made universal — rather than
as a dump of the payload's fields. The operator chooses the phrasing (`<`
becomes "less than", `!=` becomes "anything except", `&&` names both
operands so the short-circuited side is visible as `(not evaluated)`), which
is what stops `<` from being reported as though it were an equality.

For `==` and `!=` the left operand is taken as the actual value, matching the
`assert actual == expected` shape tests are overwhelmingly written in. When
the left operand is a literal and the right is not, the two are swapped: a
literal is what a test expects, never what it computed. The payload's
`Literal`/`Expression` distinction is what makes that decidable.

Where the payload alone is too abstract to read — a pattern that did not
match, a predicate that returned False — the byte offsets it carries are used
to read the failing statement back off disk, so the report quotes the code:
`a value matching Ok(port)`, `within_budget(spend) to be True`. Two
consequences follow. First, the file may not be the one the offsets were
recorded against (a panic from a dependency resolves its relative path
against the *consumer's* working directory), so the statement is only used
when the token at the recorded start position is the keyword the payload
implies — a mismatch fails closed rather than quoting confident nonsense from
an unrelated file. Second, reading can simply be unavailable (no read
permission under Deno, a moved file); every kind therefore keeps wording that
stands on the payload alone, and the quoted form is strictly an upgrade.

Reporters share one implementation of this (`vouch/internal/describe`), so the
console, the TeamCity details block and the JUnit failure body cannot drift
apart. The JSONL stream is deliberately *not* a consumer: it carries the
operands and operator as separate fields for machines to phrase themselves.

== JSONL: `--format=json`

Newline-delimited JSON, one event per line — the flag says `json` for
discoverability, the content is JSONL. Precedent: `go test -json` and cargo's
libtest JSON are both event streams, for the same reasons:

- Streaming consumers (editors, watch supervisors, CI log tailers) get events
  as they happen.
- Crash-robust: every line already emitted is valid even if the run dies
  mid-way.
- The single-document view is derivable — fold the stream, or read the final
  `run_end` line for totals. The reverse derivation is impossible.

The v1 events are `run_start` (total, discovered), `test_start`,
`test_result` (outcome, `duration_us`, and per-kind failure fields such as
`left`/`right`/`operator` for asserts, todo site fields, `timeout_ms`), and
`run_end` (tally and duration). The field-level schema is *explicitly
unstable in v1*; stabilising it is a v2 commitment, made once real
consumers exist.

== JUnit XML: `--junit=path`

The format every CI system consumes (GitHub Actions annotations, GitLab test
reports, Jenkins). No general-purpose Gleam runner emits it today; this is the
headline CI feature.

- One `<testsuite>` per test module, `<testcase>` per test with timing.
- Outcome mapping per @sec-test-model: Fail → `<failure>`,
  Todo → `<failure type="todo">` (consistent with the non-zero exit code — CI
  must not render all-green while the build fails), Skipped → `<skipped>`.
- Target the de-facto Ant/Surefire schema, tolerant-consumer flavour; verified
  against what GitHub Actions and GitLab actually parse rather than any purist
  reading of the schema.

Written to a file (path via flag) rather than stdout, so it can coexist with
console output in CI.

== TeamCity service messages: `--format=teamcity`

Emitted on stdout as the run progresses, with no file in between: the CI
server reads results straight out of the build log. TeamCity has consumed this
format since 2006 and JetBrains IDEs read it too, which makes it the cheapest
possible integration — no schema, no artifact upload step, and results appear
while the run is still going.

- One `testSuiteStarted`/`testSuiteFinished` pair per test module; a
  `testStarted`/`testFinished` pair per test, carrying its duration in
  milliseconds.
- Outcome mapping per @sec-test-model: Fail and Todo → `testFailed` (Todo
  keeps its site in the message), Skipped → `testIgnored`. A failed `assert`
  on `==` becomes `type='comparisonFailure'` with `expected` and `actual`,
  which is what makes TeamCity render its side-by-side diff; other operators
  stay plain failures, because a diff of `<` operands is nonsense.
- Both halves of a test's pair are emitted together at `TestResult` rather
  than split across `TestStart` and `TestResult`. Under `--parallel` tests
  overlap, and TeamCity requires pairs on a single flow to nest rather than
  interleave; closing each pair immediately keeps the stream valid without
  flow ids, and nothing is lost because the duration is carried explicitly.
- Zero tests emits a `buildProblem`, so the non-zero exit is backed by a
  stated reason rather than an empty, unexplained red step.

== Exit codes

Computed in pure Gleam from the `RunEnd` tally:

#table(
  columns: (1.6fr, 1fr),
  table.header([Condition], [Exit]),
  [all tests Pass or Skipped], [0],
  [any Fail (including timeouts)], [1],
  [any Todo (unimplemented code exercised)], [1],
  [zero tests ran — nothing discovered, or a filter matched nothing; the
    message says which], [1],
  [unusable arguments (unknown flag, bare positional argument)], [2, with
    usage text],
)

A run with only Todos (no Fails) exits 1 but renders yellow, not red — the
"not done" state is visually distinct from the "broken" state.

== Deferred formats

TAP is cheap to emit (and its 1987-vintage `# TODO` directive matches vouch's
todo semantics almost exactly) but its consumer audience barely overlaps with
Gleam's; it is a fast-follow if anyone asks, not v1.
