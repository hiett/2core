//// Thin Gleam bindings over the unit-07 test FFI (`test/twocore_conformance_ffi.erl`).
////
//// These are the only host capabilities the conformance harness needs that Gleam's
//// stdlib does not provide: invoke-with-trap-catch, file IO, JSON parsing (OTP's
//// built-in `json`), directory listing, and shelling out to the Tier-B reference
//// engine. Keeping every `@external` here means the rest of the harness is plain
//// Gleam. All bindings are total — every failure mode is a typed `Result`.

import gleam/dynamic.{type Dynamic}
import gleam/erlang/atom.{type Atom}

/// Apply `module:function(args)` on the freshly-loaded generated BEAM module and
/// capture the outcome. `Ok(raw)` is a normal return whose `raw` is the function's
/// result rendered as an integer (the raw value / IEEE-754 bit pattern, per D5);
/// `Error(text)` is any trap / exit / throw with its reason rendered as text so the
/// caller can substring-match (e.g. `"int_div_by_zero"`). Never crashes the runner.
@external(erlang, "twocore_conformance_ffi", "catch_apply")
pub fn catch_apply(
  module: Atom,
  function: Atom,
  args: List(Int),
) -> Result(Int, String)

/// Read a file's raw bytes. `Ok(bytes)` or `Error(reason)` (POSIX reason as text).
@external(erlang, "twocore_conformance_ffi", "read_file")
pub fn read_file(path: String) -> Result(BitArray, String)

/// Parse a JSON byte string into a `Dynamic` (maps keyed by binary strings, lists,
/// binaries, integers) via OTP's `json:decode/1`. `Error(reason)` on malformed JSON.
/// wast2json keeps every numeric value as a STRING, so no precision is lost here.
@external(erlang, "twocore_conformance_ffi", "parse_json")
pub fn parse_json(bytes: BitArray) -> Result(Dynamic, String)

/// List the entry names (not full paths) in `dir`. `Error(reason)` if it is not a
/// readable directory. Used to discover which `*.json` fixtures are present.
@external(erlang, "twocore_conformance_ffi", "list_dir")
pub fn list_dir(dir: String) -> Result(List(String), String)

/// Resolve `name` on `PATH`. `Ok(path)` if found, `Error(_)` otherwise — lets the
/// Tier-B adapter skip gracefully when the reference engine is not installed.
@external(erlang, "twocore_conformance_ffi", "find_executable")
pub fn find_executable(name: String) -> Result(String, String)

/// Run an external program with string `args`, returning `#(exit_code, combined
/// stdout+stderr)`. Tier-B only (never on the Tier-A path).
@external(erlang, "twocore_conformance_ffi", "run")
pub fn run(program: String, args: List(String)) -> #(Int, String)

/// A strictly-positive unique integer, used to make each generated module's name
/// unique so multi-module fixtures don't clobber one another on load.
@external(erlang, "twocore_conformance_ffi", "unique_int")
pub fn unique_int() -> Int

/// Reset the routing-partition spy flag (per process).
@external(erlang, "twocore_conformance_ffi", "spy_reset")
pub fn spy_reset() -> Nil

/// Mark that a spy driver's `instantiate` was (wrongly) reached.
@external(erlang, "twocore_conformance_ffi", "spy_mark")
pub fn spy_mark() -> Nil

/// Whether the spy's `instantiate` was reached since the last `spy_reset`.
@external(erlang, "twocore_conformance_ffi", "spy_called")
pub fn spy_called() -> Bool
