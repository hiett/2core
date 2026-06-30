//// The spec-suite runner — drives a fixture's commands through 2core and judges the
//// results with the oracle, split BY COMMAND TYPE up front (the partition fact).
////
//// PARTITION (VERIFIED):
////  - `assert_invalid` (typecheck) / `assert_malformed` (decode) exercise the FRONTEND
////    ONLY — they go to `Driver.check_frontend` and the runner asserts a typed `Error`
////    (fail-closed, D4). They are NEVER instantiated (the backend / a real engine would
////    reject them for the wrong reasons).
////  - `assert_return` / `assert_trap` exercise the FULL PIPELINE — `Driver.instantiate`
////    then `Driver.invoke`, compared via the oracle.
////
//// HONEST COVERAGE (D9): the allowlisted spec files contain instructions beyond the
//// Phase-1 slice (floats, memory, multi-value, …). The runner SKIPS gracefully — a
//// module that fails to instantiate (our typed `Unsupported`/error) turns all its
//// assertions into SKIPS with a reason, never a fail — and the `Report` carries
//// pass/fail/skip counts plus the reasons, so a skip is visible, not silent.
////
//// The runner is parameterised over a `Driver` so the harness is independent of the
//// pipeline: a stub `Driver` lets the parsing/oracle be tested with no compiler, and
//// the real pipeline `Driver` (see `driver.gleam`) makes the full-pipeline assertions
//// run for real.

import gleam/dict.{type Dict}
import gleam/erlang/atom.{type Atom}
import gleam/int
import gleam/list
import gleam/string
import twocore/conformance/fixture.{
  type Action, type Command, type Fixture, type SpecValue, AssertInvalid,
  AssertMalformed, AssertReturn, AssertTrap, BinaryModule, Get, Invoke,
  ModuleCmd, Register, TextModule, Unhandled,
}
import twocore/conformance/oracle
import twocore/conformance/registry.{type Registry}
import twocore/ir

// ─────────────────────────────── the Driver seam ───────────────────────────────

/// A loaded module ready to invoke: the BEAM module name (atom) plus, per export
/// name, the function's result value-types — used to tag a returned raw integer back
/// into a typed `SpecValue` for the oracle.
pub type Instance {
  Instance(module: Atom, exports: Dict(String, List(ir.ValType)))
}

/// The outcome of invoking an export.
///
/// - `Returned(values)`: a normal return; `values` carry the raw result bits tagged at
///   the export's declared width.
/// - `Trapped(reason)`: a runtime trap / capability denial, `reason` the raw text
///   (e.g. `"{wasm_trap,int_div_by_zero}"`) — mapped to the spec message by the runner.
/// - `DriverError(text)`: a pipeline/invoke failure DISTINCT from a spec trap (e.g. an
///   unsupported multi-value result) — the runner treats it as a skip, not a fail.
pub type InvokeResult {
  Returned(List(SpecValue))
  Trapped(reason: String)
  DriverError(String)
}

/// The seam between the harness and the compiler. Split by command type:
/// `check_frontend` is decode+validate ONLY (for `assert_invalid`/`assert_malformed`);
/// `instantiate`+`invoke` are the full pipeline (for `assert_return`/`assert_trap`).
pub type Driver {
  Driver(
    /// Decode + validate ONLY. `Ok(Nil)` = accepted; `Error(reason)` = rejected.
    check_frontend: fn(BitArray) -> Result(Nil, String),
    /// Full pipeline: `.wasm` bytes → loaded `.beam` `Instance` (D10).
    instantiate: fn(BitArray) -> Result(Instance, String),
    /// Run an export with raw args; see `InvokeResult`.
    invoke: fn(Instance, String, List(SpecValue)) -> InvokeResult,
  )
}

// ─────────────────────────────── the report ───────────────────────────────

/// A pass/fail/skip tally plus the human-readable reasons for the fails and skips, so
/// honest coverage is visible (D9). `pass`+`fail`+`skip` counts ASSERTION commands
/// (module/register commands are plumbing, not counted).
pub type Report {
  Report(
    pass: Int,
    fail: Int,
    skip: Int,
    fails: List(String),
    skips: List(String),
  )
}

/// An empty report (the fold seed).
pub fn empty_report() -> Report {
  Report(pass: 0, fail: 0, skip: 0, fails: [], skips: [])
}

/// Sum two reports (for aggregating across fixtures). Reason lists are concatenated.
pub fn merge(a: Report, b: Report) -> Report {
  Report(
    pass: a.pass + b.pass,
    fail: a.fail + b.fail,
    skip: a.skip + b.skip,
    fails: list.append(a.fails, b.fails),
    skips: list.append(a.skips, b.skips),
  )
}

