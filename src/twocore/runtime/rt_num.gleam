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
////   complement internally (`signed/2`) and return the unsigned bit pattern of the
////   result (`norm/2`). `norm(x, n) = ((x % 2^n) + 2^n) % 2^n` is a TRUE non-negative
////   modulo — bare `%`/`int.remainder` follows the dividend's sign and would corrupt
////   the bit pattern, so wrapping always goes through `norm`.
//// - **Floats** (f32/f64) are the **raw IEEE-754 bit pattern** as an `Int` (D5 — never
////   a BEAM double, which cannot represent NaN/Infinity: arithmetic on them raises
////   `badarith` and `<<F:64/float>>` fails to match NaN/Inf bits). Each float op
////   classifies its operands from the bit fields, handles NaN/±Inf/±0 by IEEE rules on
////   the bits, and only decodes finite operands to a native double for the actual
////   arithmetic, re-encoding the finite result back to bits.
//// - **Canonical-NaN lock (spec-permitted determinism).** Whenever an operand is NaN
////   or an operation produces NaN, these functions return the **positive canonical
////   NaN** (`f32 = 0x7FC00000`, `f64 = 0x7FF8000000000000`). No NaN-payload
////   propagation is attempted; this is conformant and is the deterministic profile.
//// - **Overflow → ±Inf, never `badarith`.** BEAM double arithmetic raises `badarith`
////   on overflow instead of yielding `±Inf`. The finite path detects f64 overflow
////   exactly (via an integer significand/exponent comparison against the IEEE
////   round-to-nearest overflow threshold) and emits the correctly-signed Inf bits;
////   f32 results are produced by a 32-bit float round-trip, which rounds to single and
////   saturates out-of-range magnitudes to `±Inf` without raising.
//// - **Comparisons** (`*_eq`, `*_ne`, `*_lt_*`, …, `*_eqz`) return an **i32 truth
////   value**: `1` for true, `0` for false (including the `i64_*` comparisons).
//// - **Trapping ops** (`*_div_s`, `*_div_u`, `*_rem_s`, `*_rem_u`) return
////   `Result(Int, TrapReason)`: `Ok(bits)` on success, `Error(reason)` on a trap (the
////   *caller* — `emit_core` — raises via `rt_trap`; resolved open question #3). NB:
////   Gleam's `/` and `%` are TOTAL (`x / 0 == 0`), so these functions check the
////   divisor explicitly BEFORE dividing.

import gleam/int
import gleam/option.{type Option, None, Some}
import gleam/order
import twocore/ir.{type TrapReason, IntDivByZero, IntOverflow}

// ───────────────────── private integer representation helpers ─────────────────────

/// `2^n` for `n >= 0`, as an arbitrary-precision integer (BEAM bignum).
fn pow2(n: Int) -> Int {
  int.bitwise_shift_left(1, n)
}

/// The modulus `2^n` bounding an n-bit value: all stored bit patterns are in `[0, M)`.
fn modulus(n: Int) -> Int {
  pow2(n)
}

/// TRUE non-negative modulo: maps any integer `x` to its canonical n-bit unsigned bit
/// pattern in `[0, 2^n)`. This is the two's-complement "wrap"; unlike bare `%` it never
/// returns a negative value.
fn norm(x: Int, n: Int) -> Int {
  let m = modulus(n)
  let r = x % m
  case r < 0 {
    True -> r + m
    False -> r
  }
}

/// Interpret an n-bit unsigned bit pattern `u` in `[0, 2^n)` as a two's-complement
/// signed integer in `[-2^(n-1), 2^(n-1))`.
fn signed(u: Int, n: Int) -> Int {
  case u >= pow2(n - 1) {
    True -> u - modulus(n)
    False -> u
  }
}

/// The smallest two's-complement signed value for width `n`: `-2^(n-1)` (INT_MIN).
fn int_min_signed(n: Int) -> Int {
  0 - pow2(n - 1)
}

/// The low `k` bits of `a` (`a >= 0`), i.e. `a mod 2^k`.
fn low_bits(a: Int, k: Int) -> Int {
  int.bitwise_and(a, pow2(k) - 1)
}

/// The shift/rotate count: the operand `b` taken modulo the width `n` (`n` a power of
/// two), so a shift by `n` is the identity and a shift by `n+1` equals a shift by `1`.
fn shift_count(b: Int, n: Int) -> Int {
  int.bitwise_and(b, n - 1)
}

/// `1` if `b` is true, `0` otherwise — the i32 truth encoding used by every comparison.
fn bool_to_i32(b: Bool) -> Int {
  case b {
    True -> 1
    False -> 0
  }
}

// ───────────────────── private integer op workers (width-parametric) ─────────────────────

fn iadd(a: Int, b: Int, n: Int) -> Int {
  norm(a + b, n)
}

fn isub(a: Int, b: Int, n: Int) -> Int {
  norm(a - b, n)
}

fn imul(a: Int, b: Int, n: Int) -> Int {
  norm(a * b, n)
}

fn ishl(a: Int, b: Int, n: Int) -> Int {
  norm(int.bitwise_shift_left(a, shift_count(b, n)), n)
}

fn ishr_u(a: Int, b: Int, n: Int) -> Int {
  // `a >= 0`, so an arithmetic shift right is identical to a logical one.
  int.bitwise_shift_right(a, shift_count(b, n))
}

fn ishr_s(a: Int, b: Int, n: Int) -> Int {
  // Arithmetic (sign-filling) shift: floor(signed(a) / 2^k). Erlang `bsr` on a negative
  // operand floors, which is exactly what an arithmetic shift requires.
  norm(int.bitwise_shift_right(signed(a, n), shift_count(b, n)), n)
}

