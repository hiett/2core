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
//// ## What is *not* here (Phase 2, D9)
////
//// No budget, no trap-on-exhaustion, no per-op accounting. `charge` only ever increments
//// a counter and returns `Nil`. The counter is per-process and unbounded.

import gleam/dynamic.{type Dynamic}
import gleam/dynamic/decode

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

/// The process-dictionary key holding this process's running fuel total. As a 0-field
/// Gleam constructor it compiles to the unique, namespace-hygienic atom
/// `twocore_rt_meter_fuel`, so it cannot clash with another library's pdict keys.
type MeterKey {
  TwocoreRtMeterFuel
}

/// Charge `cost` fuel against the current process's running total, then return `Nil`.
///
/// - `cost`: a non-negative reduction-style estimate of the work about to run. (Negative
///   values are added as-is; the contract assumes `cost >= 0` and Phase-1 codegen only
///   ever passes non-negative costs.)
/// - Return: always `Nil` — the emitter discards it and proceeds to evaluate the charged
///   expression. Total; never raises.
/// - Effect: increments the process-local counter by `cost` (read-add-write into the
///   process dictionary). Process-local, so concurrent processes meter independently.
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
