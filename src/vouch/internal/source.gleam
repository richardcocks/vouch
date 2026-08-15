//// Reading back the source text a panic points at.
////
//// Every panic payload carries byte offsets into the file it came from —
//// the whole statement, and each subexpression within it. Reading those
//// spans lets a failure name the code that failed instead of describing it
//// abstractly: `a value matching Ok(port)` rather than `the pattern`.
////
//// The offsets are the compiler's, recorded at build time, so the file on
//// disk may have moved on, or may not be reachable at all (a panic from a
//// dependency, a JavaScript runtime without read permission). Every lookup
//// therefore returns a Result and every caller has wording that works
//// without it.

import gleam/bit_array
import gleam/result
import gleam/string

/// The source text between two byte offsets, or Error if the file cannot be
/// read. Offsets are bytes, matching the payload, not grapheme indices.
@external(erlang, "vouch_ffi", "read_source")
@external(javascript, "../../vouch_ffi.mjs", "read_source")
pub fn slice(file: String, start: Int, end: Int) -> Result(String, Nil)

/// A span of source, but only if the text at `start` really is the
/// statement the payload describes — `keyword` is the token the compiler
/// must have emitted there.
///
/// Build-time paths are relative to the package root, so a panic raised
/// inside a dependency can name a path that resolves, from the test
/// runner's working directory, to an unrelated file of the same name.
/// Checking the keyword makes that mismatch fail closed rather than
/// printing confident nonsense from the wrong file.
pub fn statement(
  file: String,
  start: Int,
  end: Int,
  keyword: String,
) -> Result(String, Nil) {
  case slice(file, start, start + string.byte_size(keyword)) {
    Ok(found) if found == keyword -> slice(file, start, end)
    _ -> Error(Nil)
  }
}

/// A byte range of text already in hand, so the subexpressions of a
/// statement can be quoted without reading the file once per span. Byte
/// offsets to match the payload — `string.slice` counts graphemes, which
/// would drift from the compiler's offsets on any line holding non-ASCII.
pub fn byte_slice(text: String, start: Int, end: Int) -> Result(String, Nil) {
  case start >= 0 && end > start {
    True ->
      bit_array.from_string(text)
      |> bit_array.slice(start, end - start)
      |> result.try(bit_array.to_string)
    False -> Error(Nil)
  }
}
