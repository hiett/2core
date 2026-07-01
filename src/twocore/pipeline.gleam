//// Top-level driver glue (unit 11c completes unit 01's stub). Per-stage errors (D4)
//// compose **here**, at the driver boundary; there is **no single shared `StageError`**.
////
//// Each pipeline stage owns its own error type (`decode.DecodeError`,
//// `validate.ValidateError`, `lower.LowerError`, `ir_lower.LowerError`,
//// `emit_core.EmitError`, `build_beam.BuildError`). This module maps each into a
//// `PipelineError` variant at exactly ONE seam, and exposes the composable stage-driver
//// functions the CLI (`twocore.gleam`) and the acceptance harness (`11d`) both call — so
//// the error mapping and stage wiring live in one place, not scattered.
////
//// ## The run/invoke ABI (FIXED CONTRACT — `07`'s oracle marshals to it)
////
//// `RunResult`/`invoke` are how a compiled export is called from the BEAM (D10):
//// - **Arguments and results are raw unsigned bit patterns as Erlang integers** — an i32
////   in `[0, 2^32)`, an i64 in `[0, 2^64)` (an i64 is an ordinary BEAM bignum; nothing
////   special past 60 bits). Floats marshal as their raw IEEE-754 bit pattern, also an
////   integer (D5 — never a BEAM double).
//// - A **trap** surfaces as a BEAM exception raised by `rt_trap`; `invoke` catches it (via
////   the `twocore_cli_ffi` catching-apply seam) and returns `Trapped(reason)`. The deny-all
////   host rejection surfaces the same way (a catchable `{capability_denied, …}`), so an
////   acceptance test asserts a *rejection*, not a normal return.
////
//// > **Deviation from the frozen doc, flagged:** the doc's `RunResult.Trapped` carried an
//// > `ir.TrapReason`. Unit 07 actually landed with a String-reason trap channel
//// > (`runner.InvokeResult.Trapped(reason: String)`), and a deny-all capability denial is
//// > NOT an `ir.TrapReason`. To reuse 07 unchanged AND represent both wasm traps and
//// > capability denials honestly, `Trapped` here carries the raw reason **String** (the
//// > spec-phrase match is done by `07`'s `runner.trap_matches`). The argument/result
//// > integer-bit-pattern contract is unchanged.
////
//// See `specs/phase-1/00-overview.md` D4 and `specs/phase-1/11-ir-lower-linker-cli.md`.
////
//// ## Phase-4 binding-threading LOCK (unit P4-08 §A.1 — no new stage, no new axis reach)
////
//// Phase 4 adds **no new pipeline stage, no new IR node, and no new `PipelineError`
//// variant** (G7). The two Phase-4 axes — `state_strategy` (`Cell`/`Threaded`) and
//// `mem_tier`/`table_tier` (`Paged`/`Atomics`/`Nif` · …) — are **build-time fields on the
//// one `Binding`** that already threads through every stage. The pipeline runs the **same
//// five stages in the same order** regardless of them:
////   `source_to_ir → lower_ir → optimize_ir → ir_to_core (emit_core) → core_to_beam`.
//// **No stage branches on a Phase-4 axis.** The axes are consumed at exactly two points, both
//// downstream of the stage graph:
////   - **codegen** — `emit_core` reads `binding.state_strategy` (the one codegen-shape switch:
////     the `Cell` pdict seam vs the `Threaded` record-threading seam) and the linker-resolved
////     `binding.mem_module`/`table_module`/`state_module` **module names** (never `mem_tier`/
////     `table_tier` — the tier is a build-time module swap the emitter never sees, G5); and
////   - **run time** — the linked `twocore@runtime@rt_*` module implements the chosen tier.
//// A tier/strategy **mismatch** is a *linker* rejection (`profiles.validate_binding`/`link`),
//// surfaced **before** the pipeline runs (at the CLI's `resolve_binding`, `twocore.gleam`) —
//// **not** a pipeline-stage error. So adding a tier is a runtime-module + `Binding`-field job,
//// **never a pipeline edit**; this module threads the chosen `Binding` unchanged.
////
//// ## The strategy-aware run-ABI (unit P4-08 §C — signature-stable, self-detecting)
////
//// `instantiate`/`invoke_instance`/`run_source` do **not** gain a `Binding` parameter. The
//// owned process (`twocore_cli_ffi.erl`) discriminates the state strategy from
//// `instantiate/0`'s **return value** (unambiguous by the keystone shapes): the atom `'ok'`
//// → the `Cell` loop (apply `Fun(Args)`, state in the pdict cell); the `InstanceState` record
//// `{instance_state,_,_,_}` → the `Threaded` loop (apply `Fun(St, Args…) -> {Package, St'}`,
//// threading `St'` across invokes as a value). The `Cell` path is byte-identical to Phase 2/3;
//// a `Threaded`/`atomics` build runs the SAME driver code end-to-end (G7).

