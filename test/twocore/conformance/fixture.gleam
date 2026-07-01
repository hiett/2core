//// The conformance fixture model — wast2json JSON → typed `Command`/`Action`/`SpecValue`.
////
//// Tier-A insight (VERIFIED): the spec `.wast` files already carry the expected values,
//// so wast2json's JSON is self-contained — this module needs NO compiler and NO
//// reference engine. It is the parse half of the harness; the runner drives the
//// resulting `Command`s and the oracle compares the results.
////
//// wast2json shape facts honoured here (all VERIFIED against wabt 1.0.41 output):
////  - every command is an object with a `type`;
////  - a `module` command carries a `filename` (and optionally a `name`);
////  - ALL numeric `value`s are JSON STRINGS — the **decimal of the unsigned bit
////    pattern** (i64/float bits exceed JSON number precision). They are parsed as
////    integers, never as JSON floats: `f32 1.0` is the string `"1065353216"`
////    (= `0x3F800000`), NOT `"1.0"` (D5 — we store floats as raw bits).
////  - a NaN expectation is the literal string `"nan:canonical"` / `"nan:arithmetic"`,
////    carrying only a CLASS — never a concrete bit pattern (see `oracle`).
////  - `assert_invalid`/`assert_malformed` carry a `module_type` (`"binary"` references a
////    `.wasm` we can feed the decoder/validator; `"text"` references a `.wat` we cannot
////    — there is no Phase-1 WAT parser, so the runner skips text cases).

import gleam/dynamic/decode
import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/string
import twocore/conformance/ffi

// ─────────────────────────────── value model ───────────────────────────────

/// The NaN class a float expectation demands (the spec gives two; payloads vary, so
/// a NaN never compares by bit-equality — see `oracle.matches`).
///
/// - `Canonical`: payload is exactly the MSB (`0x40_0000` for f32); either sign.
/// - `Arithmetic`: payload MSB set, the remaining payload bits arbitrary; either sign.
pub type NanKind {
  Canonical
  Arithmetic
}

/// A single WebAssembly value as it appears in a fixture. Integers and concrete floats
/// hold the **raw UNSIGNED bit pattern** (the decimal-string in the JSON, parsed to an
/// `Int`). A NaN expectation carries only a `NanKind`, never concrete bits.
///
/// - `I32Val(bits)` / `I64Val(bits)`: `bits` in `[0, 2^32)` / `[0, 2^64)`.
/// - `F32Bits(bits)` / `F64Bits(bits)`: raw IEEE-754 binary32/binary64 bits.
/// - `F32Nan(kind)` / `F64Nan(kind)`: a NaN expectation of the given class.
pub type SpecValue {
  I32Val(bits: Int)
  I64Val(bits: Int)
  F32Bits(bits: Int)
  F64Bits(bits: Int)
  F32Nan(kind: NanKind)
  F64Nan(kind: NanKind)
}

/// Which on-disk form a rejected-module command references.
///
/// - `BinaryModule`: a `.wasm` — feed it to the decoder/validator (`check_frontend`).
/// - `TextModule`: a `.wat` — a text-syntax case with no binary; the Phase-1 harness
///   has no WAT parser, so the runner SKIPS it (honest coverage, D9).
pub type ModuleType {
  BinaryModule
  TextModule
}

/// A spec-suite action: either invoke an exported function or read an exported global.
///
/// - `Invoke(field, args, module)`: call export `field` with `args`. `module` names a
///   `register`-ed / named module, or `None` to target the current module.
/// - `Get(field, module)`: read exported global `field` (Phase-1 decodes no globals,
///   so the runner reports `Get` as unsupported — kept for completeness).
pub type Action {
  Invoke(field: String, args: List(SpecValue), module: Option(String))
  Get(field: String, module: Option(String))
}

