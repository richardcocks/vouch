// Busy-wait: good enough for a playground, and works in every JS runtime.
export function sleep(ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    // spin
  }
}

// JavaScript has no process to leak: a thrown error in a deferred callback
// would take the whole runtime down, not a sibling. The job is simply not
// run, so background_job_test passes on JavaScript and fails on the BEAM,
// where the worker really does crash — a documented target difference.
export function spawn(_job) {}

// The JavaScript half of parse_config: a raw runtime error, standing in for
// a broken FFI dependency. On Erlang the module itself is missing instead.
export function parse(path) {
  throw new TypeError(`config_parser is not loaded (parsing ${path})`);
}
