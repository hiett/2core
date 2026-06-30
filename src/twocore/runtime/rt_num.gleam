//// The numeric runtime — SIGNATURES frozen by unit 01; BODIES implemented by unit 06
//// (the `bif`, tier-P reference implementation).
////
//// This module is the single auditable chokepoint for numeric fidelity (D2): the
//// generated Core Erlang calls these functions at run time, so the two's-complement
//// wrap, the trapping `div`/`rem` semantics, shift-count masking, and the float
//// bit-pattern representation all live here and ONLY here. Unit 01 fixes the
//// **names, arities, and `Result`-vs-bare-`Int` shape**; the spec-cited *semantics*
//// (and the float = raw-bits representation, never a BEAM double) are filled in by
//// unit 06.
////
//// ## Value representation conventions (the one documented convention)
////
//// - **Integers** (i32/i64 operands and results) are the **raw UNSIGNED bit pattern**
////   as an `Int` in `[0, 2^width)`. Signed operations interpret those bits as two's
////   complement internally and return the unsigned bit pattern of the result.
//// - **Floats** (f32/f64) are the **raw IEEE-754 bit pattern** as an `Int` (D5 — never
////   a BEAM double, so NaN/Infinity/`-0.0` round-trip exactly). Float ops take and
////   return bit patterns.
//// - **Comparisons** (`*_eq`, `*_ne`, `*_lt_*`, …, `*_eqz`) return an **i32 truth
////   value**: `1` for true, `0` for false.
//// - **Trapping ops** (`*_div_s`, `*_div_u`, `*_rem_s`, `*_rem_u`) return
////   `Result(Int, TrapReason)`: `Ok(bits)` on success, `Error(reason)` on a trap (the
////   *caller* — `emit_core` — raises via `rt_trap`; resolved open question #3).
////
//// All bodies are `todo` until unit 06 implements them; calling one before then aborts
//// with "not yet implemented". This is the only sanctioned source of build warnings
//// for this file.

import twocore/ir.{type TrapReason}

// ───────────────────────────── i32 — non-trapping ─────────────────────────────

/// 32-bit integer addition (two's-complement wrap). Returns the low-32-bit result as
/// an unsigned bit pattern.
pub fn i32_add(_a: Int, _b: Int) -> Int {
  todo
}

/// 32-bit integer subtraction (two's-complement wrap).
pub fn i32_sub(_a: Int, _b: Int) -> Int {
  todo
}

/// 32-bit integer multiplication (two's-complement wrap, low 32 bits).
pub fn i32_mul(_a: Int, _b: Int) -> Int {
  todo
}

/// 32-bit bitwise AND.
pub fn i32_and(_a: Int, _b: Int) -> Int {
  todo
}

/// 32-bit bitwise OR.
pub fn i32_or(_a: Int, _b: Int) -> Int {
  todo
}

/// 32-bit bitwise XOR.
pub fn i32_xor(_a: Int, _b: Int) -> Int {
  todo
}

/// 32-bit shift left; the shift count `b` is taken modulo 32 (shift-count masking).
pub fn i32_shl(_a: Int, _b: Int) -> Int {
  todo
}

/// 32-bit arithmetic (sign-propagating) shift right; count taken modulo 32.
pub fn i32_shr_s(_a: Int, _b: Int) -> Int {
  todo
}

/// 32-bit logical (zero-filling) shift right; count taken modulo 32.
pub fn i32_shr_u(_a: Int, _b: Int) -> Int {
  todo
}

/// 32-bit rotate left; count taken modulo 32.
pub fn i32_rotl(_a: Int, _b: Int) -> Int {
  todo
}

/// 32-bit rotate right; count taken modulo 32.
pub fn i32_rotr(_a: Int, _b: Int) -> Int {
  todo
}

/// Count leading zero bits of a 32-bit value (`clz`; returns 32 for input 0).
pub fn i32_clz(_a: Int) -> Int {
  todo
}

/// Count trailing zero bits of a 32-bit value (`ctz`; returns 32 for input 0).
pub fn i32_ctz(_a: Int) -> Int {
  todo
}

/// Population count: number of set bits in a 32-bit value.
pub fn i32_popcnt(_a: Int) -> Int {
  todo
}

/// Returns `1` if the 32-bit value is zero, else `0` (i32 truth value).
pub fn i32_eqz(_a: Int) -> Int {
  todo
}

/// 32-bit equality; returns the i32 truth value `1`/`0`.
pub fn i32_eq(_a: Int, _b: Int) -> Int {
  todo
}