/// One spec-suite command. Exactly the five Phase-1 command kinds plus the two
/// rejected-module kinds; any other command `type` is preserved as `Unhandled` so the
/// runner reports it as a skip rather than silently dropping it (no silent truncation).
///
/// - `ModuleCmd(line, name, filename)`: load `filename` as the new current module
///   (and, if `name` is `Some`, also bind it by that name).
/// - `Register(line, as_name, module)`: alias `module` (or the current module) under
///   `as_name` for later cross-module invokes.
/// - `AssertReturn(line, action, expected)`: `action` must return values matching
///   `expected` (compared by the oracle). Full pipeline.
/// - `AssertTrap(line, action, text)`: `action` must trap; `text` is the expected
///   trap-message SUBSTRING (e.g. `"integer divide by zero"`). Full pipeline.
/// - `AssertInvalid(line, filename, module_type, text)`: `filename` must FAIL
///   validation. Frontend only — never instantiated.
/// - `AssertMalformed(line, filename, module_type, text)`: `filename` must FAIL
///   decoding. Frontend only — never instantiated.
/// - `AssertUninstantiable(line, filename, text)`: `filename` decodes + validates,
///   but INSTANTIATING it must trap (an OOB active data/element segment, or a
///   trapping `start`) with a message containing `text` (E5). Full pipeline —
///   instantiated, and asserted to fail to instantiate.
/// - `Unhandled(line, kind)`: a command outside the modelled set (e.g.
///   `assert_exhaustion`, `assert_unlinkable`) — reported as a skip.
pub type Command {
  ModuleCmd(line: Int, name: Option(String), filename: String)
  Register(line: Int, as_name: String, module: Option(String))
  AssertReturn(line: Int, action: Action, expected: List(SpecValue))
  AssertTrap(line: Int, action: Action, text: String)
  AssertInvalid(
    line: Int,
    filename: String,
    module_type: ModuleType,
    text: String,
  )
  AssertMalformed(
    line: Int,
    filename: String,
    module_type: ModuleType,
    text: String,
  )
  AssertUninstantiable(line: Int, filename: String, text: String)
  /// A bare `(invoke …)` / `(get …)` script action with NO assertion — run purely for
  /// its SIDE EFFECTS on the current module's mutable state (e.g. a `reset`/`init`/`run`
  /// that stores into memory before later asserts read it). Phase-1's pure modules made
  /// these no-ops, but with persistent per-instance memory they must EXECUTE, or later
  /// asserts read stale/zero state. Plumbing — never counted as pass/fail/skip.
  ActionCmd(line: Int, action: Action)
  Unhandled(line: Int, kind: String)
}

/// A parsed fixture: the originating `.wast` name plus its commands in file order.
pub type Fixture {
  Fixture(source_filename: String, commands: List(Command))
}

// ─────────────────────────────── parsing ───────────────────────────────

/// Parse a wast2json JSON byte string into a `Fixture`.
///
/// Returns `Ok(Fixture)` with every command decoded (unknown command kinds become
/// `Unhandled`, never an error), or `Error(reason)` if the bytes are not the expected
/// JSON shape. Total — never panics.
pub fn parse(json: BitArray) -> Result(Fixture, String) {
  case ffi.parse_json(json) {
    Error(e) -> Error("json: " <> e)
    Ok(dyn) ->
      case decode.run(dyn, fixture_decoder()) {
        Ok(f) -> Ok(f)
        Error(errs) -> Error("decode: " <> string.inspect(errs))
      }
  }
}

/// Read and parse a wast2json `.json` fixture from disk.
pub fn load(path: String) -> Result(Fixture, String) {
  case ffi.read_file(path) {
    Error(e) -> Error("read " <> path <> ": " <> e)
    Ok(bytes) -> parse(bytes)
  }
}

fn fixture_decoder() -> decode.Decoder(Fixture) {
  use source <- decode.optional_field("source_filename", "", decode.string)
  use commands <- decode.field("commands", decode.list(command_decoder()))
  decode.success(Fixture(source_filename: source, commands: commands))
}