fn pass(r: Report) -> Report {
  Report(..r, pass: r.pass + 1)
}

fn fail(r: Report, why: String) -> Report {
  Report(..r, fail: r.fail + 1, fails: [why, ..r.fails])
}

fn skip(r: Report, why: String) -> Report {
  Report(..r, skip: r.skip + 1, skips: [why, ..r.skips])
}

// ─────────────────────────────── driving a fixture ───────────────────────────────

/// Drive every command in `fix` through `driver`, resolving `.wasm`/`.wat` paths
/// relative to `base_dir` (the directory the fixture's files live in). Returns the
/// `Report`. Total — every command either passes, fails (with a reason), or skips
/// (with a reason); the runner never panics.
pub fn run_fixture(driver: Driver, fix: Fixture, base_dir: String) -> Report {
  let #(_reg, report) =
    list.fold(fix.commands, #(registry.new(), empty_report()), fn(state, cmd) {
      let #(reg, rep) = state
      run_command(driver, reg, rep, fix.source_filename, base_dir, cmd)
    })
  // Reasons were accumulated reversed; restore source order for readable output.
  Report(
    ..report,
    fails: list.reverse(report.fails),
    skips: list.reverse(report.skips),
  )
}

// The registry stores each module's INSTANTIATION RESULT, so a module that failed to
// load (an unsupported construct) cleanly turns its dependent assertions into skips.
type Reg =
  Registry(Result(Instance, String))

fn run_command(
  driver: Driver,
  reg: Reg,
  rep: Report,
  src: String,
  base: String,
  cmd: Command,
) -> #(Reg, Report) {
  case cmd {
    ModuleCmd(_line, name, filename) -> {
      let res = load_wasm(base, filename, driver.instantiate)
      #(registry.define(reg, name, res), rep)
    }

    Register(_line, as_name, module) ->
      case registry.register(reg, as_name, module) {
        Ok(reg2) -> #(reg2, rep)
        Error(e) -> #(reg, skip(rep, at(src, 0) <> "register: " <> e))
      }

    AssertReturn(line, action, expected) -> #(
      reg,
      run_return(driver, reg, rep, src, line, action, expected),
    )

    AssertTrap(line, action, text) -> #(
      reg,
      run_trap(driver, reg, rep, src, line, action, text),
    )

    AssertInvalid(line, filename, mt, _text) -> #(
      reg,
      run_frontend_reject(driver, rep, src, line, base, filename, mt, "invalid"),
    )

    AssertMalformed(line, filename, mt, _text) -> #(
      reg,
      run_frontend_reject(
        driver,
        rep,
        src,
        line,
        base,
        filename,
        mt,
        "malformed",
      ),
    )

    Unhandled(line, kind) -> #(
      reg,
      skip(rep, at(src, line) <> "unhandled command: " <> kind),
    )
  }
}

// assert_return / assert_trap — FULL pipeline.

fn run_return(
  driver: Driver,
  reg: Reg,
  rep: Report,
  src: String,
  line: Int,
  action: Action,
  expected: List(SpecValue),
) -> Report {
  case action {
    Get(_, _) ->
      skip(rep, at(src, line) <> "get action unsupported (no globals)")
    Invoke(field, args, module) ->
      case resolve_instance(reg, module) {
        Error(why) -> skip(rep, at(src, line) <> why)
        Ok(inst) ->
          case driver.invoke(inst, field, args) {
            Returned(actuals) ->
              case oracle.matches_all(actuals, expected) {
                True -> pass(rep)
                False ->
                  fail(
                    rep,
                    at(src, line)
                      <> field
                      <> ": got "
                      <> string.inspect(actuals)
                      <> " want "
                      <> string.inspect(expected),
                  )
              }
            Trapped(r) ->
              fail(
                rep,
                at(src, line) <> field <> ": expected return, trapped " <> r,
              )
            DriverError(d) ->
              skip(rep, at(src, line) <> field <> ": driver: " <> d)
          }
      }
  }
}

fn run_trap(
  driver: Driver,
  reg: Reg,
  rep: Report,
  src: String,
  line: Int,
  action: Action,
  text: String,
) -> Report {
  case action {
    Get(_, _) ->
      skip(rep, at(src, line) <> "get action unsupported (no globals)")
    Invoke(field, args, module) ->
      case resolve_instance(reg, module) {
        Error(why) -> skip(rep, at(src, line) <> why)
        Ok(inst) ->
          case driver.invoke(inst, field, args) {
            Trapped(r) ->
              case trap_matches(r, text) {
                True -> pass(rep)
                False ->
                  fail(
                    rep,
                    at(src, line)
                      <> field
                      <> ": trapped "
                      <> r
                      <> " want substring "
                      <> text,
                  )
              }
            Returned(vs) ->
              fail(
                rep,
                at(src, line)
                  <> field
                  <> ": expected trap '"
                  <> text
                  <> "', returned "
                  <> string.inspect(vs),
              )
            DriverError(d) ->
              skip(rep, at(src, line) <> field <> ": driver: " <> d)
          }
      }
  }
}