fn irotl(a: Int, b: Int, n: Int) -> Int {
  let k = shift_count(b, n)
  norm(
    int.bitwise_or(
      int.bitwise_shift_left(a, k),
      int.bitwise_shift_right(a, n - k),
    ),
    n,
  )
}

fn irotr(a: Int, b: Int, n: Int) -> Int {
  let k = shift_count(b, n)
  norm(
    int.bitwise_or(
      int.bitwise_shift_right(a, k),
      int.bitwise_shift_left(a, n - k),
    ),
    n,
  )
}

/// Number of significant bits of `a >= 0` (`0` for `a == 0`).
fn bit_length(a: Int) -> Int {
  case a {
    0 -> 0
    _ -> 1 + bit_length(a / 2)
  }
}

fn iclz(a: Int, n: Int) -> Int {
  n - bit_length(a)
}

fn trailing_zeros(a: Int) -> Int {
  case a % 2 {
    0 -> 1 + trailing_zeros(a / 2)
    _ -> 0
  }
}

fn ictz(a: Int, n: Int) -> Int {
  case a {
    0 -> n
    _ -> trailing_zeros(a)
  }
}

fn popcount(a: Int, acc: Int) -> Int {
  case a {
    0 -> acc
    _ -> popcount(a / 2, acc + a % 2)
  }
}

fn idiv_u(a: Int, b: Int) -> Result(Int, TrapReason) {
  case b {
    0 -> Error(IntDivByZero)
    _ -> Ok(a / b)
  }
}

fn irem_u(a: Int, b: Int) -> Result(Int, TrapReason) {
  case b {
    0 -> Error(IntDivByZero)
    _ -> Ok(a % b)
  }
}

fn idiv_s(a: Int, b: Int, n: Int) -> Result(Int, TrapReason) {
  case b {
    0 -> Error(IntDivByZero)
    _ -> {
      let sa = signed(a, n)
      let sb = signed(b, n)
      case sa == int_min_signed(n) && sb == -1 {
        True -> Error(IntOverflow)
        // Gleam `/` truncates toward zero (Erlang `div`).
        False -> Ok(norm(sa / sb, n))
      }
    }
  }
}

fn irem_s(a: Int, b: Int, n: Int) -> Result(Int, TrapReason) {
  case b {
    0 -> Error(IntDivByZero)
    // Gleam `%` is Erlang `rem`: it follows the dividend's sign and yields `0` for
    // `INT_MIN % -1` (so rem_s, unlike div_s, never traps on overflow).
    _ -> Ok(norm(signed(a, n) % signed(b, n), n))
  }
}

// ───────────────────────────── i32 — non-trapping ─────────────────────────────

/// 32-bit integer addition with two's-complement wrap. Returns the low-32-bit result as
/// an unsigned bit pattern. Never traps.
pub fn i32_add(a: Int, b: Int) -> Int {
  iadd(a, b, 32)
}

/// 32-bit integer subtraction with two's-complement wrap. Never traps.
pub fn i32_sub(a: Int, b: Int) -> Int {
  isub(a, b, 32)
}

/// 32-bit integer multiplication (low 32 bits, two's-complement wrap). Never traps.
pub fn i32_mul(a: Int, b: Int) -> Int {
  imul(a, b, 32)
}

/// 32-bit bitwise AND of the raw bit patterns.
pub fn i32_and(a: Int, b: Int) -> Int {
  int.bitwise_and(a, b)
}

/// 32-bit bitwise OR of the raw bit patterns.
pub fn i32_or(a: Int, b: Int) -> Int {
  int.bitwise_or(a, b)
}

/// 32-bit bitwise XOR of the raw bit patterns.
pub fn i32_xor(a: Int, b: Int) -> Int {
  int.bitwise_exclusive_or(a, b)
}

/// 32-bit shift left; the shift count `b` is taken modulo 32 (shift-count masking), so
/// a shift by 32 is the identity.
pub fn i32_shl(a: Int, b: Int) -> Int {
  ishl(a, b, 32)
}

/// 32-bit arithmetic (sign-propagating) shift right; count taken modulo 32.
pub fn i32_shr_s(a: Int, b: Int) -> Int {
  ishr_s(a, b, 32)
}

/// 32-bit logical (zero-filling) shift right; count taken modulo 32.
pub fn i32_shr_u(a: Int, b: Int) -> Int {
  ishr_u(a, b, 32)
}

/// 32-bit rotate left; count taken modulo 32 (count 0 is the identity).
pub fn i32_rotl(a: Int, b: Int) -> Int {
  irotl(a, b, 32)
}

/// 32-bit rotate right; count taken modulo 32 (count 0 is the identity).
pub fn i32_rotr(a: Int, b: Int) -> Int {
  irotr(a, b, 32)
}

/// Count leading zero bits of a 32-bit value; returns 32 for input 0.
pub fn i32_clz(a: Int) -> Int {
  iclz(a, 32)
}

/// Count trailing zero bits of a 32-bit value; returns 32 for input 0.
pub fn i32_ctz(a: Int) -> Int {
  ictz(a, 32)
}

/// Population count: number of set bits in a 32-bit value (bit scan).
pub fn i32_popcnt(a: Int) -> Int {
  popcount(a, 0)
}

/// Returns `1` if the 32-bit value is zero, else `0` (i32 truth value).
pub fn i32_eqz(a: Int) -> Int {
  bool_to_i32(a == 0)
}

/// 32-bit equality (raw bits); returns the i32 truth value `1`/`0`.
pub fn i32_eq(a: Int, b: Int) -> Int {
  bool_to_i32(a == b)
}

/// 32-bit inequality (raw bits); returns the i32 truth value `1`/`0`.
pub fn i32_ne(a: Int, b: Int) -> Int {
  bool_to_i32(a != b)
}

/// 32-bit signed less-than (operands read as two's complement); i32 truth value.
pub fn i32_lt_s(a: Int, b: Int) -> Int {
  bool_to_i32(signed(a, 32) < signed(b, 32))
}