/// 32-bit inequality; returns the i32 truth value `1`/`0`.
pub fn i32_ne(_a: Int, _b: Int) -> Int {
  todo
}

/// 32-bit signed less-than; returns the i32 truth value `1`/`0`.
pub fn i32_lt_s(_a: Int, _b: Int) -> Int {
  todo
}

/// 32-bit unsigned less-than; returns the i32 truth value `1`/`0`.
pub fn i32_lt_u(_a: Int, _b: Int) -> Int {
  todo
}

/// 32-bit signed greater-than; returns the i32 truth value `1`/`0`.
pub fn i32_gt_s(_a: Int, _b: Int) -> Int {
  todo
}

/// 32-bit unsigned greater-than; returns the i32 truth value `1`/`0`.
pub fn i32_gt_u(_a: Int, _b: Int) -> Int {
  todo
}

/// 32-bit signed less-than-or-equal; returns the i32 truth value `1`/`0`.
pub fn i32_le_s(_a: Int, _b: Int) -> Int {
  todo
}

/// 32-bit unsigned less-than-or-equal; returns the i32 truth value `1`/`0`.
pub fn i32_le_u(_a: Int, _b: Int) -> Int {
  todo
}

/// 32-bit signed greater-than-or-equal; returns the i32 truth value `1`/`0`.
pub fn i32_ge_s(_a: Int, _b: Int) -> Int {
  todo
}

/// 32-bit unsigned greater-than-or-equal; returns the i32 truth value `1`/`0`.
pub fn i32_ge_u(_a: Int, _b: Int) -> Int {
  todo
}

// ───────────────────────────── i32 — trapping ─────────────────────────────

/// 32-bit signed division. `Error(IntDivByZero)` if `b == 0`;
/// `Error(IntOverflow)` for `INT_MIN / -1`; else `Ok(quotient bits)`.
pub fn i32_div_s(_a: Int, _b: Int) -> Result(Int, TrapReason) {
  todo
}

/// 32-bit unsigned division. `Error(IntDivByZero)` if `b == 0`; else `Ok(quotient)`.
pub fn i32_div_u(_a: Int, _b: Int) -> Result(Int, TrapReason) {
  todo
}

/// 32-bit signed remainder. `Error(IntDivByZero)` if `b == 0`; else `Ok(remainder)`
/// (no overflow trap: `INT_MIN % -1` is `0`).
pub fn i32_rem_s(_a: Int, _b: Int) -> Result(Int, TrapReason) {
  todo
}

/// 32-bit unsigned remainder. `Error(IntDivByZero)` if `b == 0`; else `Ok(remainder)`.
pub fn i32_rem_u(_a: Int, _b: Int) -> Result(Int, TrapReason) {
  todo
}

// ───────────────────────────── i64 — non-trapping ─────────────────────────────

/// 64-bit integer addition (two's-complement wrap).
pub fn i64_add(_a: Int, _b: Int) -> Int {
  todo
}

/// 64-bit integer subtraction (two's-complement wrap).
pub fn i64_sub(_a: Int, _b: Int) -> Int {
  todo
}

/// 64-bit integer multiplication (two's-complement wrap, low 64 bits).
pub fn i64_mul(_a: Int, _b: Int) -> Int {
  todo
}

/// 64-bit bitwise AND.
pub fn i64_and(_a: Int, _b: Int) -> Int {
  todo
}

/// 64-bit bitwise OR.
pub fn i64_or(_a: Int, _b: Int) -> Int {
  todo
}

/// 64-bit bitwise XOR.
pub fn i64_xor(_a: Int, _b: Int) -> Int {
  todo
}

/// 64-bit shift left; the shift count `b` is taken modulo 64 (shift-count masking).
pub fn i64_shl(_a: Int, _b: Int) -> Int {
  todo
}

/// 64-bit arithmetic (sign-propagating) shift right; count taken modulo 64.
pub fn i64_shr_s(_a: Int, _b: Int) -> Int {
  todo
}

/// 64-bit logical (zero-filling) shift right; count taken modulo 64.
pub fn i64_shr_u(_a: Int, _b: Int) -> Int {
  todo
}

/// 64-bit rotate left; count taken modulo 64.
pub fn i64_rotl(_a: Int, _b: Int) -> Int {
  todo
}

/// 64-bit rotate right; count taken modulo 64.
pub fn i64_rotr(_a: Int, _b: Int) -> Int {
  todo
}

/// Count leading zero bits of a 64-bit value (`clz`; returns 64 for input 0).
pub fn i64_clz(_a: Int) -> Int {
  todo
}

/// Count trailing zero bits of a 64-bit value (`ctz`; returns 64 for input 0).
pub fn i64_ctz(_a: Int) -> Int {
  todo
}