// assert_invalid / assert_malformed — FRONTEND ONLY.

fn run_frontend_reject(
  driver: Driver,
  rep: Report,
  src: String,
  line: Int,
  base: String,
  filename: String,
  mt: fixture.ModuleType,
  kind: String,
) -> Report {
  case mt {
    // A text-format case references a `.wat`; there is no Phase-1 WAT parser.
    TextModule ->
      skip(rep, at(src, line) <> kind <> ": text module_type (no WAT parser)")
    BinaryModule ->
      case read_bytes(base, filename) {
        Error(e) -> skip(rep, at(src, line) <> kind <> ": " <> e)
        Ok(bytes) ->
          // Fail-closed: an invalid/malformed module MUST be rejected by the frontend.
          case driver.check_frontend(bytes) {
            Error(_) -> pass(rep)
            Ok(Nil) ->
              fail(
                rep,
                at(src, line) <> kind <> ": frontend ACCEPTED a rejected module",
              )
          }
      }
  }
}

// ─────────────────────────────── helpers ───────────────────────────────

fn resolve_instance(reg: Reg, module) -> Result(Instance, String) {
  case registry.resolve(reg, module) {
    Error(e) -> Error(e)
    Ok(Error(why)) -> Error("module did not instantiate: " <> why)
    Ok(Ok(inst)) -> Ok(inst)
  }
}

fn load_wasm(
  base: String,
  filename: String,
  instantiate: fn(BitArray) -> Result(Instance, String),
) -> Result(Instance, String) {
  case read_bytes(base, filename) {
    Error(e) -> Error(e)
    Ok(bytes) -> instantiate(bytes)
  }
}

fn read_bytes(base: String, filename: String) -> Result(BitArray, String) {
  let path = base <> "/" <> filename
  case ffi_read(path) {
    Error(e) -> Error("read " <> path <> ": " <> e)
    Ok(b) -> Ok(b)
  }
}

@external(erlang, "twocore_conformance_ffi", "read_file")
fn ffi_read(path: String) -> Result(BitArray, String)

fn at(src: String, line: Int) -> String {
  src <> ":" <> int.to_string(line) <> " "
}

/// Decide whether our runtime trap `reason` text satisfies the spec's expected message
/// `want`. The spec message is a SUBSTRING like `"integer divide by zero"`; our runtime
/// raises `{wasm_trap, <kind>}` where `<kind>` is the snake_case `TrapReason` atom. We
/// map our kind to the canonical spec phrase (per `rt_trap.spec_trap_message`) and then
/// check containment. (`want == ""` accepts any trap.)
pub fn trap_matches(reason: String, want: String) -> Bool {
  case want {
    "" -> True
    _ ->
      case spec_phrase_of(reason) {
        Ok(phrase) ->
          string.contains(phrase, want) || string.contains(want, phrase)
        // Unknown trap kind: fall back to raw containment (lenient but still honest).
        Error(_) -> string.contains(reason, want)
      }
  }
}

/// Map our raised `{wasm_trap, <kind>}` text to the WASM-spec trap-message phrase, keyed by
/// the snake_case `TrapReason` atom present in `reason`. Mirrors `rt_trap.spec_trap_message`
/// (the single source of truth) so Phase-2 memory / table / conversion traps are judged
/// against their spec messages — not the underscore atom. The most-specific atoms are tested
/// FIRST so e.g. `undefined_element` is not shadowed by a substring match.
fn spec_phrase_of(reason: String) -> Result(String, Nil) {
  let kinds = [
    #("int_div_by_zero", "integer divide by zero"),
    #("invalid_conversion_to_integer", "invalid conversion to integer"),
    #("int_overflow", "integer overflow"),
    #("memory_out_of_bounds", "out of bounds memory access"),
    #("table_out_of_bounds", "out of bounds table access"),
    #("indirect_call_type_mismatch", "indirect call type mismatch"),
    #("uninitialized_element", "uninitialized element"),
    #("undefined_element", "undefined element"),
    #("unreachable", "unreachable"),
  ]
  list.find_map(kinds, fn(kv) {
    let #(atom_text, phrase) = kv
    case string.contains(reason, atom_text) {
      True -> Ok(phrase)
      False -> Error(Nil)
    }
  })
}