/// 32-bit unsigned less-than (raw bits); i32 truth value.
pub fn i32_lt_u(a: Int, b: Int) -> Int {
  bool_to_i32(a < b)
}

/// 32-bit signed greater-than; i32 truth value.
pub fn i32_gt_s(a: Int, b: Int) -> Int {
  bool_to_i32(signed(a, 32) > signed(b, 32))
}

/// 32-bit unsigned greater-than (raw bits); i32 truth value.
pub fn i32_gt_u(a: Int, b: Int) -> Int {
  bool_to_i32(a > b)
}

/// 32-bit signed less-than-or-equal; i32 truth value.
pub fn i32_le_s(a: Int, b: Int) -> Int {
  bool_to_i32(signed(a, 32) <= signed(b, 32))
}

/// 32-bit unsigned less-than-or-equal (raw bits); i32 truth value.
pub fn i32_le_u(a: Int, b: Int) -> Int {
  bool_to_i32(a <= b)
}

/// 32-bit signed greater-than-or-equal; i32 truth value.
pub fn i32_ge_s(a: Int, b: Int) -> Int {
  bool_to_i32(signed(a, 32) >= signed(b, 32))
}

/// 32-bit unsigned greater-than-or-equal (raw bits); i32 truth value.
pub fn i32_ge_u(a: Int, b: Int) -> Int {
  bool_to_i32(a >= b)
}

// ───────────────────────────── i32 — trapping ─────────────────────────────

/// 32-bit signed division. `Error(IntDivByZero)` if `b == 0`; `Error(IntOverflow)` for
/// `INT_MIN / -1` (`0x80000000 / 0xFFFFFFFF`); else `Ok(quotient bits)` truncated toward
/// zero.
pub fn i32_div_s(a: Int, b: Int) -> Result(Int, TrapReason) {
  idiv_s(a, b, 32)
}

/// 32-bit unsigned division. `Error(IntDivByZero)` if `b == 0`; else `Ok(quotient)`
/// (truncated toward zero).
pub fn i32_div_u(a: Int, b: Int) -> Result(Int, TrapReason) {
  idiv_u(a, b)
}

/// 32-bit signed remainder. `Error(IntDivByZero)` if `b == 0`; else `Ok(remainder)` with
/// the sign of the dividend. No overflow trap: `INT_MIN % -1 == 0`.
pub fn i32_rem_s(a: Int, b: Int) -> Result(Int, TrapReason) {
  irem_s(a, b, 32)
}

/// 32-bit unsigned remainder. `Error(IntDivByZero)` if `b == 0`; else `Ok(remainder)`.
pub fn i32_rem_u(a: Int, b: Int) -> Result(Int, TrapReason) {
  irem_u(a, b)
}

// ───────────────────────────── i64 — non-trapping ─────────────────────────────

/// 64-bit integer addition with two's-complement wrap. Never traps.
pub fn i64_add(a: Int, b: Int) -> Int {
  iadd(a, b, 64)
}

/// 64-bit integer subtraction with two's-complement wrap. Never traps.
pub fn i64_sub(a: Int, b: Int) -> Int {
  isub(a, b, 64)
}

/// 64-bit integer multiplication (low 64 bits, two's-complement wrap). Never traps.
pub fn i64_mul(a: Int, b: Int) -> Int {
  imul(a, b, 64)
}

/// 64-bit bitwise AND of the raw bit patterns.
pub fn i64_and(a: Int, b: Int) -> Int {
  int.bitwise_and(a, b)
}

/// 64-bit bitwise OR of the raw bit patterns.
pub fn i64_or(a: Int, b: Int) -> Int {
  int.bitwise_or(a, b)
}

/// 64-bit bitwise XOR of the raw bit patterns.
pub fn i64_xor(a: Int, b: Int) -> Int {
  int.bitwise_exclusive_or(a, b)
}

/// 64-bit shift left; the shift count `b` is taken modulo 64 (shift-count masking).
pub fn i64_shl(a: Int, b: Int) -> Int {
  ishl(a, b, 64)
}

/// 64-bit arithmetic (sign-propagating) shift right; count taken modulo 64.
pub fn i64_shr_s(a: Int, b: Int) -> Int {
  ishr_s(a, b, 64)
}

/// 64-bit logical (zero-filling) shift right; count taken modulo 64.
pub fn i64_shr_u(a: Int, b: Int) -> Int {
  ishr_u(a, b, 64)
}

/// 64-bit rotate left; count taken modulo 64 (count 0 is the identity).
pub fn i64_rotl(a: Int, b: Int) -> Int {
  irotl(a, b, 64)
}

/// 64-bit rotate right; count taken modulo 64 (count 0 is the identity).
pub fn i64_rotr(a: Int, b: Int) -> Int {
  irotr(a, b, 64)
}

/// Count leading zero bits of a 64-bit value; returns 64 for input 0.
pub fn i64_clz(a: Int) -> Int {
  iclz(a, 64)
}

/// Count trailing zero bits of a 64-bit value; returns 64 for input 0.
pub fn i64_ctz(a: Int) -> Int {
  ictz(a, 64)
}

/// Population count: number of set bits in a 64-bit value (bit scan).
pub fn i64_popcnt(a: Int) -> Int {
  popcount(a, 0)
}

/// Returns `1` if the 64-bit value is zero, else `0` (i32 truth value).
pub fn i64_eqz(a: Int) -> Int {
  bool_to_i32(a == 0)
}

/// 64-bit equality (raw bits); returns the i32 truth value `1`/`0`.
pub fn i64_eq(a: Int, b: Int) -> Int {
  bool_to_i32(a == b)
}

/// 64-bit inequality (raw bits); returns the i32 truth value `1`/`0`.
pub fn i64_ne(a: Int, b: Int) -> Int {
  bool_to_i32(a != b)
}

