= Test model <sec-test-model>

== Discovery

vouch discovers tests by the ecosystem convention gleeunit established:

- modules under `test/` whose name ends in `_test`
- public zero-arity functions whose name ends in `_test`

Enumeration of compiled modules and their exports is FFI; everything after that
(suffix matching, ordering, filtering) is pure Gleam over plain data.

A run that discovers *zero tests is a failure* (loud, non-zero exit). A typo'd
suffix or a misconfigured target silently reporting success is worse than a
false alarm.

Name filtering: `gleam test -- --filter=text` runs only tests whose qualified
name (`module.function`) contains the text. Substring match in v1; nothing
fancier until someone needs it. Bare positional arguments are rejected with a
hint, so a mistyped flag cannot silently become a filter.

== Failure is the panic channel

A Gleam test communicates exactly one thing: whether it panicked. There is no
runner-supplied context object (nothing like Go's `*testing.T`), which is
precisely why any runner can execute any convention-following test. The panic
arrives in one of several shapes, all of which vouch must catch and decode:

#table(
  columns: (1fr, 1.2fr, 1.4fr),
  table.header([Shape], [Source], [Payload richness]),
  [`assert` failure],
  [`assert` keyword (Gleam 1.11+)],
  [rich: expression source, subexpression values, location],
  [`let assert` failure],
  [pattern match failure],
  [value that failed to match, location],
  [`panic` / `panic as "msg"`],
  [explicit],
  [message, location],
  [`todo` / `todo as "msg"`],
  [unimplemented marker],
  [message, location — see below],
  [gleeunit `should.*`],
  [ordinary functions that panic],
  [pre-formatted string only],
  [raw runtime error],
  [FFI code, crashes],
  [target-specific error value],
)

Decoding is per-target FFI normalisation followed by pure-Gleam
interpretation. On Erlang the decoder searches nested exit-reason tuples
recursively, because OTP wraps payloads: a panic inside a gen_server callback
reaches the calling test as `{{Payload, Stacktrace}, {gen_server, call, ...}}`
— a todo raised inside an OTP process must still classify as Todo, not as an
opaque failure. The `assert` payload is what makes rich console diffs possible;
`should.*` failures can only ever render as the string gleeunit formatted.
Exact payload shapes, especially on JavaScript, are top of the verification
list in @sec-open-questions.

== Outcome model

```gleam
pub type TestOutcome {
  Pass(duration: Duration)
  Fail(detail: FailureDetail, duration: Duration)
  Todo(site: Site, message: Option(String), duration: Duration)
  Skipped(message: Option(String))
}
```

(Shapes indicative; exact fields settle during implementation.)

== Todo and Skipped semantics

`todo` panics carry their site (module, function, line). vouch uses the site to
distinguish two situations that are conflated today, applying one mechanical
rule:

#quote(block: true)[
  If the todo's site is the running test function itself, the test is
  *Skipped*. If the site is anywhere else, the outcome is *Todo*.
]

*Todo — the test hit unimplemented code.* The test exercised a `todo` in the
code under test. This is the test-driven development signal: it separates "I
have not implemented this" (yellow) from "I have implemented this wrong" (red),
which call for different responses. Todo is still not-done, so it contributes a
non-zero exit code — CI must not go green while `todo` is live in exercised
code paths. Output shows the blocking site (`todo at src/limiter.gleam:41`),
and the console reporter groups tests blocked on the same site into a single
work item: `5 tests blocked on todo at src/limiter.gleam:41`.

*Skipped — the test body is the todo.* `pub fn foo_test() { todo }` is a
pending test, not a failing one. It renders dimmed, maps to `<skipped>` in
JUnit XML, and does not affect the exit code. This gives vouch skip support with
zero new convention: stubbing a test with `todo` is already the idiomatic thing
to write, and vouch simply reports it truthfully.

Edge cases, resolved by the rule rather than by judgement:

- A `todo` in a test-module _helper_ function is Todo, not Skipped (site is not
  the running test function). Predictable, and the misclassification direction
  is safe: it fails loud.
- If a target's payload lacks a usable site, degrade to *Todo*. Failing safe
  means failing loud, never silently green.

#table(
  columns: (auto, 1.6fr, auto, auto, auto),
  table.header([Outcome], [Trigger], [Console], [Exit], [JUnit]),
  [Pass], [no panic], [green], [0], [`<testcase>`],
  [Fail], [assert / panic / crash], [red], [1], [`<failure>`],
  [Todo], [`todo` hit in code under test], [yellow], [1], [`<failure type="todo">`],
  [Skipped], [test body is `todo`], [dim], [0], [`<skipped>`],
)

History: this design descends from a long-open gleeunit PR
(#link("https://github.com/lpil/gleeunit/pull/67")[gleeunit\#67]) adding a todo
reporting category. The site split refines it: the PR had to pick one exit-code
policy for both cases, and the reporting-only change still required patching
per-target FFI. In vouch the distinction is one variant in the outcome type and
every reporter inherits it.

== What the model deliberately excludes in v1

No tags, focus, fixtures, setup/teardown, or parametrized tests. Each requires
a channel beyond "public zero-arity function" — a return type, a registration
API, or a DSL — and choosing that channel is the central v2 design question,
not something to bolt onto v1. The convention that makes compatibility free is
also expressively minimal; vouch v1 accepts that trade. See @sec-roadmap.