fn command_decoder() -> decode.Decoder(Command) {
  use ty <- decode.field("type", decode.string)
  use line <- decode.optional_field("line", 0, decode.int)
  case ty {
    "module" -> {
      use name <- decode.optional_field("name", "", decode.string)
      use filename <- decode.field("filename", decode.string)
      decode.success(ModuleCmd(line, blank_to_none(name), filename))
    }
    "register" -> {
      use as_name <- decode.field("as", decode.string)
      use module <- decode.optional_field("name", "", decode.string)
      decode.success(Register(line, as_name, blank_to_none(module)))
    }
    "assert_return" -> {
      use action <- decode.field("action", action_decoder())
      use expected <- decode.field(
        "expected",
        decode.list(spec_value_decoder()),
      )
      decode.success(AssertReturn(line, action, expected))
    }
    "assert_trap" -> {
      use action <- decode.field("action", action_decoder())
      use text <- decode.optional_field("text", "", decode.string)
      decode.success(AssertTrap(line, action, text))
    }
    "assert_invalid" -> {
      use filename <- decode.field("filename", decode.string)
      use mt <- decode.optional_field("module_type", "binary", decode.string)
      use text <- decode.optional_field("text", "", decode.string)
      decode.success(AssertInvalid(line, filename, module_type(mt), text))
    }
    "assert_malformed" -> {
      use filename <- decode.field("filename", decode.string)
      use mt <- decode.optional_field("module_type", "binary", decode.string)
      use text <- decode.optional_field("text", "", decode.string)
      decode.success(AssertMalformed(line, filename, module_type(mt), text))
    }
    "assert_uninstantiable" -> {
      use filename <- decode.field("filename", decode.string)
      use text <- decode.optional_field("text", "", decode.string)
      decode.success(AssertUninstantiable(line, filename, text))
    }
    "action" -> {
      use action <- decode.field("action", action_decoder())
      decode.success(ActionCmd(line, action))
    }
    other -> decode.success(Unhandled(line, other))
  }
}

fn action_decoder() -> decode.Decoder(Action) {
  use ty <- decode.field("type", decode.string)
  use field <- decode.field("field", decode.string)
  use module <- decode.optional_field("module", "", decode.string)
  case ty {
    "get" -> decode.success(Get(field, blank_to_none(module)))
    _ -> {
      use args <- decode.optional_field(
        "args",
        [],
        decode.list(spec_value_decoder()),
      )
      decode.success(Invoke(field, args, blank_to_none(module)))
    }
  }
}

fn spec_value_decoder() -> decode.Decoder(SpecValue) {
  use ty <- decode.field("type", decode.string)
  use value <- decode.optional_field("value", "", decode.string)
  decode.success(parse_spec_value(ty, value))
}

/// Build a `SpecValue` from the JSON `type` tag and the `value` STRING. Integers and
/// concrete floats parse the decimal-of-unsigned-bits to an `Int`; the NaN literals
/// map to a `NanKind`. An absent/empty value (e.g. an `assert_trap`'s placeholder
/// `expected:[{type:i32}]`) parses to `0` and is never compared as a value.
fn parse_spec_value(ty: String, value: String) -> SpecValue {
  case ty {
    "i32" -> I32Val(parse_bits(value))
    "i64" -> I64Val(parse_bits(value))
    "f32" ->
      case nan_kind(value) {
        Some(k) -> F32Nan(k)
        None -> F32Bits(parse_bits(value))
      }
    "f64" ->
      case nan_kind(value) {
        Some(k) -> F64Nan(k)
        None -> F64Bits(parse_bits(value))
      }
    // funcref/externref are not in the Phase-1 surface; model as I32 placeholder so a
    // value position never panics (such modules skip at instantiate anyway).
    _ -> I32Val(parse_bits(value))
  }
}

fn nan_kind(value: String) -> Option(NanKind) {
  case value {
    "nan:canonical" -> Some(Canonical)
    "nan:arithmetic" -> Some(Arithmetic)
    _ -> None
  }
}

/// Parse a decimal-of-unsigned-bits string to an `Int`. BEAM integers are bignums, so
/// i64/f64 patterns up to `2^64-1` parse exactly. A non-numeric/empty string yields
/// `0` (only reached for value-less placeholders, never compared).
fn parse_bits(value: String) -> Int {
  case int.parse(value) {
    Ok(n) -> n
    Error(_) -> 0
  }
}

fn module_type(s: String) -> ModuleType {
  case s {
    "text" -> TextModule
    _ -> BinaryModule
  }
}

fn blank_to_none(s: String) -> Option(String) {
  case s {
    "" -> None
    other -> Some(other)
  }
}
