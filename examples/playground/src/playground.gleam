//// Code under test for the playground: one implemented function, one
//// unimplemented one (the target for deep-todo outcomes).

pub fn add(a: Int, b: Int) -> Int {
  a + b
}

pub fn rate_limit(_requests: Int) -> Bool {
  todo as "rate limiting is not implemented yet"
}

@external(erlang, "playground_ffi", "sleep")
@external(javascript, "./playground_ffi.mjs", "sleep")
pub fn sleep(ms: Int) -> Nil
