//// `rt_meter` — the minimal fuel/metering seam (D9). Process-local; cannot crash the node.
////
//// The generated Core Erlang calls `charge` at run time for a `Charge(cost, body)` IR
//// node (inserted by unit 11's `ir_lower`): `call 'twocore@runtime@rt_meter':'charge'(Cost)`
//// then the charged `body` (see the calling convention in `runtime/instance.gleam`). The
//// point of Phase 1 is that the **instrumentation seam exists and is exercised
//// end-to-end** — not that metering is complete.
////
//// ## Mechanism & trust tier (flagged choice — see `state.md`)
////
//// Phase 1 **accumulates** fuel into a **process-dictionary** counter. That is
//// process-local and node-safe, but the high-level §10 tier taxonomy classifies
//// process-dictionary state as **tier-O** (OTP-native state), not strict tier-P. Safe
//// permits tiers P *or* O (never N), so this is allowed. The pdict accumulator is chosen
//// over a pure no-op `charge` precisely because it makes the seam **observable** — a test
//// can assert `fuel_consumed()` equals the summed cost, proving the charge path executed.
//// A strict-tier-P no-op is the alternative but cannot be observed.
////
//// ## Phase-3 enforcing metering (F5) — the freeze seam
////
//// Phase 3 turns CPU fuel into a real bound. This freeze (unit 01) adds the `seed_fuel/1`
//// seam and the `default_fuel_budget` constant (the finite Safe seed), and documents the
//// enforcing contract on `charge`; the enforcement itself (budget check + `FuelExhausted`
//// raise) lands in unit 05, and the ABI `charge/1` codegen calls is UNCHANGED (arity 1,
//// returns `Nil`), so no generated code changes when metering becomes enforcing. The budget
//// is process-dictionary state (like the Phase-2 cell), seeded once at instantiation and
//// read/written only by `charge` — never threaded through generated function signatures — so
//// a tail-iterating loop stays constant-space and preemptible.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode

/// The finite default CPU-fuel budget a Safe profile seeds (F5) — the SINGLE source of the
/// budget magnitude. `instance.safe_default()` reads this into `binding.fuel_budget`, and
/// `emit_core`'s `instantiate/0` bakes `seed_fuel(binding.fuel_budget)` under `MeterFuel`.
///
/// It is FINITE (so no metered artifact runs unbounded — fail-closed, D4) yet large enough
/// that the acceptance corpus + spec suite complete without tripping it. Unit 05 tunes the
/// magnitude against the real suite; a metered profile (`profiles.safe_metered(budget)`,
/// unit 10) may LOWER it, exactly as `safe_max_pages` bounds memory.
pub const default_fuel_budget: Int = 1_000_000_000

/// `erlang:put/2` — store `value` under `key` in the current process dictionary; returns
/// the previous value (or the atom `undefined` if unset), which callers here discard.
/// Direct BIF reference; process-local, cannot crash the node.
@external(erlang, "erlang", "put")
fn erlang_put(key: k, value: v) -> Dynamic

/// `erlang:get/1` — read `key` from the current process dictionary, or the atom
/// `undefined` if it was never set. Typed `Dynamic` because the result is either an
/// integer counter or `undefined`; callers decode it.
@external(erlang, "erlang", "get")
fn erlang_get(key: k) -> Dynamic

/// The process-dictionary keys `rt_meter` uses. Each 0-field Gleam constructor compiles to a
/// unique, namespace-hygienic atom, so neither can clash with another library's pdict keys.
///
/// - `TwocoreRtMeterFuel` (`twocore_rt_meter_fuel`): the running fuel total charged so far.
/// - `TwocoreRtMeterBudget` (`twocore_rt_meter_budget`): the seeded CPU budget (`seed_fuel`),
///   the finite bound `charge` will enforce against (unit 05).
type MeterKey {
  TwocoreRtMeterFuel
  TwocoreRtMeterBudget
}

/// Seed this instance's CPU-fuel BUDGET (F5), then reset the consumed total to 0.
///
/// Called once by the generated `instantiate/0` (synthesized by `emit_core`, unit 09), which
/// — as a documented exception to emit_core's posture-agnosticism — emits
/// `seed_fuel(binding.fuel_budget)` as `instantiate/0`'s FIRST effect under `MeterFuel`. It
/// runs inside the instance's OWNED process, so the budget lives in that process's dictionary
/// alongside the Phase-2 cell (one-instance-one-process, E1) — isolated per instance and GC'd
/// with the process.
///
/// - `budget`: the finite reduction-style fuel bound — `instantiate/0` passes
///   `binding.fuel_budget` (which `safe_default()` seeds from `default_fuel_budget`). The
///   numeric bound is a seed value on the `Binding`, NOT a field of `MeterMode`.
/// - Return: always `Nil`. Total; never raises.
/// - Effect: stores `budget` in the per-process budget cell and zeroes the consumed counter.
///
/// FREEZE body: store the budget + reset consumed (real, trivial). Unit 05 makes `charge`
/// enforce this budget (budget check + `FuelExhausted` raise).
pub fn seed_fuel(budget: Int) -> Nil {
  let _ = erlang_put(TwocoreRtMeterBudget, budget)
  reset_fuel()
}

/// Charge `cost` fuel against the current process's running total, then return `Nil`.
///
/// - `cost`: a non-negative reduction-style estimate of the work about to run. (Negative
///   values are added as-is; the contract assumes `cost >= 0` and codegen only ever passes
///   non-negative costs.)
/// - Return: always `Nil` — the emitter discards it and proceeds to evaluate the charged
///   expression. At the freeze, total; never raises.
/// - Effect: increments the process-local counter by `cost` (read-add-write into the
///   process dictionary). Process-local, so concurrent processes meter independently.
///
/// ENFORCING CONTRACT (unit 05): advance the consumed total by `cost`; if a budget was
/// seeded and the total exceeds it, **raise `FuelExhausted`** (via `rt_trap.raise`, surfacing
/// as `{wasm_trap, fuel_exhausted}`). Fail-closed (D4): a `MeterFuel` artifact must never run
/// silently unbounded — its `instantiate/0` ALWAYS seeds the budget and the run-ABI
/// instantiates before every invoke, so the production CPU bound is always armed. The ABI is
/// UNCHANGED (arity 1, returns `Nil`), so no generated code changes when enforcement lands.
/// FREEZE body: the existing accumulate-only body (kept green); unit 05 adds the check + raise.
pub fn charge(cost: Int) -> Nil {
  let _ = erlang_put(TwocoreRtMeterFuel, fuel_consumed() + cost)
  Nil
}

/// The running fuel total charged in the **current process** so far.
///
/// - Return: the accumulated cost (`>= 0` in normal use), or `0` if `charge` has never
///   run in this process (the counter is absent — decoded from `undefined` to `0`).
///   Total; never raises. Reading it does not reset it.
/// - Use: test/observability support and the Phase-2 budget check; it is *not* part of
///   the generated-code calling convention.
pub fn fuel_consumed() -> Int {
  case decode.run(erlang_get(TwocoreRtMeterFuel), decode.int) {
    Ok(total) -> total
    Error(_) -> 0
  }
}

/// Zero the current process's fuel counter.
///
/// - Return: always `Nil`. Total; never raises.
/// - Use: test support (make a metering assertion independent of prior charges in this
///   process) and the future budget-reset hook. Not called by generated code.
pub fn reset_fuel() -> Nil {
  let _ = erlang_put(TwocoreRtMeterFuel, 0)
  Nil
}
