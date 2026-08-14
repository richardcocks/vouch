#set document(title: "vouch — design documents", author: "Rich")
#set page(numbering: "1")
#set text(font: "Merriweather", size: 11pt)
#set par(leading: 0.75em, spacing: 1.2em)
#show raw: set text(font: "Cascadia Mono", size: 0.9em)
#set heading(numbering: "1.1")
#show link: underline
#show raw.where(block: true): it => block(
  fill: luma(246),
  inset: 8pt,
  radius: 3pt,
  width: 100%,
  it,
)
#show heading.where(level: 1): it => {
  pagebreak(weak: true)
  it
}

#align(center)[
  #text(size: 24pt, weight: "bold")[vouch]
  #v(0.3em)
  #text(size: 14pt)[Design documents]
  #v(0.3em)
  #text(size: 10pt, fill: luma(100))[August 2026 — planning phase, pre-implementation]
]

#v(1.5em)

vouch is a test runner for Gleam. Written from scratch — not a gleeunit fork —
but compatible with the gleeunit convention, so existing test suites run
unchanged.

This document records the design as settled during planning, before the first
line of code. Where a decision rests on an unverified assumption, that
assumption is listed in @sec-open-questions and must be checked against the
real toolchain during the walking-skeleton phase.

#v(1em)

#outline(depth: 2, indent: auto)

#include "chapters/goals.typ"
#include "chapters/prior-art.typ"
#include "chapters/architecture.typ"
#include "chapters/test-model.typ"
#include "chapters/execution.typ"
#include "chapters/output.typ"
#include "chapters/compatibility.typ"
#include "chapters/roadmap.typ"
#include "chapters/open-questions.typ"