/// 64-bit signed less-than; i32 truth value.
pub fn i64_lt_s(a: Int, b: Int) -> Int {
  bool_to_i32(signed(a, 64) < signed(b, 64))
}

/// 64-bit unsigned less-than (raw bits); i32 truth value.
pub fn i64_lt_u(a: Int, b: Int) -> Int {
  bool_to_i32(a < b)
}

/// 64-bit signed greater-than; i32 truth value.
pub fn i64_gt_s(a: Int, b: Int) -> Int {
  bool_to_i32(signed(a, 64) > signed(b, 64))
}

/// 64-bit unsigned greater-than (raw bits); i32 truth value.
pub fn i64_gt_u(a: Int, b: Int) -> Int {
  bool_to_i32(a > b)
}

/// 64-bit signed less-than-or-equal; i32 truth value.
pub fn i64_le_s(a: Int, b: Int) -> Int {
  bool_to_i32(signed(a, 64) <= signed(b, 64))
}

/// 64-bit unsigned less-than-or-equal (raw bits); i32 truth value.
pub fn i64_le_u(a: Int, b: Int) -> Int {
  bool_to_i32(a <= b)
}

/// 64-bit signed greater-than-or-equal; i32 truth value.
pub fn i64_ge_s(a: Int, b: Int) -> Int {
  bool_to_i32(signed(a, 64) >= signed(b, 64))
}

/// 64-bit unsigned greater-than-or-equal (raw bits); i32 truth value.
pub fn i64_ge_u(a: Int, b: Int) -> Int {
  bool_to_i32(a >= b)
}

// ───────────────────────────── i64 — trapping ─────────────────────────────

/// 64-bit signed division. `Error(IntDivByZero)` if `b == 0`; `Error(IntOverflow)` for
/// `INT_MIN / -1`; else `Ok(quotient bits)` truncated toward zero.
pub fn i64_div_s(a: Int, b: Int) -> Result(Int, TrapReason) {
  idiv_s(a, b, 64)
}

/// 64-bit unsigned division. `Error(IntDivByZero)` if `b == 0`; else `Ok(quotient)`.
pub fn i64_div_u(a: Int, b: Int) -> Result(Int, TrapReason) {
  idiv_u(a, b)
}

/// 64-bit signed remainder. `Error(IntDivByZero)` if `b == 0`; else `Ok(remainder)` with
/// the sign of the dividend. No overflow trap: `INT_MIN % -1 == 0`.
pub fn i64_rem_s(a: Int, b: Int) -> Result(Int, TrapReason) {
  irem_s(a, b, 64)
}

/// 64-bit unsigned remainder. `Error(IntDivByZero)` if `b == 0`; else `Ok(remainder)`.
pub fn i64_rem_u(a: Int, b: Int) -> Result(Int, TrapReason) {
  irem_u(a, b)
}

// ───────────────────────────── Conversions ─────────────────────────────

/// Wrap an i64 to its low 32 bits (`i32.wrap_i64`): `x mod 2^32`. Never traps.
pub fn i32_wrap_i64(a: Int) -> Int {
  norm(a, 32)
}

/// Sign-extend an i32 to i64 (`i64.extend_i32_s`): the low-32 value read as signed,
/// re-encoded into 64 bits.
pub fn i64_extend_i32_s(a: Int) -> Int {
  norm(signed(a, 32), 64)
}

/// Zero-extend an i32 to i64 (`i64.extend_i32_u`): identity, since `x ∈ [0, 2^32)` is
/// already a valid 64-bit bit pattern.
pub fn i64_extend_i32_u(a: Int) -> Int {
  a
}

/// Sign-extend the low 8 bits of an i32 to a full i32 (`i32.extend8_s`):
/// e.g. `0x80 -> 0xFFFFFF80`.
pub fn i32_extend8_s(a: Int) -> Int {
  norm(signed(low_bits(a, 8), 8), 32)
}

/// Sign-extend the low 16 bits of an i32 to a full i32 (`i32.extend16_s`):
/// e.g. `0x8000 -> 0xFFFF8000`.
pub fn i32_extend16_s(a: Int) -> Int {
  norm(signed(low_bits(a, 16), 16), 32)
}

/// Sign-extend the low 8 bits of an i64 to a full i64 (`i64.extend8_s`).
pub fn i64_extend8_s(a: Int) -> Int {
  norm(signed(low_bits(a, 8), 8), 64)
}

/// Sign-extend the low 16 bits of an i64 to a full i64 (`i64.extend16_s`).
pub fn i64_extend16_s(a: Int) -> Int {
  norm(signed(low_bits(a, 16), 16), 64)
}

/// Sign-extend the low 32 bits of an i64 to a full i64 (`i64.extend32_s`).
pub fn i64_extend32_s(a: Int) -> Int {
  norm(signed(low_bits(a, 32), 32), 64)
}

/// Reinterpret an f32 bit pattern as i32 bits (`i32.reinterpret_f32`). A no-op on our
/// representation: floats are *already* stored as their raw bit pattern, so only the
/// static IR type changes — the bits are returned unchanged.
pub fn i32_reinterpret_f32(a: Int) -> Int {
  a
}

/// Reinterpret an f64 bit pattern as i64 bits (`i64.reinterpret_f64`). A no-op — see
/// `i32_reinterpret_f32`.
pub fn i64_reinterpret_f64(a: Int) -> Int {
  a
}

/// Reinterpret an i32 bit pattern as f32 bits (`f32.reinterpret_i32`). A no-op — see
/// `i32_reinterpret_f32`.
pub fn f32_reinterpret_i32(a: Int) -> Int {
  a
}

