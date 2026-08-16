// The async sequencing (dynamic import, awaiting test functions) lives here
// because JavaScript makes those operations async; decisions (what counts as
// a test, reporting, exit codes) belong to Gleam. The *_test suffix checks
// are deliberately duplicated here: filtering before the dynamic import is
// what keeps non-test modules from ever being loaded.
import { readFileSync, writeFileSync, statSync, readdirSync } from "node:fs";
import { spawnSync } from "node:child_process";
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

export function run_tests(state, should_run, on_begin, on_test_start, on_test_result, on_done) {
  run(state, should_run, on_begin, on_test_start, on_test_result, on_done);
}

async function run(state, should_run, on_begin, on_test_start, on_test_result, on_done) {
  const pkg = await readRootPackageName();
  const tests = [];
  let discovered = 0;
  for (const path of await collectGleamFiles("test")) {
    const moduleName = path.slice("test/".length, -".gleam".length);
    if (!moduleName.endsWith("_test")) continue;
    const module = await import(`../${pkg}/${moduleName}.mjs`);
    for (const name of Object.keys(module)) {
      if (!name.endsWith("_test")) continue;
      const fn = module[name];
      if (typeof fn !== "function" || fn.length !== 0) continue;
      discovered++;
      if (!should_run(moduleName, name)) continue;
      tests.push([moduleName, name, fn]);
    }
  }
  tests.sort(([am, an], [bm, bn]) =>
    am < bm ? -1 : am > bm ? 1 : an < bn ? -1 : an > bn ? 1 : 0,
  );

  state = on_begin(state, tests.length, discovered);
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

export function is_erlang() {
  return false;
}

// Stubs for the Erlang-only primitives (process isolation, parallelism).
// Unreachable: runner.run dispatches on is_erlang() before any of these
// can be called.
function erlangOnly(name) {
  throw new Error(`vouch: ${name} is only available on the Erlang target`);
}

export function redirect_diagnostics_to_stderr() {
  erlangOnly("redirect_diagnostics_to_stderr");
}

export function find_test_files() {
  erlangOnly("find_test_files");
}

export function exported_zero_arity(_module) {
  erlangOnly("exported_zero_arity");
}

export function run_test(_module, _function, _timeout_ms) {
  erlangOnly("run_test");
}

export function start_test(_module, _function, _timeout_ms) {
  erlangOnly("start_test");
}

export function await_test(_handle) {
  erlangOnly("await_test");
}

export function schedulers_online() {
  erlangOnly("schedulers_online");
}

// Watch mode primitives. The Gleam supervisor loop is synchronous, so these
// deliberately block — spawnSync for the inner run, Atomics.wait for the
// poll interval. Anything async could never fire anyway: the loop never
// returns to the event loop.

// One row per watched file: [path, mtime, size], sorted by path. The mtime
// is target-local (milliseconds here, gregorian seconds on Erlang):
// snapshots are only ever compared for equality, and the size column still
// guards same-tick rewrites.
export function file_snapshot(roots) {
  const rows = [];
  for (const root of roots) {
    collectSnapshotRows(root, rows);
  }
  rows.sort(([a], [b]) => (a < b ? -1 : a > b ? 1 : 0));
  let list = List$Empty();
  let i = rows.length;
  while (i--) {
    list = List$NonEmpty(rows[i], list);
  }
  return list;
}

function collectSnapshotRows(path, rows) {
  try {
    const stats = statSync(path, { throwIfNoEntry: false });
    if (stats === undefined) return;
    if (stats.isDirectory()) {
      for (const entry of readdirSync(path)) {
        collectSnapshotRows(`${path}/${entry}`, rows);
      }
    } else {
      rows.push([path, Math.floor(stats.mtimeMs), stats.size]);
    }
  } catch {
    // Deleted mid-walk: contribute nothing, the next poll sees the truth.
  }
}

// Output is inherited so the inner run streams straight to the terminal;
// stdin is ignored so inner runs never contend for it. Error(Nil) only for
// "not found" — anything else (notably Deno's NotCapable when allow_run is
// missing) is rethrown so the runtime's own diagnostic surfaces. No shell:
// on Windows this resolves gleam.exe via PATH but would miss a .cmd shim,
// which gleam does not ship as.
export function run_passthrough(command, args) {
  const result = spawnSync(command, [...args], {
    stdio: ["ignore", "inherit", "inherit"],
  });
  if (result.error) {
    if (result.error.code === "ENOENT") return Result$Error(undefined);
    throw result.error;
  }
  // status is null when the child dies to a signal; the watcher is about
  // to die to the same Ctrl+C, so the fallback is a formality.
  return Result$Ok(result.status ?? 1);
}

// Atomics.wait needs a SharedArrayBuffer view, allocated lazily so
// ordinary test runs never touch SharedArrayBuffer.
let sleeper;

export function sleep_ms(ms) {
  sleeper ??= new Int32Array(new SharedArrayBuffer(4));
  Atomics.wait(sleeper, 0, 0, ms);
}

// Nothing to install: the synchronous loop never returns to the event
// loop, so a stdin listener could not fire. Quitting is Ctrl+C — unlike
// the BEAM, the runtime dies to SIGINT by default, even while blocked.
export function install_quit_hooks() {}

// Node and Deno write UTF-8 to stdout/stderr regardless of redirection;
// the latin1 hazard this guards against is BEAM-specific.
export function ensure_unicode_stdio() {}

export function now_microseconds() {
  return Math.round(performance.now() * 1000);
}

export function is_stdout_tty() {
  try {
    if (globalThis.Deno) return Deno.stdout.isTerminal();
    return Boolean(process.stdout.isTTY);
  } catch {
    return false;
  }
}

export function env(name) {
  try {
    const value = globalThis.Deno ? Deno.env.get(name) : process.env[name];
    return value === undefined ? Result$Error(undefined) : Result$Ok(value);
  } catch {
    return Result$Error(undefined);
  }
}

export function write_file(path, content) {
  try {
    writeFileSync(path, content);
    return Result$Ok(undefined);
  } catch (error) {
    return Result$Error(String(error?.message ?? error));
  }
}

// The source text between two byte offsets, as the compiler recorded them in
// a panic payload. Any failure to read is an Error: source text is a nicety
// on top of the payload, never a requirement. Byte offsets, not string
// indices, so the slice happens before decoding.
export function read_source(path, start, end) {
  try {
    if (start < 0 || end <= start) return Result$Error(undefined);
    const bytes = readFileSync(path);
    if (bytes.length < end) return Result$Error(undefined);
    return Result$Ok(new TextDecoder().decode(bytes.subarray(start, end)));
  } catch {
    return Result$Error(undefined);
  }
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
    // process.exit() discards stdout writes still buffered when stdout is a
    // pipe, which would truncate a large JSONL stream mid-line. A write's
    // callback runs only once everything queued before it has been flushed,
    // so exiting from an empty write's callback preserves the whole stream.
    process.stdout.write("", () => process.exit(code));
  }
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
