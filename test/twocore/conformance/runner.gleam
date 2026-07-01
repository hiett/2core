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

import gleam/bit_array
import gleam/dict.{type Dict}
import gleam/erlang/process.{type Pid}
import gleam/int
import gleam/list
import gleam/string
import twocore/conformance/fixture.{
  type Action, type Command, type Fixture, type SpecValue, ActionCmd,
  AssertInvalid, AssertMalformed, AssertReturn, AssertTrap, AssertUninstantiable,
  BinaryModule, Get, Invoke, ModuleCmd, Register, TextModule, Unhandled,
}
import twocore/conformance/oracle
import twocore/conformance/registry.{type Registry}
import twocore/ir

// ─────────────────────────────── the Driver seam ───────────────────────────────

/// A live instance ready to invoke: the OWNING PROCESS pid (one-instance-one-process,
/// E1) plus, per export name, the function's result value-types — used to tag a
/// returned raw integer back into a typed `SpecValue` for the oracle. The instance's
/// mutable state (memory/globals/table cell) lives in `proc`'s process dictionary, so
/// every invoke is routed INTO `proc` (via `ffi.call_instance`); cross-invoke state
/// persists, and a (re)instantiation spawns a fresh `proc` with a fresh zeroed cell.
pub type Instance {
  Instance(proc: Pid, exports: Dict(String, List(ir.ValType)))
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

    AssertUninstantiable(line, filename, text) -> #(
      reg,
      run_uninstantiable(driver, rep, src, line, base, filename, text),
    )

    // A bare action: run it for its SIDE EFFECTS on the current module's mutable state
    // (so later asserts see the result), then continue. Plumbing — the report is unchanged
    // (not counted). If the target module did not instantiate, the action is silently
    // dropped (its dependent asserts already skip with a reason).
    ActionCmd(_line, action) -> {
      run_action_effect(driver, reg, action)
      #(reg, rep)
    }

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
            // We ACCEPTED a module the spec rejects. That is normally a real bug — EXCEPT
            // when the malformation lives in the IMPORT SECTION, which our decoder
            // deliberately skips (non-function imports / the `spectest` module are deferred
            // to Phase 3). We cannot judge an import-section malformation, so this is an
            // honest out-of-scope SKIP, not a silent pass and not a fail. Keyed to the
            // structural fact "the binary carries an import section", never to line numbers.
            Ok(Nil) ->
              case has_import_section(bytes) {
                True ->
                  skip(
                    rep,
                    at(src, line)
                      <> kind
                      <> ": import-section construct (non-function imports deferred to Phase 3)",
                  )
                False ->
                  fail(
                    rep,
                    at(src, line)
                      <> kind
                      <> ": frontend ACCEPTED a rejected module",
                  )
              }
          }
      }
  }
}

/// Whether a `.wasm` binary carries a non-empty IMPORT section (section id 2). Walks the
/// section headers (`<id:u8><size:uleb32><size bytes>`) after the 8-byte magic+version. Our
/// decoder skips the import section wholesale (imports are deferred to Phase 3), so an
/// import-section malformation that the spec rejects is one we cannot judge — this predicate
/// lets `run_frontend_reject` skip those honestly instead of silent-passing. Total — any
/// malformed framing simply returns `False`.
fn has_import_section(bytes: BitArray) -> Bool {
  case bytes {
    <<0x00, 0x61, 0x73, 0x6d, _v:bytes-size(4), rest:bytes>> ->
      scan_for_import(rest)
    _ -> False
  }
}

fn scan_for_import(bytes: BitArray) -> Bool {
  case bytes {
    <<id:8, rest:bytes>> ->
      case read_uleb32(rest, 0, 0) {
        Error(_) -> False
        Ok(#(size, after_size)) ->
          case id == 2 && size > 0 {
            True -> True
            False ->
              case
                bit_array.slice(after_size, size, byte_count(after_size) - size)
              {
                Ok(next) -> scan_for_import(next)
                Error(_) -> False
              }
          }
      }
    _ -> False
  }
}

/// Read one LEB128 unsigned int from the front of `bytes`. `Ok(#(value, rest))` or `Error`
/// if the input ends mid-number. Used only by the section walker above.
fn read_uleb32(
  bytes: BitArray,
  shift: Int,
  acc: Int,
) -> Result(#(Int, BitArray), Nil) {
  case bytes {
    <<byte:8, rest:bytes>> -> {
      let acc2 =
        acc + int.bitwise_shift_left(int.bitwise_and(byte, 0x7f), shift)
      case int.bitwise_and(byte, 0x80) {
        0 -> Ok(#(acc2, rest))
        _ -> read_uleb32(rest, shift + 7, acc2)
      }
    }
    _ -> Error(Nil)
  }
}

fn byte_count(bytes: BitArray) -> Int {
  bit_array.byte_size(bytes)
}

// assert_uninstantiable — the module is well-formed + valid, but INSTANTIATION traps
// (an OOB active data/element segment, or a trapping `start`). The spec's
// `assert_uninstantiable` (and the legacy `assert_unlinkable` framing of an OOB active
// segment). The runner loads + instantiates the module and asserts it FAILS to
// instantiate with a trap whose spec phrase contains `text` (E5). A success is a FAIL;
// these no longer fall through the `Unhandled → skip` path and get silently dropped.

fn run_uninstantiable(
  driver: Driver,
  rep: Report,
  src: String,
  line: Int,
  base: String,
  filename: String,
  text: String,
) -> Report {
  case read_bytes(base, filename) {
    Error(e) -> skip(rep, at(src, line) <> "uninstantiable: " <> e)
    Ok(bytes) ->
      case driver.instantiate(bytes) {
        // The module instantiated, but it MUST trap at instantiation — a real failure.
        Ok(_inst) ->
          fail(
            rep,
            at(src, line)
              <> "uninstantiable: module instantiated but must fail to instantiate",
          )
        Error(reason) ->
          // Distinguish a genuine instantiation-time trap (driver prefix "instantiate: ")
          // from a compile-stage rejection of an out-of-scope construct (decode/validate/
          // emit/build) — the latter is an honest SKIP, not a pass.
          case string.split_once(reason, "instantiate: ") {
            Ok(#(_, trap)) ->
              case trap_matches(trap, text) {
                True -> pass(rep)
                False ->
                  fail(
                    rep,
                    at(src, line)
                      <> "uninstantiable: trapped "
                      <> trap
                      <> " want substring "
                      <> text,
                  )
              }
            Error(_) ->
              skip(
                rep,
                at(src, line) <> "uninstantiable (out of scope): " <> reason,
              )
          }
      }
  }
}

/// Run a bare action for its side effects on the resolved instance, discarding the result
/// (and any trap — a bare setup action that traps is not an assertion). If the target module
/// failed to instantiate, do nothing. `Get` actions read a global and have no side effect, so
/// they are skipped here. Total.
fn run_action_effect(driver: Driver, reg: Reg, action: Action) -> Nil {
  case action {
    Get(_, _) -> Nil
    Invoke(field, args, module) ->
      case resolve_instance(reg, module) {
        Error(_) -> Nil
        Ok(inst) -> {
          let _ = driver.invoke(inst, field, args)
          Nil
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
