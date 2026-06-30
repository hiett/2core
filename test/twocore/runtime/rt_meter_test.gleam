//// Tests for `rt_meter` (unit 09) — the minimal fuel/metering seam.
////
//// Metering is a *policy* seam, not a WASM-spec concept (D9), so these assert OUR
//// documented `charge` contract: it accumulates the summed cost into a process-local
//// counter and returns `Nil`. The point is the instrumentation seam is **callable and
//// observable** end-to-end; the full `emit_core` fixture (IR `Charge` nodes → this
//// counter) lands with unit 08. Each test that reads a total resets first so it is
//// independent of any prior charge in this process.

import gleeunit/should
import twocore/runtime/rt_meter

/// A fresh counter reads 0, and `charge` accumulates the *sum* of its costs.
pub fn charge_accumulates_test() {
  rt_meter.reset_fuel()
  rt_meter.fuel_consumed() |> should.equal(0)
  rt_meter.charge(5)
  rt_meter.charge(7)
  rt_meter.charge(0)
  rt_meter.fuel_consumed() |> should.equal(12)
}

/// `charge` returns `Nil` (the emitter discards it before the charged expression).
pub fn charge_returns_nil_test() {
  rt_meter.charge(3) |> should.equal(Nil)
}

/// `charge(0)` is total and a no-op on the running total.
pub fn charge_zero_is_total_test() {
  rt_meter.reset_fuel()
  rt_meter.charge(0)
  rt_meter.fuel_consumed() |> should.equal(0)
}

/// `reset_fuel` zeroes a non-empty counter.
pub fn reset_zeroes_counter_test() {
  rt_meter.charge(100)
  rt_meter.reset_fuel()
  rt_meter.fuel_consumed() |> should.equal(0)
}

/// A single large charge is recorded exactly (no overflow — BEAM bignums).
pub fn charge_large_cost_test() {
  rt_meter.reset_fuel()
  rt_meter.charge(1_000_000)
  rt_meter.charge(2_345_678)
  rt_meter.fuel_consumed() |> should.equal(3_345_678)
}
