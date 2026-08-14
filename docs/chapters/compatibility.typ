= Compatibility with gleeunit <sec-compatibility>

== The claim

For a convention-following project, migration is one line:

```diff
-import gleeunit
+import vouch

 pub fn main() {
-  gleeunit.main()
+  vouch.main()
 }
```

No test file changes. No new dependency on gleeunit, and no removal required
either (though it becomes dead weight).

== Why this works

*Compatibility targets the convention, not the library.* The discovery
convention (`*_test` modules, public zero-arity `*_test` functions) is
ecosystem-wide; vouch honours it exactly.

*Assertions carry over because they were never gleeunit's.* Tests fail by
panicking, a language-level channel with no runner-supplied handle — there is
no context object threaded from runner into test, so nothing couples a test to
the runner that started it. This covers all of:

- the `assert` keyword and `let assert` (language features),
- `panic` and `todo` (language features),
- `gleeunit/should.*` — ordinary functions that panic. A test file full of
  `should.equal` runs correctly under vouch without vouch knowing gleeunit
  exists.

The observable difference is output quality, not correctness: `assert` failures
decode into rich diffs; `should.*` failures arrive as pre-formatted strings and
render as such. vouch does not special-case gleeunit's message format in v1.

== Behavioural differences, intentional

- *Zero tests discovered fails loudly* instead of succeeding quietly.
- *`todo` is classified*, not treated as a generic failure — see
  @sec-test-model. Net effect on exit codes: a suite whose only "failures" were
  todo-stub test bodies (`pub fn x_test() { todo }`) previously exited 1 under
  gleeunit and now exits 0 (Skipped). Todos in exercised code still exit 1.
  This is the one migration-visible semantic change and the changelog/README
  must state it prominently.
- *Crashing or hanging tests are contained* on Erlang (process-per-test,
  timeouts) instead of taking down or wedging the run.

== The EUnit cliff

On Erlang, gleeunit delegates to EUnit, so a project can contain hand-written
`.erl` test modules using EUnit generators (`foo_test_() -> ...`), fixtures, or
`{setup, ...}` tuples that happen to work today. vouch does not reimplement
EUnit and never will; those modules are out of scope, permanently. Projects
that need EUnit features should keep running them with EUnit/rebar3 alongside
vouch.

This is expected to affect very few Gleam projects (the pattern is
Erlang-interop territory), but it is the one hard "no" in the compatibility
story and belongs in the README, not just here.

== Coexistence

Nothing prevents a project depending on both gleeunit and vouch during
evaluation; whichever `main()` the test module calls is the runner. There is no
global state and no registration step, so switching back is the same one line
reversed.