import gleam/bit_array
import gleam/erlang/atom.{type Atom}
import gleam/erlang/process.{type Pid}
import gleam/string
import twocore/backend/build_beam
import twocore/backend/core_printer
import twocore/backend/emit_core
import twocore/frontend/wasm/ast
import twocore/frontend/wasm/decode
import twocore/frontend/wasm/lower
import twocore/frontend/wasm/validate
import twocore/ir
import twocore/ir/parser as ir_parser
import twocore/middle/ir_lower
import twocore/middle/ir_opt
import twocore/runtime/instance.{type Binding}

// ─────────────────────────────── composed error type (D4) ───────────────────────────────

/// The union of every stage's error, assembled at the driver boundary. Each variant WRAPS
/// the failing stage's OWN error type (D4) — there is no shared `StageError`. A
/// `Result(_, PipelineError)` is `Error(variant)` iff that named stage rejected the input
/// (fail-closed) — never a panic.
///
/// Variants (in pipeline order):
/// - `DecodeFailed`: the WASM binary decoder rejected the bytes (unit 05).
/// - `ValidateFailed`: the `full` validator rejected the module (unit 10a).
/// - `FrontendLowerFailed`: WASM-AST → IR lowering failed (unit 10b).
/// - `IrLowerFailed`: the IR→IR Safe policy pass rejected a `CallHost` (unit 11a).
/// - `EmitFailed`: `emit_core` could not produce Core Erlang (unit 08).
/// - `BuildFailed`: the Core Erlang → `.beam` build/load step failed (unit 04).
pub type PipelineError {
  DecodeFailed(ast.DecodeError)
  ValidateFailed(validate.ValidateError)
  FrontendLowerFailed(lower.LowerError)
  IrLowerFailed(ir_lower.LowerError)
  EmitFailed(emit_core.EmitError)
  BuildFailed(build_beam.BuildError)
}

/// A short, human-readable rendering of a `PipelineError` (which stage + the wrapped error)
/// for CLI stderr. Total — never panics. The text is diagnostic only; programmatic callers
/// should match the variant, not parse this string.
pub fn describe(error: PipelineError) -> String {
  case error {
    DecodeFailed(e) -> "decode: " <> string.inspect(e)
    ValidateFailed(e) -> "validate: " <> string.inspect(e)
    FrontendLowerFailed(e) -> "lower: " <> string.inspect(e)
    IrLowerFailed(e) -> "ir-lower: " <> string.inspect(e)
    EmitFailed(e) -> "emit: " <> string.inspect(e)
    BuildFailed(e) -> "build: " <> string.inspect(e)
  }
}

// ─────────────────────────────── the run/invoke ABI ───────────────────────────────

/// The outcome of invoking a compiled export on the BEAM.
///
/// - `Returned(values)`: a normal return; `values` are the raw result bit patterns as
///   integers (Phase-1 exports are single-result, so length 1).
/// - `Trapped(reason)`: a runtime trap or capability denial — the catchable BEAM error
///   reason rendered as text (e.g. `"{wasm_trap,int_div_by_zero}"`,
///   `"{capability_denied,env,forbidden}"`). The caller maps it to the spec phrase.
pub type RunResult {
  Returned(values: List(Int))
  Trapped(reason: String)
}

