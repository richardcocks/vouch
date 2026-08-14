//// A reporter is a fold over the event stream: initial state plus a step
//// function. The runner threads the state; reporters never control
//// execution or exit codes.

import vouch/internal/event.{type Event}

pub type Reporter(state) {
  Reporter(init: state, handle: fn(state, Event) -> state)
}