/// Population count: number of set bits in a 64-bit value.
pub fn i64_popcnt(_a: Int) -> Int {
  todo
}

/// Returns `1` if the 64-bit value is zero, else `0` (i32 truth value).
pub fn i64_eqz(_a: Int) -> Int {
  todo
}

/// 64-bit equality; returns the i32 truth value `1`/`0`.
pub fn i64_eq(_a: Int, _b: Int) -> Int {
  todo
}

/// 64-bit inequality; returns the i32 truth value `1`/`0`.
pub fn i64_ne(_a: Int, _b: Int) -> Int {
  todo
}

/// 64-bit signed less-than; returns the i32 truth value `1`/`0`.
pub fn i64_lt_s(_a: Int, _b: Int) -> Int {
  todo
}

/// 64-bit unsigned less-than; returns the i32 truth value `1`/`0`.
pub fn i64_lt_u(_a: Int, _b: Int) -> Int {
  todo
}

/// 64-bit signed greater-than; returns the i32 truth value `1`/`0`.
pub fn i64_gt_s(_a: Int, _b: Int) -> Int {
  todo
}

/// 64-bit unsigned greater-than; returns the i32 truth value `1`/`0`.
pub fn i64_gt_u(_a: Int, _b: Int) -> Int {
  todo
}

/// 64-bit signed less-than-or-equal; returns the i32 truth value `1`/`0`.
pub fn i64_le_s(_a: Int, _b: Int) -> Int {
  todo
}

/// 64-bit unsigned less-than-or-equal; returns the i32 truth value `1`/`0`.
pub fn i64_le_u(_a: Int, _b: Int) -> Int {
  todo
}

/// 64-bit signed greater-than-or-equal; returns the i32 truth value `1`/`0`.
pub fn i64_ge_s(_a: Int, _b: Int) -> Int {
  todo
}

/// 64-bit unsigned greater-than-or-equal; returns the i32 truth value `1`/`0`.
pub fn i64_ge_u(_a: Int, _b: Int) -> Int {
  todo
}

// ───────────────────────────── i64 — trapping ─────────────────────────────

/// 64-bit signed division. `Error(IntDivByZero)` if `b == 0`;
/// `Error(IntOverflow)` for `INT_MIN / -1`; else `Ok(quotient bits)`.
pub fn i64_div_s(_a: Int, _b: Int) -> Result(Int, TrapReason) {
  todo
}

/// 64-bit unsigned division. `Error(IntDivByZero)` if `b == 0`; else `Ok(quotient)`.
pub fn i64_div_u(_a: Int, _b: Int) -> Result(Int, TrapReason) {
  todo
}

/// 64-bit signed remainder. `Error(IntDivByZero)` if `b == 0`; else `Ok(remainder)`
/// (no overflow trap: `INT_MIN % -1` is `0`).
pub fn i64_rem_s(_a: Int, _b: Int) -> Result(Int, TrapReason) {
  todo
}

/// 64-bit unsigned remainder. `Error(IntDivByZero)` if `b == 0`; else `Ok(remainder)`.
pub fn i64_rem_u(_a: Int, _b: Int) -> Result(Int, TrapReason) {
  todo
}

// ───────────────────────────── Conversions ─────────────────────────────

/// Wrap an i64 to its low 32 bits (`i32.wrap_i64`).
pub fn i32_wrap_i64(_a: Int) -> Int {
  todo
}

/// Sign-extend an i32 to i64 (`i64.extend_i32_s`).
pub fn i64_extend_i32_s(_a: Int) -> Int {
  todo
}

/// Zero-extend an i32 to i64 (`i64.extend_i32_u`).
pub fn i64_extend_i32_u(_a: Int) -> Int {
  todo
}

/// Sign-extend the low 8 bits of an i32 to a full i32 (`i32.extend8_s`).
pub fn i32_extend8_s(_a: Int) -> Int {
  todo
}

/// Sign-extend the low 16 bits of an i32 to a full i32 (`i32.extend16_s`).
pub fn i32_extend16_s(_a: Int) -> Int {
  todo
}

/// Sign-extend the low 8 bits of an i64 to a full i64 (`i64.extend8_s`).
pub fn i64_extend8_s(_a: Int) -> Int {
  todo
}

/// Sign-extend the low 16 bits of an i64 to a full i64 (`i64.extend16_s`).
pub fn i64_extend16_s(_a: Int) -> Int {
  todo
}

/// Sign-extend the low 32 bits of an i64 to a full i64 (`i64.extend32_s`).
pub fn i64_extend32_s(_a: Int) -> Int {
  todo
}

