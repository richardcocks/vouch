// Busy-wait: good enough for a playground, and works in every JS runtime.
export function sleep(ms) {
  const end = Date.now() + ms;
  while (Date.now() < end) {
    // spin
  }
}