/// Reinterpret an i64 bit pattern as f64 bits (`f64.reinterpret_i64`). A no-op — see
/// `i32_reinterpret_f32`.
pub fn f64_reinterpret_i64(a: Int) -> Int {
  a
}

/// Saturating signed truncation f32 → i32 (`i32.trunc_sat_f32_s`); never traps.
/// NaN → 0; `-Inf` → INT_MIN; `+Inf` → INT_MAX; else truncate toward zero and clamp.
pub fn i32_trunc_sat_f32_s(a: Int) -> Int {
  trunc_sat_s(f32_fmt, a, 32)
}

/// Saturating unsigned truncation f32 → i32 (`i32.trunc_sat_f32_u`); never traps.
/// NaN → 0; `<= 0`/`-Inf` → 0; `+Inf` → UINT32_MAX; else truncate toward zero and clamp.
pub fn i32_trunc_sat_f32_u(a: Int) -> Int {
  trunc_sat_u(f32_fmt, a, 32)
}

/// Saturating signed truncation f64 → i32 (`i32.trunc_sat_f64_s`); never traps.
pub fn i32_trunc_sat_f64_s(a: Int) -> Int {
  trunc_sat_s(f64_fmt, a, 32)
}

/// Saturating unsigned truncation f64 → i32 (`i32.trunc_sat_f64_u`); never traps.
pub fn i32_trunc_sat_f64_u(a: Int) -> Int {
  trunc_sat_u(f64_fmt, a, 32)
}

/// Saturating signed truncation f32 → i64 (`i64.trunc_sat_f32_s`); never traps.
pub fn i64_trunc_sat_f32_s(a: Int) -> Int {
  trunc_sat_s(f32_fmt, a, 64)
}

/// Saturating unsigned truncation f32 → i64 (`i64.trunc_sat_f32_u`); never traps.
pub fn i64_trunc_sat_f32_u(a: Int) -> Int {
  trunc_sat_u(f32_fmt, a, 64)
}

/// Saturating signed truncation f64 → i64 (`i64.trunc_sat_f64_s`); never traps.
pub fn i64_trunc_sat_f64_s(a: Int) -> Int {
  trunc_sat_s(f64_fmt, a, 64)
}

/// Saturating unsigned truncation f64 → i64 (`i64.trunc_sat_f64_u`); never traps.
pub fn i64_trunc_sat_f64_u(a: Int) -> Int {
  trunc_sat_u(f64_fmt, a, 64)
}

// ───────────────────── private float representation helpers ─────────────────────

/// The IEEE-754 binary format of a float: total width, exponent-field width, and
/// trailing-significand (mantissa) width, all in bits.
type FloatFmt {
  FloatFmt(total: Int, ebits: Int, mbits: Int)
}

const f32_fmt = FloatFmt(total: 32, ebits: 8, mbits: 23)

const f64_fmt = FloatFmt(total: 64, ebits: 11, mbits: 52)

/// The IEEE classification of a float, with the operand's sign bit (`0` positive,
/// `1` negative) where it is meaningful.
type FClass {
  CNan
  CInf(sign: Int)
  CZero(sign: Int)
  CFinite(sign: Int)
}

/// The arithmetic kind for the finite path (subtraction is realised as `a + (-b)`).
type FBinOp {
  AddOp
  MulOp
  DivOp
}

/// The all-ones exponent field for `fmt` (the NaN/Inf exponent).
fn exp_all_ones(fmt: FloatFmt) -> Int {
  pow2(fmt.ebits) - 1
}

/// The exponent bias for `fmt` (`127` for f32, `1023` for f64).
fn fbias(fmt: FloatFmt) -> Int {
  pow2(fmt.ebits - 1) - 1
}

/// The sign bit of `bits` (`0` or `1`).
fn sign_of(fmt: FloatFmt, bits: Int) -> Int {
  int.bitwise_shift_right(bits, fmt.total - 1)
}

/// The positive canonical quiet NaN bit pattern for `fmt`
/// (`0x7FC00000` for f32, `0x7FF8000000000000` for f64).
fn canonical_nan(fmt: FloatFmt) -> Int {
  exp_all_ones(fmt) * pow2(fmt.mbits) + pow2(fmt.mbits - 1)
}

/// The `±Inf` bit pattern for `fmt` (`sign` `0` → `+Inf`, else `-Inf`).
fn float_inf(fmt: FloatFmt, sign: Int) -> Int {
  let pos = exp_all_ones(fmt) * pow2(fmt.mbits)
  case sign {
    0 -> pos
    _ -> pos + pow2(fmt.total - 1)
  }
}

/// The `±0` bit pattern for `fmt` (`sign` `0` → `+0` i.e. all-zero, else `-0`).
fn float_zero(fmt: FloatFmt, sign: Int) -> Int {
  case sign {
    0 -> 0
    _ -> pow2(fmt.total - 1)
  }
}

/// Toggle the sign bit of `bits` (negation in the bit domain).
fn flip_sign(fmt: FloatFmt, bits: Int) -> Int {
  int.bitwise_exclusive_or(bits, pow2(fmt.total - 1))
}

/// Classify `bits` as NaN / ±Inf / ±0 / finite from its exponent and mantissa fields,
/// without decoding to a native double (which cannot hold NaN/Inf).
fn classify(fmt: FloatFmt, bits: Int) -> FClass {
  let sign = sign_of(fmt, bits)
  let exp =
    int.bitwise_and(int.bitwise_shift_right(bits, fmt.mbits), exp_all_ones(fmt))
  let mant = low_bits(bits, fmt.mbits)
  case exp == exp_all_ones(fmt) {
    True ->
      case mant == 0 {
        True -> CInf(sign)
        False -> CNan
      }
    False ->
      case exp == 0 && mant == 0 {
        True -> CZero(sign)
        False -> CFinite(sign)
      }
  }
}

