// Walking-skeleton FFI. The async sequencing (dynamic import, awaiting test
// functions) lives here because JavaScript makes those operations async;
// decisions (what counts as a test, reporting, exit codes) belong to Gleam.
// TODO: the *_test suffix checks are duplicated here so non-test modules are
// never imported; unify once the discovery/execution contract settles.
import { Result$Ok, Result$Error, List$Empty, List$NonEmpty } from "./gleam.mjs";
import {
  GleamPanic$GleamPanic,
  PanicKind$Todo,
  PanicKind$Panic,
  PanicKind$LetAssert,
  PanicKind$Assert,
  AssertKind$BinaryOperator,
  AssertKind$FunctionCall,
  AssertKind$OtherExpression,
  AssertedExpression$AssertedExpression,
  ExpressionKind$Literal,
  ExpressionKind$Expression,
  ExpressionKind$Unevaluated,
} from "./vouch/internal/gleam_panic.mjs";

export function run_tests(state, on_begin, on_test_start, on_test_result, on_done) {
  run(state, on_begin, on_test_start, on_test_result, on_done);
}

async function run(state, on_begin, on_test_start, on_test_result, on_done) {
  const pkg = await readRootPackageName();
  const tests = [];
  for (const path of await collectGleamFiles("test")) {
    const moduleName = path.slice("test/".length, -".gleam".length);
    if (!moduleName.endsWith("_test")) continue;
    const module = await import(`../${pkg}/${moduleName}.mjs`);
    for (const name of Object.keys(module)) {
      if (!name.endsWith("_test")) continue;
      const fn = module[name];
      if (typeof fn !== "function" || fn.length !== 0) continue;
      tests.push([moduleName, name, fn]);
    }
  }
  tests.sort(([am, an], [bm, bn]) =>
    am < bm ? -1 : am > bm ? 1 : an < bn ? -1 : an > bn ? 1 : 0,
  );

  state = on_begin(state, tests.length);
  for (const [moduleName, name, fn] of tests) {
    state = on_test_start(state, moduleName, name);
    let outcome;
    try {
      await fn();
      outcome = Result$Ok(undefined);
    } catch (error) {
      outcome = Result$Error(error);
    }
    state = on_test_result(state, moduleName, name, outcome);
  }
  on_done(state);
}

export function now_microseconds() {
  return Math.round(performance.now() * 1000);
}

// Synchronous invocation for callers that already hold the function value.
export function catch_panic(f) {
  try {
    f();
    return Result$Ok(undefined);
  } catch (error) {
    return Result$Error(error);
  }
}

// Decode a thrown value into vouch's GleamPanic type, or error for anything
// that is not a Gleam panic.
export function decode_panic(error) {
  if (!(error instanceof globalThis.Error) || !error.gleam_error) {
    return Result$Error(undefined);
  }

  if (error.gleam_error === "todo") {
    return wrap(error, PanicKind$Todo());
  }

  if (error.gleam_error === "panic") {
    return wrap(error, PanicKind$Panic());
  }

  if (error.gleam_error === "let_assert") {
    const kind = PanicKind$LetAssert(
      error.start,
      error.end,
      error.pattern_start,
      error.pattern_end,
      error.value,
    );
    return wrap(error, kind);
  }

  if (error.gleam_error === "assert") {
    const kind = PanicKind$Assert(
      error.start,
      error.end,
      error.expression_start,
      assertKind(error),
    );
    return wrap(error, kind);
  }

  return Result$Error(undefined);
}

function assertKind(error) {
  if (error.kind === "binary_operator") {
    return AssertKind$BinaryOperator(
      error.operator,
      expression(error.left),
      expression(error.right),
    );
  }

  if (error.kind === "function_call") {
    let args = List$Empty();
    let i = error.arguments.length;
    while (i--) {
      args = List$NonEmpty(expression(error.arguments[i]), args);
    }
    return AssertKind$FunctionCall(args);
  }

  return AssertKind$OtherExpression(expression(error.expression));
}

function expression(data) {
  let kind;
  if (data.kind === "literal") {
    kind = ExpressionKind$Literal(data.value);
  } else if (data.kind === "expression") {
    kind = ExpressionKind$Expression(data.value);
  } else {
    kind = ExpressionKind$Unevaluated();
  }
  return AssertedExpression$AssertedExpression(data.start, data.end, kind);
}

function wrap(e, kind) {
  return Result$Ok(
    GleamPanic$GleamPanic(e.message, e.file, e.module, e.function, e.line, kind),
  );
}

export function halt(code) {
  if (globalThis.Deno) {
    Deno.exit(code);
  } else {
    process.exit(code);
  }
}

function toList(array) {
  let list = List$Empty();
  for (let i = array.length - 1; i >= 0; i--) {
    list = List$NonEmpty(array[i], list);
  }
  return list;
}

async function collectGleamFiles(directory) {
  const collected = [];
  for (const entry of await readDir(directory)) {
    const path = `${directory}/${entry}`;
    if (path.endsWith(".gleam")) {
      collected.push(path);
    } else {
      try {
        collected.push(...(await collectGleamFiles(path)));
      } catch {
        // Not a directory.
      }
    }
  }
  return collected;
}

async function readDir(path) {
  if (globalThis.Deno) {
    const items = [];
    for await (const item of Deno.readDir(path)) {
      items.push(item.name);
    }
    return items;
  } else {
    const { readdir } = await import("node:fs/promises");
    return readdir(path);
  }
}

async function readRootPackageName() {
  let toml;
  if (globalThis.Deno) {
    toml = await Deno.readTextFile("gleam.toml");
  } else {
    const { readFile } = await import("node:fs/promises");
    toml = (await readFile("gleam.toml")).toString();
  }
  for (const line of toml.split("\n")) {
    const matches = line.match(/\s*name\s*=\s*"([a-z][a-z0-9_]*)"/);
    if (matches) return matches[1];
  }
  throw new Error("Could not determine package name from gleam.toml");
}
