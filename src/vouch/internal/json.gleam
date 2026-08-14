//// Minimal JSON encoding — enough for vouch's event stream, avoiding a
//// dependency for what is a page of code. Strings are escaped per RFC 8259.

import gleam/int
import gleam/list
import gleam/string

pub type Value {
  Str(String)
  Num(Int)
  Bool(Bool)
  Arr(List(Value))
  Obj(List(#(String, Value)))
}

pub fn render(value: Value) -> String {
  case value {
    Str(s) -> encode_string(s)
    Num(i) -> int.to_string(i)
    Bool(True) -> "true"
    Bool(False) -> "false"
    Arr(items) -> "[" <> string.join(list.map(items, render), ",") <> "]"
    Obj(fields) ->
      "{"
      <> string.join(
        list.map(fields, fn(f) { encode_string(f.0) <> ":" <> render(f.1) }),
        ",",
      )
      <> "}"
  }
}

fn encode_string(s: String) -> String {
  let escaped =
    s
    |> string.to_utf_codepoints
    |> list.map(escape_codepoint)
    |> string.concat
  "\"" <> escaped <> "\""
}

fn escape_codepoint(cp: UtfCodepoint) -> String {
  let code = string.utf_codepoint_to_int(cp)
  case code {
    0x22 -> "\\\""
    0x5c -> "\\\\"
    0x08 -> "\\b"
    0x0c -> "\\f"
    0x0a -> "\\n"
    0x0d -> "\\r"
    0x09 -> "\\t"
    _ ->
      case code < 0x20 {
        True -> "\\u" <> pad4(int.to_base16(code))
        False -> string.from_utf_codepoints([cp])
      }
  }
}

fn pad4(hex: String) -> String {
  case string.length(hex) {
    1 -> "000" <> hex
    2 -> "00" <> hex
    3 -> "0" <> hex
    _ -> hex
  }
}