/// Decompose a FINITE NONZERO float into `#(sign, significand, exp2)` such that the
/// magnitude equals `significand * 2^exp2` EXACTLY (`significand` an integer ≥ 1). Used
/// for exact overflow detection and exact truncation. Not valid for NaN/Inf/zero.
fn decompose(fmt: FloatFmt, bits: Int) -> #(Int, Int, Int) {
  let sign = sign_of(fmt, bits)
  let exp =
    int.bitwise_and(int.bitwise_shift_right(bits, fmt.mbits), exp_all_ones(fmt))
  let mant = low_bits(bits, fmt.mbits)
  case exp == 0 {
    // subnormal: value = mant * 2^(1 - bias - mbits)
    True -> #(sign, mant, 1 - fbias(fmt) - fmt.mbits)
    // normal: value = (2^mbits + mant) * 2^(exp - bias - mbits)
    False -> #(sign, pow2(fmt.mbits) + mant, exp - fbias(fmt) - fmt.mbits)
  }
}

/// Apply the operand's `sign` (`0`/`1`) to a magnitude, yielding a signed integer.
fn signed_significand(sign: Int, sig: Int) -> Int {
  case sign {
    0 -> sig
    _ -> 0 - sig
  }
}

/// Decode a finite/zero 64-bit pattern into a native double. Fails (`badmatch`) on
/// NaN/Inf bits — callers must classify first.
fn bits_to_f64(bits: Int) -> Float {
  let assert <<f:float-size(64)>> = <<bits:size(64)>>
  f
}

/// Encode a finite native double into its 64-bit pattern.
fn f64_to_bits(f: Float) -> Int {
  let assert <<bits:size(64)>> = <<f:float-size(64)>>
  bits
}

/// Decode a finite/zero 32-bit pattern into a native double (widening single → double).
/// Fails on NaN/Inf bits — callers must classify first.
fn bits_to_f32(bits: Int) -> Float {
  let assert <<f:float-size(32)>> = <<bits:size(32)>>
  f
}

/// Round a native double to binary32 and return its 32-bit pattern. The 32-bit float
/// construct rounds to nearest-ties-to-even and saturates out-of-single-range
/// magnitudes to `±Inf` without raising.
fn f32_round_to_bits(f: Float) -> Int {
  let assert <<bits:size(32)>> = <<f:float-size(32)>>
  bits
}

/// Decode a finite/zero `fmt` pattern into a native double.
fn decode_float(fmt: FloatFmt, bits: Int) -> Float {
  case fmt.total {
    32 -> bits_to_f32(bits)
    _ -> bits_to_f64(bits)
  }
}

/// Apply a binary op to two native doubles (only on the all-finite path).
fn apply_double(op: FBinOp, x: Float, y: Float) -> Float {
  case op {
    AddOp -> x +. y
    MulOp -> x *. y
    DivOp -> x /. y
  }
}

/// The IEEE round-to-nearest overflow threshold for binary64: a finite result rounds to
/// `±Inf` exactly when its magnitude is `>= 2^1024 - 2^970`.
fn f64_overflow_threshold() -> Int {
  pow2(1024) - pow2(970)
}

/// Compare `s1 * 2^e1` with `s2 * 2^e2` (`s1, s2 >= 0`), exactly, as bignums.
fn mag_cmp(s1: Int, e1: Int, s2: Int, e2: Int) -> order.Order {
  let m = int.min(e1, e2)
  int.compare(s1 * pow2(e1 - m), s2 * pow2(e2 - m))
}

/// `True` iff `s1 * 2^e1 >= s2 * 2^e2`.
fn mag_geq(s1: Int, e1: Int, s2: Int, e2: Int) -> Bool {
  mag_cmp(s1, e1, s2, e2) != order.Lt
}

/// Decide whether the f64 finite-finite op `a OP b` overflows to `±Inf`.
/// `Some(sign)` → the exact result has magnitude at/above the IEEE overflow threshold,
/// so emit Inf with that sign (`0`/`1`); `None` → the BEAM op is safe (no `badarith`).
fn f64_finite_overflow(a: Int, b: Int, op: FBinOp) -> Option(Int) {
  let #(sa, ma, ea) = decompose(f64_fmt, a)
  let #(sb, mb, eb) = decompose(f64_fmt, b)
  let t = f64_overflow_threshold()
  case op {
    MulOp ->
      // |a*b| = (ma*mb) * 2^(ea+eb)
      case mag_geq(ma * mb, ea + eb, t, 0) {
        True -> Some(int.bitwise_exclusive_or(sa, sb))
        False -> None
      }
    DivOp ->
      // |a/b| >= T  <=>  ma*2^ea >= (T*mb)*2^eb
      case mag_geq(ma, ea, t * mb, eb) {
        True -> Some(int.bitwise_exclusive_or(sa, sb))
        False -> None
      }
    AddOp -> {
      // exact signed result = S * 2^c, c = min(ea, eb)
      let c = int.min(ea, eb)
      let va = signed_significand(sa, ma) * pow2(ea - c)
      let vb = signed_significand(sb, mb) * pow2(eb - c)
      let s = va + vb
      case mag_geq(int.absolute_value(s), c, t, 0) {
        True ->
          case s < 0 {
            True -> Some(1)
            False -> Some(0)
          }
        False -> None
      }
    }
  }
}

/// The all-finite-nonzero arithmetic path. For f32, compute in double and round the
/// result to binary32 (which saturates overflow to `±Inf`). For f64, first detect
/// overflow exactly (emitting signed Inf) and otherwise let BEAM compute the
/// correctly-rounded finite result.
fn finite_binop(fmt: FloatFmt, a: Int, b: Int, op: FBinOp) -> Int {
  case fmt.total {
    32 -> f32_round_to_bits(apply_double(op, bits_to_f32(a), bits_to_f32(b)))
    _ ->
      case f64_finite_overflow(a, b, op) {
        Some(sign) -> float_inf(fmt, sign)
        None -> f64_to_bits(apply_double(op, bits_to_f64(a), bits_to_f64(b)))
      }
  }
}

