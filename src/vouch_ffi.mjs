// Walking-skeleton FFI. The async sequencing (dynamic import, awaiting test
// functions) lives here because JavaScript makes those operations async;
// decisions (what counts as a test, reporting, exit codes) belong to Gleam.
// TODO: the *_test suffix checks are duplicated here so non-test modules are
// never imported; unify once the discovery/execution contract settles.
import { Result$Ok, Result$Error, List$Empty, List$NonEmpty } from "./gleam.mjs";

export function run_tests(report) {
  run(report);
}

async function run(report) {
  const pkg = await readRootPackageName();
  const results = [];
  for (const path of await collectGleamFiles("test")) {
    const moduleName = path.slice("test/".length, -".gleam".length);
    if (!moduleName.endsWith("_test")) continue;
    const module = await import(`../${pkg}/${moduleName}.mjs`);
    for (const name of Object.keys(module)) {
      if (!name.endsWith("_test")) continue;
      const fn = module[name];
      if (typeof fn !== "function" || fn.length !== 0) continue;
      let outcome;
      try {
        await fn();
        outcome = Result$Ok(undefined);
      } catch (error) {
        outcome = Result$Error(error);
      }
      results.push([moduleName, name, outcome]);
    }
  }
  report(toList(results));
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