/// Load `beam` into the build VM (D10) and apply `export`/`length(args)` IN THE CALLING
/// PROCESS, catching any trap. This is the same-process one-shot: the apply runs in the
/// caller's process, so a process-dictionary effect (e.g. `rt_meter` fuel) is observable by
/// the caller afterwards. It does NOT call `instantiate/0`, so it is only correct for PURE
/// modules (no memory/globals/tables); stateful modules must go through the
/// `instantiate → invoke_instance` process ABI below (E5). Retained for the fuel-measuring
/// `ir_lower` tests, which require same-process execution.
///
/// - `beam`: the compiled `.beam` binary (from `core_to_beam`).
/// - `mod`: the module's atom NAME (the name baked into the `.core`, i.e. `ir.Module.name`).
/// - `export`: the exported function name to apply.
/// - `args`: the call arguments as raw unsigned bit-pattern integers (see the ABI above).
///
/// Returns `Returned([value])` on a normal single-result return, or `Trapped(reason)` if the
/// call raises (a trap or a deny-all capability denial), or if loading the binary fails
/// (`Trapped("load failed: …")`). Total — never panics.
pub fn invoke(
  beam: BitArray,
  mod: String,
  export: String,
  args: List(Int),
) -> RunResult {
  case build_beam.load_module(atom.create(mod), "twocore_cli", beam) {
    Error(reason) -> Trapped("load failed: " <> reason)
    Ok(mod_atom) ->
      case ffi_catch_apply(mod_atom, atom.create(export), args) {
        Ok(value) -> Returned([value])
        Error(reason) -> Trapped(reason)
      }
  }
}

/// A live instance: the OWNING PROCESS that ran `instantiate/0` and holds this instance's
/// per-instance state (one-instance-one-process, E1). Every `invoke_instance` is routed into
/// it, so each invoke reads this instance's state and cross-invoke state persists.
///
/// The process holds the state per the build's `state_strategy` (self-detected by the shim,
/// unit P4-08 §C.2): under `Cell` in its **process-dictionary cell**; under `Threaded` as the
/// **`InstanceState` record carried as a loop variable** (threaded across invokes as a value,
/// never in the pdict). This handle is opaque to that choice — the run-ABI signature is the
/// same for both.
pub opaque type InstanceProc {
  InstanceProc(proc: Pid)
}

/// **Instantiate** a loaded module in its own OWNED PROCESS (the run-ABI's middle step,
/// E5: `load → instantiate → invoke`). Loads `beam` ONCE into the build VM, then spawns a
/// process and runs the generated `instantiate/0` IN it — building that process's fresh
/// per-instance state (memory/table/globals + active element/data segments + `start`).
///
/// **Strategy-aware, signature-stable (unit P4-08 §C):** the shim discriminates the build's
/// `state_strategy` from `instantiate/0`'s return — the atom `'ok'` (`Cell`, seeds the pdict
/// cell) vs the `InstanceState` record (`Threaded`, held as the process's loop variable) — so
/// this function needs **no** `Binding` parameter and both strategies share one code path.
///
/// - `beam`: the compiled `.beam` binary (from `core_to_beam`).
/// - `mod`: the module's atom NAME (must match the name baked into the `.core`).
/// - Returns `Ok(InstanceProc)` once the state is seeded and the process is ready for
///   `invoke_instance`; `Error("load failed: …")` if the binary will not load; or
///   `Error(reason)` for an INSTANTIATION-TIME TRAP (an OOB active segment / trapping
///   `start`) — surfaced identically to a runtime trap. Total — never panics.
pub fn instantiate(
  beam: BitArray,
  mod: String,
) -> Result(InstanceProc, String) {
  case build_beam.load_module(atom.create(mod), "twocore_cli", beam) {
    Error(reason) -> Error("load failed: " <> reason)
    Ok(mod_atom) ->
      case ffi_start_instance(mod_atom) {
        Ok(proc) -> Ok(InstanceProc(proc))
        Error(reason) -> Error(reason)
      }
  }
}

/// **Invoke** an export on a live instance (the run-ABI's last step). Routes the call INTO
/// the instance's owned process via `call_instance`, so it reads that instance's state.
///
/// **Strategy-aware, signature-stable (unit P4-08 §C):** under `Cell` the process applies
/// `Module:export(Args)` against its pdict cell; under `Threaded` it applies
/// `Module:export(St, Args…)`, unpacks the returned `{Package, St'}`, and threads `St'` into
/// the next invoke (so a mutation observed here persists into the following `invoke_instance`
/// on the same handle). Either way this returns the unpacked result `Package`, so the caller
/// sees one uniform shape.
///
/// - `proc`: a live `InstanceProc` (from `instantiate`).
/// - `export`: the exported function name to apply.
/// - `args`: raw unsigned bit-pattern integer arguments (the D5 ABI).
/// - Returns `Returned([value])` on a normal single-result return or `Trapped(reason)` on a
///   trap / capability denial. Total — never panics.
pub fn invoke_instance(
  proc: InstanceProc,
  export: String,
  args: List(Int),
) -> RunResult {
  let InstanceProc(pid) = proc
  case ffi_call_instance(pid, atom.create(export), args) {
    Ok(value) -> Returned([value])
    Error(reason) -> Trapped(reason)
  }
}

