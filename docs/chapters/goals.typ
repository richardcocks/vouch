= Goals <sec-goals>

== Motivation

Gleam's default test runner, gleeunit, is deliberately minimal: convention-based
discovery, pass/fail output, an exit code. It has no configuration surface at
all — no reporter options, no machine-readable output, no filtering, no
isolation. Its internals make this hard to change: discovery, execution, and
formatting are all implemented twice, once per target, inside the foreign
function interface (on Erlang by delegating to EUnit with a custom listener; on
JavaScript as a separate bespoke loop). Every output feature costs two
implementations kept in sync by hand, which is why the cheapest consistent
choice has been to offer nothing.

The practical consequences for Gleam projects today:

- CI systems see only "the build went red". No per-test results, no annotations
  on pull requests, no timing history, no flaky-test tracking.
- Editors have no structured output to build test explorers or inline gutters
  on.
- A test that hangs, hangs `gleam test` forever. A test that crashes linked
  processes can take down more than itself.
- A test that exercises unimplemented (`todo`) code is indistinguishable from a
  test whose assertions failed — a real loss of signal during test-driven
  development.

vouch exists to fix these while keeping the migration cost at one line.

== Design principles

+ *Convention compatibility, not library compatibility.* The valuable thing
  gleeunit owns is the convention (`*_test` modules, public zero-arity `*_test`
  functions), not its implementation or API. vouch honours the convention and
  depends on nothing from gleeunit. See @sec-compatibility.

+ *Push the FFI boundary as low as it will go.* Target-specific code does only
  what genuinely requires it: enumerate modules and functions, invoke a
  function while capturing a panic, read a clock, halt the runtime. Everything
  above that — filtering, scheduling, the outcome model, every reporter — is
  pure Gleam, written once, identical on both targets. This is the single
  highest-leverage decision in the design and the direct answer to gleeunit's
  structural trap. See @sec-architecture.

+ *Failure is a language-level channel.* Gleam tests fail by panicking
  (`assert`, `let assert`, `panic`, `todo`); there is no runner-supplied
  context object and no framework-owned assertion library. vouch leans into
  this: the panic payload is the interface, and decoding it well — including
  the structured subexpression values the `assert` keyword provides — is
  core-path work, not a feature.

+ *Machine-readable output is a first-class citizen.* An internal event stream
  is the spine of the runner; the console reporter, the JSONL output, and the
  JUnit XML are all consumers of the same events. Adding a format is a new
  Gleam module, not a pair of FFI implementations.

+ *Both targets from day one.* Building Erlang and JavaScript together forces
  the FFI contract to be honest. Deferring one invites a design shaped around
  the other's assumptions — gleeunit's mistake in mirror image. Target
  capabilities may differ (see @sec-execution); target existence may not.

+ *Near-zero dependencies.* vouch is a dev dependency in every consumer's tree;
  version conflicts in a test runner are especially obnoxious. Budget: the
  standard library, `argv`, and reluctance.

== Non-goals

- *EUnit compatibility.* Projects with hand-written `.erl` test modules using
  EUnit generators or fixtures are out of scope, permanently. See
  @sec-compatibility.
- *A describe/it DSL.* The zero-arity convention is the v1 authoring surface.
  Richer structure (tags, fixtures, parametrized tests) requires a channel
  beyond the convention and is deliberately deferred until it can be designed
  properly. See @sec-roadmap.
- *Replacing the build tool.* `gleam test` remains the entry point; vouch is a
  library it calls. Compilation, caching, and target selection stay
  toolchain-owned.
