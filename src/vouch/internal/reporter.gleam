//// A reporter is a fold over the event stream: initial state plus a step
//// function. The runner threads the state; reporters never control
//// execution or exit codes.

import vouch/internal/event.{type Event}

pub type Reporter(state) {
  Reporter(init: state, handle: fn(state, Event) -> state)
}

/// Run two reporters over the same event stream.
pub fn pair(a: Reporter(x), b: Reporter(y)) -> Reporter(#(x, y)) {
  Reporter(init: #(a.init, b.init), handle: fn(state, e) {
    #(a.handle(state.0, e), b.handle(state.1, e))
  })
}