/// IEEE-754 addition on raw bit patterns, with NaN → canonical, Inf/zero by IEEE rules.
fn fadd(fmt: FloatFmt, a: Int, b: Int) -> Int {
  case classify(fmt, a), classify(fmt, b) {
    CNan, _ -> canonical_nan(fmt)
    _, CNan -> canonical_nan(fmt)
    CInf(sa), CInf(sb) ->
      // +Inf + -Inf is NaN; same-sign Infs add to that Inf.
      case sa == sb {
        True -> float_inf(fmt, sa)
        False -> canonical_nan(fmt)
      }
    CInf(sa), _ -> float_inf(fmt, sa)
    _, CInf(sb) -> float_inf(fmt, sb)
    CZero(sa), CZero(sb) ->
      // -0 only when both addends are -0; otherwise +0 (round-to-nearest).
      case sa == 1 && sb == 1 {
        True -> float_zero(fmt, 1)
        False -> float_zero(fmt, 0)
      }
    CZero(_), _ -> b
    _, CZero(_) -> a
    CFinite(_), CFinite(_) -> finite_binop(fmt, a, b, AddOp)
  }
}

/// IEEE-754 subtraction: `a - b = a + (-b)`.
fn fsub(fmt: FloatFmt, a: Int, b: Int) -> Int {
  fadd(fmt, a, flip_sign(fmt, b))
}

/// IEEE-754 multiplication on raw bit patterns.
fn fmul(fmt: FloatFmt, a: Int, b: Int) -> Int {
  case classify(fmt, a), classify(fmt, b) {
    CNan, _ -> canonical_nan(fmt)
    _, CNan -> canonical_nan(fmt)
    CZero(_), CInf(_) -> canonical_nan(fmt)
    CInf(_), CZero(_) -> canonical_nan(fmt)
    CInf(sa), CInf(sb) -> float_inf(fmt, int.bitwise_exclusive_or(sa, sb))
    CInf(sa), CFinite(sb) -> float_inf(fmt, int.bitwise_exclusive_or(sa, sb))
    CFinite(sa), CInf(sb) -> float_inf(fmt, int.bitwise_exclusive_or(sa, sb))
    CZero(sa), CZero(sb) -> float_zero(fmt, int.bitwise_exclusive_or(sa, sb))
    CZero(sa), CFinite(sb) -> float_zero(fmt, int.bitwise_exclusive_or(sa, sb))
    CFinite(sa), CZero(sb) -> float_zero(fmt, int.bitwise_exclusive_or(sa, sb))
    CFinite(_), CFinite(_) -> finite_binop(fmt, a, b, MulOp)
  }
}

/// IEEE-754 division on raw bit patterns.
fn fdiv(fmt: FloatFmt, a: Int, b: Int) -> Int {
  case classify(fmt, a), classify(fmt, b) {
    CNan, _ -> canonical_nan(fmt)
    _, CNan -> canonical_nan(fmt)
    CInf(_), CInf(_) -> canonical_nan(fmt)
    CZero(_), CZero(_) -> canonical_nan(fmt)
    CInf(sa), CZero(sb) -> float_inf(fmt, int.bitwise_exclusive_or(sa, sb))
    CInf(sa), CFinite(sb) -> float_inf(fmt, int.bitwise_exclusive_or(sa, sb))
    CZero(sa), CInf(sb) -> float_zero(fmt, int.bitwise_exclusive_or(sa, sb))
    CFinite(sa), CInf(sb) -> float_zero(fmt, int.bitwise_exclusive_or(sa, sb))
    CZero(sa), CFinite(sb) -> float_zero(fmt, int.bitwise_exclusive_or(sa, sb))
    CFinite(sa), CZero(sb) -> float_inf(fmt, int.bitwise_exclusive_or(sa, sb))
    CFinite(_), CFinite(_) -> finite_binop(fmt, a, b, DivOp)
  }
}

/// WASM `fmin` on raw bit patterns: either NaN → canonical NaN; opposite-signed zeroes
/// → `-0`; else the numerically smaller value (with `-Inf`/`+Inf` handled directly).
fn fmin(fmt: FloatFmt, a: Int, b: Int) -> Int {
  case classify(fmt, a), classify(fmt, b) {
    CNan, _ -> canonical_nan(fmt)
    _, CNan -> canonical_nan(fmt)
    CZero(sa), CZero(sb) ->
      // min of signed zeroes is -0 whenever either is -0.
      case sa == 1 || sb == 1 {
        True -> float_zero(fmt, 1)
        False -> float_zero(fmt, 0)
      }
    CInf(1), _ -> a
    CInf(0), _ -> b
    _, CInf(1) -> b
    _, CInf(0) -> a
    _, _ -> {
      let da = decode_float(fmt, a)
      let db = decode_float(fmt, b)
      case da <. db {
        True -> a
        False ->
          case db <. da {
            True -> b
            False -> a
          }
      }
    }
  }
}

/// WASM `fmax` on raw bit patterns: either NaN → canonical NaN; opposite-signed zeroes
/// → `+0`; else the numerically larger value (with `-Inf`/`+Inf` handled directly).
fn fmax(fmt: FloatFmt, a: Int, b: Int) -> Int {
  case classify(fmt, a), classify(fmt, b) {
    CNan, _ -> canonical_nan(fmt)
    _, CNan -> canonical_nan(fmt)
    CZero(sa), CZero(sb) ->
      // max of signed zeroes is +0 whenever either is +0.
      case sa == 0 || sb == 0 {
        True -> float_zero(fmt, 0)
        False -> float_zero(fmt, 1)
      }
    CInf(0), _ -> a
    CInf(1), _ -> b
    _, CInf(0) -> b
    _, CInf(1) -> a
    _, _ -> {
      let da = decode_float(fmt, a)
      let db = decode_float(fmt, b)
      case da >. db {
        True -> a
        False ->
          case db >. da {
            True -> b
            False -> a
          }
      }
    }
  }
}

