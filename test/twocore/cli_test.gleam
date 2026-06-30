//// Unit 11c CLI integration tests — drive the subcommand dispatcher (`twocore.run/1`)
//// exactly as `main` does (it is `run(argv.load().arguments)`), proving decision #5: every
//// stage is independently invokable, and bad input yields a typed error (never a panic).
////
//// These exercise the REAL pipeline + file IO (reading the committed corpus `.wasm` and
//// golden `.ir` fixtures), so they are true end-to-end CLI tests, not arg-parsing unit
//// tests.

import gleam/string
import simplifile
import twocore

const corpus = "test/twocore/conformance/corpus"

const golden = "test/twocore/ir/golden"

// ─────────────────────────────── end-to-end `run` ───────────────────────────────

/// `run add.wasm add 2 3` prints `5` (the documented arg convention: raw unsigned decimals).
/// This is the full Safe pipeline (decode→…→ir_lower→…→invoke) behind one command.
pub fn cli_run_add_test() {
  assert twocore.run(["run", corpus <> "/add.wasm", "add", "2", "3"]) == Ok("5")
}

/// `run sum_to.wasm sum_to 100` prints `5050` — the constant-space loop, through ir_lower.
pub fn cli_run_sum_to_test() {
  assert twocore.run(["run", corpus <> "/sum_to.wasm", "sum_to", "100"])
    == Ok("5050")
}

/// A divide-by-zero is reported as a trap (exit non-zero in `main`); the reason carries the
/// spec trap kind.
pub fn cli_run_trap_test() {
  let assert Error(msg) =
    twocore.run(["run", corpus <> "/intops.wasm", "divu", "10", "0"])
  assert string.contains(msg, "trap")
  assert string.contains(msg, "int_div_by_zero")
}

// ─────────────────────────────── per-stage subcommands ───────────────────────────────

/// `ir <in.wasm>` prints the `.ir` (source→IR end-to-end, unit 02's printer).
pub fn cli_ir_test() {
  let assert Ok(text) = twocore.run(["ir", corpus <> "/add.wasm"])
  assert string.contains(text, "module @")
  assert string.contains(text, "i.add.32")
}

/// `validate <in.wasm>` accepts a well-typed module.
pub fn cli_validate_test() {
  assert twocore.run(["validate", corpus <> "/fib.wasm"]) == Ok("valid")
}

/// `decode <in.wasm>` dumps the WASM AST.
pub fn cli_decode_test() {
  let assert Ok(text) = twocore.run(["decode", corpus <> "/add.wasm"])
  assert string.contains(text, "Module(")
}

/// `ir-lower <in.ir>` runs the Safe policy pass and prints `.ir` with the metering `charge`
/// inserted (the visible evidence that ir_lower ran).
pub fn cli_ir_lower_inserts_charge_test() {
  let assert Ok(text) = twocore.run(["ir-lower", golden <> "/sum_to.ir"])
  assert string.contains(text, "charge")
}

/// `to-core <in.ir>` runs ir_lower(Safe) + emit_core and prints `.core` text.
pub fn cli_to_core_test() {
  let assert Ok(text) = twocore.run(["to-core", golden <> "/add.ir"])
  assert string.contains(text, "module 'add'")
}

/// `emit <in.ir>` runs emit_core alone (no policy pass) and prints `.core` text.
pub fn cli_emit_test() {
  let assert Ok(text) = twocore.run(["emit", golden <> "/add.ir"])
  assert string.contains(text, "module 'add'")
}

/// `to-beam` compiles `.core` to a real `.beam` binary on disk (round-tripping the `.core`
/// produced by `to-core`).
pub fn cli_to_beam_writes_beam_test() {
  let assert Ok(core) = twocore.run(["to-core", golden <> "/add.ir"])
  let tmp_core = "build/cli_test_add.core"
  let tmp_beam = "build/cli_test_add.beam"
  let assert Ok(Nil) = simplifile.write(tmp_core, core)
  let assert Ok(msg) = twocore.run(["to-beam", tmp_core, tmp_beam])
  assert string.contains(msg, "wrote")
  // the .beam exists and is non-trivial
  let assert Ok(beam) = simplifile.read_bits(tmp_beam)
  assert beam != <<>>
  let _ = simplifile.delete(tmp_core)
  let _ = simplifile.delete(tmp_beam)
}

// ─────────────────────────────── fail-closed dispatch (never panics) ───────────────────────────────

/// No arguments → the usage text as an `Error` (exit non-zero), never a panic.
pub fn cli_usage_on_no_args_test() {
  let assert Error(msg) = twocore.run([])
  assert string.contains(msg, "Usage")
}

/// An unrecognised subcommand → the usage text as an `Error`.
pub fn cli_usage_on_unknown_command_test() {
  let assert Error(msg) = twocore.run(["frobnicate", "x"])
  assert string.contains(msg, "Usage")
}

/// A missing input file → a typed read error (`Error`), never a panic.
pub fn cli_missing_file_is_typed_error_test() {
  let assert Error(msg) =
    twocore.run(["decode", corpus <> "/does_not_exist.wasm"])
  assert string.contains(msg, "read")
}

/// A non-integer `run` argument → a typed error, never a panic.
pub fn cli_bad_run_argument_test() {
  let assert Error(msg) =
    twocore.run(["run", corpus <> "/add.wasm", "add", "two", "3"])
  assert string.contains(msg, "not an integer")
}
