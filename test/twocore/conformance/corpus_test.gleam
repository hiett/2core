//// The Phase-1 ACCEPTANCE CORPUS — the goal proof (overview §1, run by capstone 11).
////
//// Each authored `corpus/<name>.wat` is compiled to `<name>.wasm` and driven through
//// the REAL pipeline (decode → validate → lower → emit_core → build_beam → invoke on
//// the BEAM); results are checked against `corpus/<name>.expected`, whose numeric-edge
//// values are sourced from the spec `.wast` files / wasmtime (cited inside each file).
//// This is the end-to-end proof that 2core produces spec-correct BEAM code: the
//// arithmetic results, the two divide traps, the two's-complement wrap, the shift-count
//// masking, the signed/unsigned divide pair, the float value path, and the deny-all
//// `call_host` rejection.
////
//// Two acceptance items live as hand-built IR rather than `.wat`, because the Phase-1
//// WASM *decoder* does not yet decode them (a documented Phase-2 frontend gap), yet the
//// backend + runtime DO implement them and must be proven end-to-end through codegen:
////   - float ARITHMETIC (`f32.add`/`f64.add` → rt_num `FAdd`/`FMul`);
////   - the `call_host` capability boundary FIRING at run time (deny-all → a catchable
////     `{capability_denied, …}`), complementing the `.wat` host-import frontend rejection.

import gleam/bit_array
import gleam/erlang/atom.{type Atom}
import gleam/int
import gleam/list
import gleam/option
import gleam/result
import gleam/string
import twocore/backend/build_beam
import twocore/backend/core_printer
import twocore/backend/emit_core
import twocore/conformance/corpus.{type Expect, Rejects, Returns, Traps}
import twocore/conformance/driver
import twocore/conformance/ffi
import twocore/conformance/oracle
import twocore/conformance/runner.{type Driver}
import twocore/ir
import twocore/runtime/instance

const corpus_dir = "test/twocore/conformance/corpus"

// ─────────────────────────────── per-program acceptance ───────────────────────────────

/// `add` — direct numeric op + i32 two's-complement WRAP (add overflow, mul overflow).
pub fn add_corpus_test() {
  assert check_program("add") == []
}

/// `intops` — signed/unsigned divide pair, the div_s(INT_MIN,-1) overflow TRAP, the
/// div_u(_,0) divide-by-zero TRAP, and shift-count >= width masking — all through codegen.
pub fn intops_corpus_test() {
  assert check_program("intops") == []
}

/// `sum_to(n)` — loop/break/continue lowered to a constant-space tail-recursive BEAM loop.
pub fn sum_to_corpus_test() {
  assert check_program("sum_to") == []
}

/// `fib` — if + direct self-call + recursion.
pub fn fib_corpus_test() {
  assert check_program("fib") == []
}

/// `fac` — if + direct self-call + recursion (spec also bakes `fac` into `fac.wast`).
pub fn fac_corpus_test() {
  assert check_program("fac") == []
}

/// `floatops` — one f32 + one f64 program through the full WASM pipeline: float CONSTANTS
/// returned as raw IEEE-754 bits (D5) and trunc_sat float→int conversions (rt_num).
pub fn floatops_corpus_test() {
  assert check_program("floatops") == []
}

/// `hostimport` — a host import under deny-all is REJECTED end-to-end (fail-closed, D9/D4):
/// the module must not compile to a runnable instance.
pub fn hostimport_rejected_corpus_test() {
  assert check_program("hostimport") == []
}

// ─────────────────────────────── IR-sourced float arithmetic ───────────────────────────────

/// Float ARITHMETIC end-to-end through codegen (rt_num `FAdd`/`FMul`), from hand-built IR
/// since the Phase-1 decoder has no `f32.add` yet. Values flow as raw IEEE-754 bits (D5):
/// `f32.add(1.0, 2.0) == 3.0` is bits `1065353216 + 1073741824 -> 1077936128`; likewise
/// `f64.mul(1.5, 2.5) == 3.75` is `4609434218613702656 * 4612811918334230528 ->
/// 4615626668101337088` (raw f64 bits).
pub fn float_arithmetic_ir_e2e_test() {
  let mod = load_ir(float_arith_module())
  // f32.add(1.0, 2.0) == 3.0  (raw f32 bits)
  assert ffi.catch_apply(mod, atom.create("f32add"), [
      1_065_353_216,
      1_073_741_824,
    ])
    == Ok(1_077_936_128)
  // f64.mul(1.5, 2.5) == 3.75 (raw f64 bits)
  assert ffi.catch_apply(mod, atom.create("f64mul"), [
      4_609_434_218_613_702_656,
      4_612_811_918_334_230_528,
    ])
    == Ok(4_615_626_668_101_337_088)
}

/// The `call_host` capability boundary FIRES at run time under the Safe deny-all host:
/// a genuine host import raises a catchable `{capability_denied, …}` (fail-closed, D9).
/// This complements the `.wat` `hostimport` frontend rejection by exercising `rt_host`
/// itself end-to-end (the `.wat` path cannot reach it — the decoder drops imports).
pub fn call_host_denied_ir_e2e_test() {
  let mod = load_ir(host_import_module())
  let assert Error(reason) =
    ffi.catch_apply(mod, atom.create("useimport"), [123])
  assert string.contains(reason, "capability_denied")
}

