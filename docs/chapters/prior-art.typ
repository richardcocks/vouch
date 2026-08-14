= Prior art <sec-prior-art>

== How other ecosystems split framework from runner

Test tooling elsewhere falls into roughly three patterns:

*Designed adapter/SPI* — framework and runner are separate products joined by a
published interface that third parties implement (a Service Provider Interface:
an interface you _implement_ and the host calls, as opposed to an API you
call).

- .NET: VSTest hosts frameworks via adapter interfaces (`ITestDiscoverer` /
  `ITestExecutor`); xUnit, NUnit and MSTest each ship an adapter.
- JVM: JUnit 5 split itself into the JUnit Platform (launcher + `TestEngine`
  SPI), Jupiter (the framework), and Vintage (a `TestEngine` wrapping JUnit 4).
  Spock, jqwik, Kotest and Cucumber all run as engines on the Platform.
- Haskell: tasty is a framework-agnostic host; tasty-hunit, tasty-quickcheck
  and friends are providers.

*Wire-protocol or CLI split* — the boundary is a data format or a thin binary
interface rather than an API.

- Perl/TAP (1987): `Test::More` produces TAP on stdout; `prove` consumes it.
  TAP notably has native `# TODO` directive semantics.
- Rust: `harness = false` lets a crate supply its own test main; cargo-nextest
  exists as an alternative runner because the test binary's `--list` interface
  is a stable de-facto contract.
- Go: `go test -json` emits a newline-delimited event stream; gotestsum is an
  alternative reporter built on it. (The framework itself, `testing`, is
  toolchain-privileged and irreplaceable — `go test` has hardcoded knowledge of
  `func TestXxx(*testing.T)`.)

*Bundled* — one tool does discovery, execution, assertion and reporting.
ExUnit, RSpec, Jest/Vitest, and Gleam's gleeunit. Python inverted the pattern:
pytest is a runner that grew the ability to host other frameworks' tests.

Modern JavaScript deserves a precise reading because it is the closest
structural analogue to Gleam: no designed SPI, failure is a thrown value with
no runner-supplied context object, and portability arises from shared
convention (`describe`/`it`/`expect`, assertion libraries that just throw). In
exactly that setting, Vitest displaced Jest by implementing the incumbent's
authoring surface and being better underneath. That is the strategy available
to vouch: the `*_test` convention is the compatibility surface, and it is far
cheaper to match than Jest's API was.

== Where Gleam sits

Gleam has no framework/runner split at all. The entire built-in contract is:
`gleam test` compiles the project and calls `main()` in
`test/<package_name>_test.gleam` on the configured target. No discovery
protocol, no adapter interface, no result format. Every "test framework" for
Gleam is therefore simultaneously framework, runner, and reporter — the layers
collapse because there is nothing to attach them to separately.

Structurally this is Rust's `harness = false` for every project, minus the
standardised binary interface that made nextest possible. What Gleam does have
is one universal contract: *a test fails by panicking*, and the panic payload
(particularly from the `assert` keyword, Gleam 1.11+) carries structured
information. That payload is the closest thing Gleam has to a framework/runner
boundary, and vouch treats it as such.

For an ecosystem Gleam's size, a full adapter SPI would be machinery with no
second implementer. The two cheap pieces that pay off — the position healthy
ecosystems converged on — are a structured outcome model and machine-readable
output. vouch builds both; publishing the outcome type as a stable SPI for
property-testing and snapshot libraries (qcheck, birdie) is deferred until the
design has earned it. See @sec-roadmap.

== Existing Gleam runners

- *gleeunit* — the default, scaffolded by `gleam new`. Minimal by design; no
  configuration surface. Erlang side delegates to EUnit with a custom progress
  listener; JavaScript side is an independent bespoke implementation. Its moat
  is wide (template privilege: nearly every project starts with it) but shallow
  (nearly nothing depends on it — since the `assert` keyword landed, its
  assertion module is no longer a reason to stay). Maintained by Gleam's
  creator, which confers implicit blessing without formal toolchain privilege.
- *showtime* — alternative runner, both targets.
- *startest* — alternative runner, both targets; abandons the zero-arity
  convention for a describe/it DSL, with filtering.
- *exercism_test_runner* — emits structured JSON, but purpose-built for
  Exercism's platform rather than general use.

All three alternatives honour or extend the gleeunit discovery convention,
which is evidence the convention — not any implementation — is the standard.
Reading gleeunit's source (it is a few hundred lines) is a prerequisite for the
walking-skeleton phase; several claims in this document should be confirmed
against its current version. See @sec-open-questions.
