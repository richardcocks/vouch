// Busy-wait: good enough for a playground, and works in every JS runtime.
export function sleep(ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    // spin
  }
}

// The JavaScript half of parse_config: a raw runtime error, standing in for
// a broken FFI dependency. On Erlang the module itself is missing instead.
export function parse(path) {
  throw new TypeError(`config_parser is not loaded (parsing ${path})`);
}