// ─────────────────────────────── driving machinery ───────────────────────────────

/// Run a `corpus/<name>` program through the real driver and return the list of failure
/// descriptions (empty ⇒ every expectation held). A `reject` program asserts the module
/// fails to instantiate; otherwise the module instantiates once and each expectation is
/// invoked and compared.
fn check_program(name: String) -> List(String) {
  let d = driver.pipeline()
  let assert Ok(bytes) = read_bytes(name <> ".wasm")
  let assert Ok(text) = read_text(name <> ".expected")
  let assert Ok(expects) = corpus.parse(text)

  case expects {
    [Rejects] ->
      case d.instantiate(bytes) {
        Error(_) -> []
        Ok(_) -> [name <> ": expected REJECT, but the module instantiated"]
      }
    _ ->
      case d.instantiate(bytes) {
        Error(e) -> [name <> ": module failed to instantiate: " <> e]
        Ok(inst) ->
          list.filter_map(expects, fn(ex) {
            case run_expect(d, inst, ex) {
              Ok(Nil) -> Error(Nil)
              Error(msg) -> Ok(name <> ": " <> msg)
            }
          })
      }
  }
}

fn run_expect(d: Driver, inst, ex: Expect) -> Result(Nil, String) {
  case ex {
    Rejects -> Error("unexpected 'reject' among value expectations")
    Returns(field, args, results) ->
      case d.invoke(inst, field, args) {
        runner.Returned(actual) ->
          case oracle.matches_all(actual, results) {
            True -> Ok(Nil)
            False ->
              Error(
                field
                <> ": got "
                <> string.inspect(actual)
                <> " want "
                <> string.inspect(results),
              )
          }
        runner.Trapped(r) -> Error(field <> ": expected return, trapped " <> r)
        runner.DriverError(x) -> Error(field <> ": driver error " <> x)
      }
    Traps(field, args, text) ->
      case d.invoke(inst, field, args) {
        runner.Trapped(r) ->
          case runner.trap_matches(r, text) {
            True -> Ok(Nil)
            False ->
              Error(
                field <> ": trapped " <> r <> " want substring '" <> text <> "'",
              )
          }
        runner.Returned(v) ->
          Error(
            field
            <> ": expected trap '"
            <> text
            <> "', returned "
            <> string.inspect(v),
          )
        runner.DriverError(x) -> Error(field <> ": driver error " <> x)
      }
  }
}

fn read_bytes(file: String) -> Result(BitArray, String) {
  ffi.read_file(corpus_dir <> "/" <> file)
}

fn read_text(file: String) -> Result(String, String) {
  use bytes <- result.try(ffi.read_file(corpus_dir <> "/" <> file))
  bit_array.to_string(bytes) |> result.replace_error("non-UTF8 .expected")
}

// ─────────────────────────────── hand-built IR helpers ───────────────────────────────

/// Emit `m` to Core text, compile + load it into the test VM, return the module atom.
/// A failure here is a genuine test failure (the backend should compile valid IR).
fn load_ir(m: ir.Module) -> Atom {
  let assert Ok(cmod) = emit_core.emit_module(m, instance.safe_default())
  let core = core_printer.print_module(cmod)
  let assert Ok(mod) = build_beam.compile_and_load(bit_array.from_string(core))
  mod
}

fn numeric_module(name: String, fns: List(ir.Function)) -> ir.Module {
  ir.Module(
    name: "twocore@corpus@" <> name <> "_" <> int.to_string(ffi.unique_int()),
    uses_numerics: True,
    memory: option.None,
    globals: [],
    imports: [],
    functions: fns,
    exports: list.map(fns, fn(f) { ir.ExportFn(f.name, f.name) }),
    data_segments: [],
    tables: [],
    elements: [],
    start: option.None,
  )
}

fn float_arith_module() -> ir.Module {
  let f32add =
    ir.Function(
      name: "f32add",
      params: [ir.Local("p0", ir.TF32), ir.Local("p1", ir.TF32)],
      result: [ir.TF32],
      locals: [],
      body: ir.Let(
        ["r"],
        ir.Num(ir.FAdd(ir.FW32), [ir.Var("p0"), ir.Var("p1")]),
        ir.Return([ir.Var("r")]),
      ),
    )
  let f64mul =
    ir.Function(
      name: "f64mul",
      params: [ir.Local("p0", ir.TF64), ir.Local("p1", ir.TF64)],
      result: [ir.TF64],
      locals: [],
      body: ir.Let(
        ["r"],
        ir.Num(ir.FMul(ir.FW64), [ir.Var("p0"), ir.Var("p1")]),
        ir.Return([ir.Var("r")]),
      ),
    )
  numeric_module("float", [f32add, f64mul])
}

fn host_import_module() -> ir.Module {
  let f =
    ir.Function(
      name: "useimport",
      params: [ir.Local("p0", ir.TI32)],
      result: [ir.TI32],
      locals: [],
      body: ir.Let(
        ["r"],
        ir.CallHost("env", "forbidden", [ir.Var("p0")]),
        ir.Return([ir.Var("r")]),
      ),
    )
  numeric_module("host", [f])
}