/// Reinterpret an f32 bit pattern as i32 bits — no value change (`i32.reinterpret_f32`).
pub fn i32_reinterpret_f32(_a: Int) -> Int {
  todo
}

/// Reinterpret an f64 bit pattern as i64 bits — no value change (`i64.reinterpret_f64`).
pub fn i64_reinterpret_f64(_a: Int) -> Int {
  todo
}

/// Reinterpret an i32 bit pattern as f32 bits — no value change (`f32.reinterpret_i32`).
pub fn f32_reinterpret_i32(_a: Int) -> Int {
  todo
}

/// Reinterpret an i64 bit pattern as f64 bits — no value change (`f64.reinterpret_i64`).
pub fn f64_reinterpret_i64(_a: Int) -> Int {
  todo
}

/// Saturating signed truncation f32 → i32 (`i32.trunc_sat_f32_s`); never traps.
pub fn i32_trunc_sat_f32_s(_a: Int) -> Int {
  todo
}

/// Saturating unsigned truncation f32 → i32 (`i32.trunc_sat_f32_u`); never traps.
pub fn i32_trunc_sat_f32_u(_a: Int) -> Int {
  todo
}

/// Saturating signed truncation f64 → i32 (`i32.trunc_sat_f64_s`); never traps.
pub fn i32_trunc_sat_f64_s(_a: Int) -> Int {
  todo
}

/// Saturating unsigned truncation f64 → i32 (`i32.trunc_sat_f64_u`); never traps.
pub fn i32_trunc_sat_f64_u(_a: Int) -> Int {
  todo
}

/// Saturating signed truncation f32 → i64 (`i64.trunc_sat_f32_s`); never traps.
pub fn i64_trunc_sat_f32_s(_a: Int) -> Int {
  todo
}

/// Saturating unsigned truncation f32 → i64 (`i64.trunc_sat_f32_u`); never traps.
pub fn i64_trunc_sat_f32_u(_a: Int) -> Int {
  todo
}

/// Saturating signed truncation f64 → i64 (`i64.trunc_sat_f64_s`); never traps.
pub fn i64_trunc_sat_f64_s(_a: Int) -> Int {
  todo
}

/// Saturating unsigned truncation f64 → i64 (`i64.trunc_sat_f64_u`); never traps.
pub fn i64_trunc_sat_f64_u(_a: Int) -> Int {
  todo
}

// ───────────────────────────── f32 (raw bits) ─────────────────────────────

/// 32-bit float addition; operands and result are raw binary32 bit patterns.
pub fn f32_add(_a: Int, _b: Int) -> Int {
  todo
}

/// 32-bit float subtraction; operands and result are raw binary32 bit patterns.
pub fn f32_sub(_a: Int, _b: Int) -> Int {
  todo
}

/// 32-bit float multiplication; operands and result are raw binary32 bit patterns.
pub fn f32_mul(_a: Int, _b: Int) -> Int {
  todo
}

/// 32-bit float division; operands and result are raw binary32 bit patterns.
pub fn f32_div(_a: Int, _b: Int) -> Int {
  todo
}

/// 32-bit float minimum (IEEE-754 / WASM semantics); raw binary32 bit patterns.
pub fn f32_min(_a: Int, _b: Int) -> Int {
  todo
}

/// 32-bit float maximum (IEEE-754 / WASM semantics); raw binary32 bit patterns.
pub fn f32_max(_a: Int, _b: Int) -> Int {
  todo
}

// ───────────────────────────── f64 (raw bits) ─────────────────────────────

/// 64-bit float addition; operands and result are raw binary64 bit patterns.
pub fn f64_add(_a: Int, _b: Int) -> Int {
  todo
}

/// 64-bit float subtraction; operands and result are raw binary64 bit patterns.
pub fn f64_sub(_a: Int, _b: Int) -> Int {
  todo
}

/// 64-bit float multiplication; operands and result are raw binary64 bit patterns.
pub fn f64_mul(_a: Int, _b: Int) -> Int {
  todo
}

/// 64-bit float division; operands and result are raw binary64 bit patterns.
pub fn f64_div(_a: Int, _b: Int) -> Int {
  todo
}

/// 64-bit float minimum (IEEE-754 / WASM semantics); raw binary64 bit patterns.
pub fn f64_min(_a: Int, _b: Int) -> Int {
  todo
}

/// 64-bit float maximum (IEEE-754 / WASM semantics); raw binary64 bit patterns.
pub fn f64_max(_a: Int, _b: Int) -> Int {
  todo
}