/// Stop a live instance's owned process (its pdict cell is GC'd with it). Call when an
/// instance is no longer needed; total.
pub fn stop_instance(proc: InstanceProc) -> Nil {
  let InstanceProc(pid) = proc
  ffi_stop_instance(pid)
}

/// **Exec** a PREBUILT `.beam` (the run-ABI on an already-compiled module — NO compile step).
/// Reads the module name baked into `beam`, loads + instantiates it in an owned process, then
/// invokes `export(args)` `repeat` times in that process, timing ONLY the invocations
/// (excludes compile, load, and instantiate — for benchmarking the emitted BEAM code).
///
/// - `beam`: a compiled `.beam` binary (e.g. from `to-beam`).
/// - `export`/`args`: as `run` (raw bit-pattern integer args).
/// - `repeat`: number of invocations (>= 1); the timing covers all of them.
/// - Returns `Ok(#(micros, RunResult))` — `micros` is the total wall time for the calls,
///   `RunResult` the LAST call's outcome. `Error(reason)` if the `.beam` is unreadable / won't
///   load; an instantiation/runtime trap is `Ok(#(0, Trapped(reason)))`. Total — never panics.
pub fn exec_beam(
  beam: BitArray,
  export: String,
  args: List(Int),
  repeat: Int,
) -> Result(#(Int, RunResult), String) {
  case ffi_module_name(beam) {
    Error(reason) -> Error("not a .beam: " <> reason)
    Ok(mod) ->
      case instantiate(beam, mod) {
        Error(reason) -> Ok(#(0, Trapped(reason)))
        Ok(proc) -> {
          let InstanceProc(pid) = proc
          let out = case
            ffi_bench_instance(pid, atom.create(export), args, repeat)
          {
            Ok(#(micros, value)) -> #(micros, Returned([value]))
            Error(reason) -> #(0, Trapped(reason))
          }
          stop_instance(proc)
          Ok(out)
        }
      }
  }
}

/// Apply `module:function(args)` IN THE CALLING PROCESS, capturing a trap as `Error(text)`
/// (the same-process catching-apply seam). See `src/twocore_cli_ffi.erl`.
@external(erlang, "twocore_cli_ffi", "catch_apply")
fn ffi_catch_apply(
  module: Atom,
  function: Atom,
  args: List(Int),
) -> Result(Int, String)

/// Spawn an instance's owned process and run `module:instantiate()` in it (the
/// one-instance-one-process seam). `Ok(pid)` once seeded; `Error(reason)` on an
/// instantiation-time trap. See `src/twocore_cli_ffi.erl`.
@external(erlang, "twocore_cli_ffi", "start_instance")
fn ffi_start_instance(module: Atom) -> Result(Pid, String)

/// Apply `function(args)` inside an instance's owned process. `Ok(v)` / `Error(reason)`.
@external(erlang, "twocore_cli_ffi", "call_instance")
fn ffi_call_instance(
  proc: Pid,
  function: Atom,
  args: List(Int),
) -> Result(Int, String)

/// Ask an instance's owned process to exit (cell GC'd with it).
@external(erlang, "twocore_cli_ffi", "stop_instance")
fn ffi_stop_instance(proc: Pid) -> Nil

/// Read the module name baked into a `.beam` binary (so a prebuilt `.beam` can be loaded even
/// when its filename differs from its module name). `Ok(name)` / `Error(reason)`.
@external(erlang, "twocore_cli_ffi", "module_name")
fn ffi_module_name(beam: BitArray) -> Result(String, String)

/// Invoke `function(args)` `repeat` times inside an instance's owned process, returning
/// `Ok(#(total_micros, last_value))` / `Error(reason)`. Times only the invocations.
@external(erlang, "twocore_cli_ffi", "bench_instance")
fn ffi_bench_instance(
  proc: Pid,
  function: Atom,
  args: List(Int),
  repeat: Int,
) -> Result(#(Int, Int), String)

// ─────────────────────────────── composable stage drivers ───────────────────────────────

/// Decode → validate → frontend-lower a `.wasm` binary into the shared IR (the unit-10
/// frontend slice). Each stage's typed error is mapped to its `PipelineError` variant.
///
/// - `wasm`: untrusted `.wasm` bytes.
/// - Return: `Ok(ir.Module)` or the first failing stage's `Error(PipelineError)`. No policy
///   pass or codegen is run here (use `ir_to_core` for those). Total — never panics.
pub fn source_to_ir(wasm: BitArray) -> Result(ir.Module, PipelineError) {
  case decode.decode(wasm) {
    Error(e) -> Error(DecodeFailed(e))
    Ok(m) ->
      case validate.validate(m) {
        Error(e) -> Error(ValidateFailed(e))
        Ok(tm) ->
          case lower.lower(tm) {
            Error(e) -> Error(FrontendLowerFailed(e))
            Ok(irmod) -> Ok(irmod)
          }
      }
  }
}

/// Run the IR→IR Safe policy pass (`ir_lower`, unit 11a) over `m` under `binding`.
///
/// - `m`: the IR module (e.g. from `source_to_ir` or `ir/parser`).
/// - `binding`: the build-time runtime binding (its `mode`/`stdlib_module` drive policy).
/// - Return: `Ok(rewritten_module)` (CallHosts gated, metering inserted), or
///   `Error(IrLowerFailed(_))` on the first policy violation (fail-closed). Total.
pub fn lower_ir(
  m: ir.Module,
  binding: Binding,
) -> Result(ir.Module, PipelineError) {
  case ir_lower.lower(m, binding) {
    Error(e) -> Error(IrLowerFailed(e))
    Ok(lowered) -> Ok(lowered)
  }
}

/// Run the shared IR→IR optimizer over `m` at the level carried by the profile (F1/F7).
///
/// The optimizer sits BETWEEN `ir_lower` and `emit_core`: `source_to_ir → ir_lower →
/// optimize_ir → emit_core`. The level is read from `binding.opt_level` (F7 — the profile is
/// the single source of truth), so `profiles.safe()` optimizes at `Baseline` (trust-neutral
/// passes) and `profiles.unsafe()` at `Aggressive` (baseline + Unsafe-only passes).
///
/// - `m`: the IR module (post-`ir_lower`, so `Charge` metering nodes are already present under
///   `MeterFuel` and absent under `MeterOff` — the optimizer must PRESERVE the charges it sees,
///   F3, and only the `Aggressive` charge-elision pass may remove them, unit 04).
/// - `binding`: the build-time profile; only `binding.opt_level` is read here.
/// - Return: a semantics-preserving rewrite of `m` (F2). `OptNone` is the identity, so a
///   profile with `opt_level: OptNone` BYPASSES the optimizer (the Phase-1/2 build path / F2
///   differential baseline). TOTAL — `ir_opt.optimize` never fails, so this returns a bare
///   `ir.Module`, not a `Result` (no new `PipelineError` variant, F7).
pub fn optimize_ir(m: ir.Module, binding: Binding) -> ir.Module {
  ir_opt.optimize(m, binding.opt_level)
}

/// IR → `.core` text: `ir_lower` (Safe policy pass / metering) → `ir_opt` (level from
/// `binding.opt_level`, F1) → `emit_core`, printed by `core_printer`. The canonical
/// "IR → backend" path the CLI's `to-core`/`run` use, now with the optimizer in-chain.
///
/// - `m`: the IR module to compile.
/// - `binding`: the build-time runtime binding (chokepoint module names + policy mode + the
///   optimizer level).
/// - Return: `Ok(core_text)`, or `Error(IrLowerFailed/EmitFailed)`. Total — never panics.
pub fn ir_to_core(
  m: ir.Module,
  binding: Binding,
) -> Result(String, PipelineError) {
  case lower_ir(m, binding) {
    Error(e) -> Error(e)
    Ok(lowered) -> {
      let optimized = optimize_ir(lowered, binding)
      case emit_core.emit_module(optimized, binding) {
        Error(e) -> Error(EmitFailed(e))
        Ok(cmod) -> Ok(core_printer.print_module(cmod))
      }
    }
  }
}

/// Compile `.core` text to an in-memory `.beam` binary (unit 04), WITHOUT loading it.
///
/// - `core`: the Core Erlang source text.
/// - `mod`: the expected module name (documentation/diagnostic only; the real name is the
///   one baked into the `.core` header — pass `ir.Module.name` for clarity).
/// - Return: `Ok(beam_bytes)` or `Error(BuildFailed(_))` (scan/parse/compile diagnostics).
///   Total — never panics on malformed `.core` (it becomes `Error`).
pub fn core_to_beam(
  core: String,
  mod: String,
) -> Result(BitArray, PipelineError) {
  let _ = mod
  case build_beam.compile_core(bit_array.from_string(core)) {
    Error(e) -> Error(BuildFailed(e))
    Ok(#(_atom, beam)) -> Ok(beam)
  }
}

/// Parse `.ir` text into an `ir.Module` (unit 02's parser). A convenience wrapper used by
/// the CLI's `.ir`-consuming subcommands; the `ir.parser.ParseError` is NOT a pipeline
/// stage error (it parses the inter-stage textual form), so it is surfaced as its own type.
///
/// - `text`: `.ir` source text.
/// - Return: `Ok(ir.Module)` or `Error(ir_parser.ParseError)`. Total.
pub fn parse_ir(text: String) -> Result(ir.Module, ir_parser.ParseError) {
  ir_parser.parse_module(text)
}

/// End-to-end: `.wasm` bytes → result on the BEAM, through the Phase-2 run-ABI
/// `load → instantiate → invoke` with one-instance-one-process isolation (E5).
///
/// Composes `source_to_ir` → `ir_to_core(binding)` → `core_to_beam` → `instantiate` (spawn
/// the instance's owned process + run `instantiate/0`) → `invoke_instance` → `stop_instance`.
/// This is the CLI `run` subcommand's engine and the shape the acceptance corpus proves
/// green. The raw-bit-pattern argument/result ABI (D5) is unchanged.
///
/// **Posture-agnostic (unit P4-08 §C.3):** `binding` carries the chosen `state_strategy` and
/// tiers **unchanged** through every stage. `emit_core` links the tier via `binding.mem_module`
/// and picks the state seam via `binding.state_strategy`; the run-ABI self-detects the strategy
/// (§C.2). So a `Threaded`/`atomics` binding runs the SAME driver code as `Cell`/`paged` and
/// returns **byte-identical** results (G7) — the difference is confined to the loaded `.beam`
/// (calling convention) and the linked runtime module. The caller is expected to pass a binding
/// already validated through `profiles.link/1` (the CLI does so via `resolve_binding`); a
/// tier/strategy incoherence is a linker rejection surfaced there, not a `PipelineError` here.
///
/// - `wasm`: the `.wasm` bytes.
/// - `binding`: the build-time runtime binding (e.g. `profiles.safe()`/`portable()`, or a
///   `resolve_binding`-validated composition).
/// - `export`: the exported function name to invoke.
/// - `args`: raw unsigned bit-pattern integer arguments.
/// - Return: `Ok(Returned(_))` on a normal return; `Ok(Trapped(reason))` for an
///   INSTANTIATION-TIME trap (OOB active segment / trapping `start`) OR a runtime trap —
///   both are runtime outcomes, surfaced identically; or the first compile-stage
///   `Error(PipelineError)`. Total — never panics.
pub fn run_source(
  wasm: BitArray,
  binding: Binding,
  export: String,
  args: List(Int),
) -> Result(RunResult, PipelineError) {
  case source_to_ir(wasm) {
    Error(e) -> Error(e)
    Ok(m) ->
      case ir_to_core(m, binding) {
        Error(e) -> Error(e)
        Ok(core) ->
          case core_to_beam(core, m.name) {
            Error(e) -> Error(e)
            Ok(beam) ->
              case instantiate(beam, m.name) {
                // An instantiation-time trap is a runtime outcome, not a compile error.
                Error(reason) -> Ok(Trapped(reason))
                Ok(proc) -> {
                  let result = invoke_instance(proc, export, args)
                  stop_instance(proc)
                  Ok(result)
                }
              }
          }
      }
  }
}