/// The exact truncation-toward-zero of a finite float, as a (possibly huge) signed
/// integer. Computed from the exact significand decomposition, so it is precise even for
/// magnitudes far outside the i32/i64 range (the caller then clamps).
fn trunc_integer(fmt: FloatFmt, bits: Int) -> Int {
  let #(sign, sig, exp) = decompose(fmt, bits)
  let mag = case exp >= 0 {
    True -> sig * pow2(exp)
    // sig >= 0, so integer division truncates the magnitude toward zero.
    False -> sig / pow2(0 - exp)
  }
  signed_significand(sign, mag)
}

/// Saturating signed float→int truncation to `target_bits` (`i.._trunc_sat_.._s`).
/// NaN → 0; `-Inf` → INT_MIN; `+Inf` → INT_MAX; else truncate toward zero, clamp to
/// `[-2^(N-1), 2^(N-1)-1]`, and re-encode to the unsigned bit pattern.
fn trunc_sat_s(fmt: FloatFmt, bits: Int, target_bits: Int) -> Int {
  let lo = int_min_signed(target_bits)
  let hi = pow2(target_bits - 1) - 1
  case classify(fmt, bits) {
    CNan -> 0
    CInf(0) -> hi
    CInf(_) -> norm(lo, target_bits)
    CZero(_) -> 0
    CFinite(_) -> norm(int.clamp(trunc_integer(fmt, bits), lo, hi), target_bits)
  }
}

/// Saturating unsigned float→int truncation to `target_bits` (`i.._trunc_sat_.._u`).
/// NaN → 0; `<= 0`/`-Inf` → 0; `+Inf` → `2^N - 1`; else truncate toward zero and clamp
/// to `[0, 2^N - 1]`.
fn trunc_sat_u(fmt: FloatFmt, bits: Int, target_bits: Int) -> Int {
  let hi = pow2(target_bits) - 1
  case classify(fmt, bits) {
    CNan -> 0
    CInf(0) -> hi
    CInf(_) -> 0
    CZero(_) -> 0
    CFinite(1) -> 0
    CFinite(_) -> int.clamp(trunc_integer(fmt, bits), 0, hi)
  }
}

// ───────────────────────────── f32 (raw bits) ─────────────────────────────

/// 32-bit float addition; operands and result are raw binary32 bit patterns. NaN in or
/// produced → canonical NaN (`0x7FC00000`); ±Inf/±0 by IEEE; overflow → signed Inf.
pub fn f32_add(a: Int, b: Int) -> Int {
  fadd(f32_fmt, a, b)
}

/// 32-bit float subtraction; raw binary32 bit patterns. (`a - b = a + (-b)`.)
pub fn f32_sub(a: Int, b: Int) -> Int {
  fsub(f32_fmt, a, b)
}

/// 32-bit float multiplication; raw binary32 bit patterns. `0 * Inf` → canonical NaN.
pub fn f32_mul(a: Int, b: Int) -> Int {
  fmul(f32_fmt, a, b)
}

/// 32-bit float division; raw binary32 bit patterns. `x / 0` → signed Inf; `0/0` and
/// `Inf/Inf` → canonical NaN.
pub fn f32_div(a: Int, b: Int) -> Int {
  fdiv(f32_fmt, a, b)
}

/// 32-bit float minimum (WASM semantics); raw binary32 bit patterns. NaN → canonical
/// NaN; `min(+0, -0)` → `-0`.
pub fn f32_min(a: Int, b: Int) -> Int {
  fmin(f32_fmt, a, b)
}

/// 32-bit float maximum (WASM semantics); raw binary32 bit patterns. NaN → canonical
/// NaN; `max(+0, -0)` → `+0`.
pub fn f32_max(a: Int, b: Int) -> Int {
  fmax(f32_fmt, a, b)
}

// ───────────────────────────── f64 (raw bits) ─────────────────────────────

/// 64-bit float addition; operands and result are raw binary64 bit patterns. NaN in or
/// produced → canonical NaN (`0x7FF8000000000000`); ±Inf/±0 by IEEE; overflow → signed
/// Inf (computed exactly, never `badarith`).
pub fn f64_add(a: Int, b: Int) -> Int {
  fadd(f64_fmt, a, b)
}

/// 64-bit float subtraction; raw binary64 bit patterns. (`a - b = a + (-b)`.)
pub fn f64_sub(a: Int, b: Int) -> Int {
  fsub(f64_fmt, a, b)
}

/// 64-bit float multiplication; raw binary64 bit patterns. `0 * Inf` → canonical NaN.
pub fn f64_mul(a: Int, b: Int) -> Int {
  fmul(f64_fmt, a, b)
}

/// 64-bit float division; raw binary64 bit patterns. `x / 0` → signed Inf; `0/0` and
/// `Inf/Inf` → canonical NaN.
pub fn f64_div(a: Int, b: Int) -> Int {
  fdiv(f64_fmt, a, b)
}

/// 64-bit float minimum (WASM semantics); raw binary64 bit patterns. NaN → canonical
/// NaN; `min(+0, -0)` → `-0`.
pub fn f64_min(a: Int, b: Int) -> Int {
  fmin(f64_fmt, a, b)
}

/// 64-bit float maximum (WASM semantics); raw binary64 bit patterns. NaN → canonical
/// NaN; `max(+0, -0)` → `+0`.
pub fn f64_max(a: Int, b: Int) -> Int {
  fmax(f64_fmt, a, b)
}
