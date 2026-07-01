//// The real pipeline `Driver` — composes the public stages of 2core into the seam the
//// runner drives, plus a `stub` driver for testing the harness with no compiler.
////
//// `pipeline()` wires the EXISTING, committed stages (units 04–10): decode → validate
//// → lower → `emit_module(_, safe_default())` → `compile_and_load` → invoke. Nothing
//// here re-implements compiler logic; it only sequences the public APIs and adapts
//// their per-stage error types (D4) into the runner's `String` channel. This is what
//// makes "is our output spec-correct?" answerable end-to-end (and what unit 11's
//// capstone reuses instead of re-deriving an oracle/driver).
////
//// Invoke convention (D5/D10): a generated export returns its result as an Erlang
//// integer — the raw value / IEEE-754 bit pattern. `invoke` tags that integer back to
//// a typed `SpecValue` using the export's DECLARED result width, so the oracle can
//// compare. Arguments travel the same way (raw bits in, as integers).

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/atom
import gleam/int
import gleam/list
import gleam/result
import gleam/string
import twocore/backend/build_beam
import twocore/backend/core_printer
import twocore/backend/emit_core
import twocore/conformance/ffi
import twocore/conformance/fixture.{
  type SpecValue, F32Bits, F32Nan, F64Bits, F64Nan, I32Val, I64Val,
}
import twocore/conformance/runner.{type Driver, type Instance, type InvokeResult}
import twocore/frontend/wasm/decode
import twocore/frontend/wasm/lower
import twocore/frontend/wasm/validate
import twocore/ir
import twocore/runtime/profiles

/// The real pipeline driver: the full Phase-1 vertical slice behind the runner seam.
pub fn pipeline() -> Driver {
  runner.Driver(
    check_frontend: check_frontend,
    instantiate: instantiate,
    invoke: invoke,
  )
}

/// A do-nothing driver: every entry point reports failure. Lets the harness, fixtures,
/// parser, oracle and routing be tested with NO compiler in play (the temporal seam —
/// unit 11 can likewise swap a driver in). `check_frontend` returns `Error` (so a
/// stub-driven `assert_invalid` still "passes" by rejection) while `instantiate`
/// fails, proving the partition: invalid/malformed never reach `instantiate`.
pub fn stub() -> Driver {
  runner.Driver(
    check_frontend: fn(_bytes) { Error("stub: not implemented") },
    instantiate: fn(_bytes) { Error("stub: not implemented") },
    invoke: fn(_inst, _field, _args) {
      runner.DriverError("stub: not implemented")
    },
  )
}

// ─────────────────────────────── check_frontend ───────────────────────────────

/// Decode + validate ONLY (the `assert_invalid`/`assert_malformed` partition). Returns
/// `Ok(Nil)` iff the bytes decode AND validate; otherwise `Error(reason)` carrying the
/// rejecting stage's typed error (fail-closed, D4). Never instantiates / runs anything.
pub fn check_frontend(bytes: BitArray) -> Result(Nil, String) {
  use m <- result.try(
    decode.decode(bytes)
    |> result.map_error(fn(e) { "decode: " <> string.inspect(e) }),
  )
  use _tm <- result.try(
    validate.validate(m)
    |> result.map_error(fn(e) { "validate: " <> string.inspect(e) }),
  )
  Ok(Nil)
}

// ─────────────────────────────── instantiate ───────────────────────────────

/// Compile `.wasm` bytes to a loaded BEAM module (D10), then **instantiate** it in its
/// own OWNED PROCESS (E5: `load → instantiate → invoke`, one-instance-one-process). Each
/// module gets a UNIQUE name so loading many modules from one fixture cannot clobber one
/// another.
///
/// `ffi.start_instance` spawns a process and runs the generated `instantiate/0` IN it,
/// seeding that process's per-instance cell (fresh memory/table/globals + active
/// element/data segments + `start`) before any export is invoked. The returned
/// `Instance` carries the OWNING PID; every later `invoke` is routed into it so it reads
/// that instance's state, and a (re)instantiation spawns a fresh process → a fresh zeroed
/// cell (isolation + reset are automatic).
///
/// Returns `Error(reason)` — never a panic — for any stage that rejects: a compile-stage
/// rejection (`decode:`/`validate:`/`lower:`/`emit:`/`build:`, an out-of-scope construct →
/// a graceful skip) or, prefixed `instantiate: `, an INSTANTIATION-TIME TRAP (OOB active
/// segment / trapping `start`). The runner uses the prefix to tell the two apart.
pub fn instantiate(bytes: BitArray) -> Result(Instance, String) {
  use m <- result.try(
    decode.decode(bytes)
    |> result.map_error(fn(e) { "decode: " <> string.inspect(e) }),
  )
  use tm <- result.try(
    validate.validate(m)
    |> result.map_error(fn(e) { "validate: " <> string.inspect(e) }),
  )
  use irmod0 <- result.try(
    lower.lower(tm)
    |> result.map_error(fn(e) { "lower: " <> string.inspect(e) }),
  )
  let irmod = ir.Module(..irmod0, name: uniquify(irmod0.name))
  use cmod <- result.try(
    emit_core.emit_module(irmod, profiles.safe())
    |> result.map_error(fn(e) { "emit: " <> string.inspect(e) }),
  )
  let core_text = core_printer.print_module(cmod)
  use mod_atom <- result.try(
    build_beam.compile_and_load(bit_array.from_string(core_text))
    |> result.map_error(fn(e) { "build: " <> string.inspect(e) }),
  )
  // Spawn the instance's owned process and run `instantiate/0` in it (E5). An
  // instantiation-time trap surfaces here as `Error("instantiate: " <> reason)`, turning
  // the module's dependent assertions into skips — except `assert_uninstantiable`, which
  // the runner asserts MUST land here with the expected trap phrase.
  case ffi.start_instance(mod_atom) {
    Ok(proc) -> Ok(runner.Instance(proc: proc, exports: export_types(irmod)))
    Error(trap) -> Error("instantiate: " <> trap)
  }
}

/// Append a process-unique suffix to a module name so concurrent fixtures' modules do
/// not share a single BEAM module name (which `code:load_binary` would overwrite).
fn uniquify(name: String) -> String {
  name <> "_" <> int.to_string(ffi.unique_int())
}

/// Build the `export name → result value-types` table from the lowered IR module, so
/// `invoke` can tag a returned raw integer at the right width.
fn export_types(m: ir.Module) -> Dict(String, List(ir.ValType)) {
  let by_fn =
    list.fold(m.functions, dict.new(), fn(acc, f) {
      dict.insert(acc, f.name, f.result)
    })
  list.fold(m.exports, dict.new(), fn(acc, e) {
    case e {
      ir.ExportFn(export_name, fn_name) ->
        case dict.get(by_fn, fn_name) {
          Ok(results) -> dict.insert(acc, export_name, results)
          Error(_) -> acc
        }
    }
  })
}

// ─────────────────────────────── invoke ───────────────────────────────

/// Invoke export `field` on `inst` with `args`. Converts the spec args to raw integer
/// bits, applies `module:field/arity` (catching any trap), and tags the result.
///
/// - 0 results → `Returned([])` on a normal return (the value, if any, is ignored).
/// - 1 result → `Returned([tagged])` at the export's declared width.
/// - >1 results (multi-value) → `DriverError` (out of Phase-1 scope → a skip).
/// A trap / capability denial surfaces as `Trapped(reason_text)`.
pub fn invoke(
  inst: Instance,
  field: String,
  args: List(SpecValue),
) -> InvokeResult {
  case dict.get(inst.exports, field) {
    Error(_) -> runner.DriverError("no such export: " <> field)
    Ok(results) -> {
      let arg_ints = list.map(args, spec_to_raw)
      // Route the invoke INTO the instance's owned process so it reads that instance's
      // cell (one-instance-one-process). Cross-invoke state persists across these calls.
      case results {
        [] ->
          case ffi.call_instance(inst.proc, atom.create(field), arg_ints) {
            Ok(_) -> runner.Returned([])
            Error(t) -> runner.Trapped(t)
          }
        [ty] ->
          case ffi.call_instance(inst.proc, atom.create(field), arg_ints) {
            Ok(raw) -> runner.Returned([tag(ty, raw)])
            Error(t) -> runner.Trapped(t)
          }
        _ -> runner.DriverError("multi-value result unsupported")
      }
    }
  }
}

/// The raw integer bits an argument carries (NaN args, which the spec never uses, map
/// to 0).
fn spec_to_raw(v: SpecValue) -> Int {
  case v {
    I32Val(b) | I64Val(b) | F32Bits(b) | F64Bits(b) -> b
    F32Nan(_) | F64Nan(_) -> 0
  }
}

/// Tag a raw result integer as a `SpecValue` at the export's declared width. A WASM
/// numeric export only ever has `TI32/TI64/TF32/TF64` results; `TTerm` (the BEAM-value
/// layer, never produced by the Phase-1 WASM frontend) falls back to an i32 tag so the
/// function is total.
fn tag(ty: ir.ValType, raw: Int) -> SpecValue {
  case ty {
    ir.TI32 -> I32Val(raw)
    ir.TI64 -> I64Val(raw)
    ir.TF32 -> F32Bits(raw)
    ir.TF64 -> F64Bits(raw)
    ir.TTerm -> I32Val(raw)
  }
}
