# Unit 06 — rt_num float extension (the remaining float surface)

> **One owner · Wave A · gated on `«RTNUM2-SIG-FROZEN»` (P2-01).** Additive, single-file
> (`rt_num.gleam` bodies + its test module). No IR/ABI/decoder changes — you fill the `todo`
> heads P2-01 froze. Read [`00-overview.md`](00-overview.md) (E1–E8) and
> [`01-interface-freeze.md`](01-interface-freeze.md) §D first; D1–D10 and §9.1 still hold.

---

## Context

Phase 1 shipped `rt_num` as the single auditable numeric-fidelity chokepoint (D2): all
integer ops, the float **arithmetic** (`f32/f64` add/sub/mul/div/min/max), the 8 saturating
`trunc_sat`, every reinterpret, and the integer wrap/extend conversions — 90 functions,
property-tested, zero-warning. Floats are stored as **raw IEEE-754 bit patterns in an `Int`**
(D5), never BEAM doubles (which raise `badarith` on NaN/Inf). That representation, the
**canonical-NaN lock** (NaN-producing ops return the positive canonical NaN), the **f32
round-to-single** helper (`<<F:32/float>>`, which rounds ties-to-even and saturates overflow
to ±Inf without raising), and the **exact f64-overflow-to-Inf** guard are all proven and
reused verbatim here.

What is still missing is the rest of the WASM scalar float surface: the unary ops, copysign,
the six comparisons, the **trapping** float→int truncations, int→float conversions, and
demote/promote. P2-01 has frozen their signatures as `todo` heads (`«RTNUM2-SIG-FROZEN»`).
This unit fills the bodies, bit-exactly, against the WASM numerics spec.

## Goal

Implement the **46 remaining `rt_num` float/convert functions** so they match
[`exec/numerics`](https://webassembly.github.io/spec/core/exec/numerics.html) bit-for-bit,
reusing the Phase-1 representation and private helpers. Prove correctness with spec-cited
unit tests (not change-detector tests). These bodies are what lets the capstone (unit 11)
flip the float conformance files skip→pass.

## Files owned

- `src/twocore/runtime/rt_num.gleam` — **EXTEND** (single-owner, additive). Fill the 46 `todo`
  bodies P2-01 published; add the private workers below. Do **not** touch the Phase-1 public
  functions or their helpers except to call them.
- `test/twocore/runtime/rt_num_floats_test.gleam` — **NEW** (your spec-corner suite). (Keep
  the existing Phase-1 `rt_num` test module untouched and green.)

## Depends on

- **`«RTNUM2-SIG-FROZEN»` (P2-01)** — the 46 frozen heads + the new `ir.TrapReason`
  `InvalidConversionToInteger`. If that stub has not landed, you may start against the
  signature list in [`01-interface-freeze.md`](01-interface-freeze.md) §D and re-sync when it
  lands; the names/arities are fixed there and must not drift (unit 10's `NumOp/ConvOp →
  fn-name` map binds to them).

Nothing else. You need no runtime state, no decoder, no emit_core. Pure Gleam over bignums.

## Scope — in / out for Phase 2

**In** (the 46 public fns, all operating on raw bit patterns):

| Group | Functions (per width `w ∈ {f32, f64}` unless noted) | Result |
|---|---|---|
| Unary | `w_abs`, `w_neg`, `w_ceil`, `w_floor`, `w_trunc`, `w_nearest`, `w_sqrt` (14) | `Int` (bits) |
| Copysign | `w_copysign(a, b)` (2) | `Int` (bits) |
| Comparisons | `w_eq`, `w_ne`, `w_lt`, `w_gt`, `w_le`, `w_ge` (12) | `Int` (i32 `0`/`1`) |
| Trapping float→int | `i32_trunc_f32_s/u`, `i32_trunc_f64_s/u`, `i64_trunc_f32_s/u`, `i64_trunc_f64_s/u` (8) | `Result(Int, TrapReason)` |
| int→float convert | `f32_convert_i32_s/u`, `f32_convert_i64_s/u`, `f64_convert_i32_s/u`, `f64_convert_i64_s/u` (8) | `Int` (bits) |
| demote/promote | `f32_demote_f64`, `f64_promote_f32` (2) | `Int` (bits) |

**Out** (already done — reuse, do not reimplement): `f32/f64` add/sub/mul/div/min/max, the 8
`trunc_sat`, the 4 reinterprets, `i32_wrap_i64`, `i64_extend_i32_s/u`, the `extendN_s` ops.
The integer wrap/extend/reinterpret gap is the **decoder** (unit 07), not `rt_num` — do not
add opcodes here. Deferred entirely (E8): SIMD/relaxed-simd float ops, `fma`. No new
`TrapReason` beyond `InvalidConversionToInteger` (reuse existing `IntOverflow`).

## Deliverables

### New private workers to add (then the public fns are one-liners over them)

```gleam
type RoundMode { RCeil  RFloor  RTrunc  RNearest }

/// ceil/floor/trunc/nearest share this. NaN→canonical; ±Inf→bits; ±0→bits;
/// finite→integral per `mode`, preserving the operand's sign on a zero result.
fn round_to_integral(fmt: FloatFmt, bits: Int, mode: RoundMode) -> Int

/// Encode a signed integer magnitude back to `fmt` bits, EXACTLY (|v| within the
/// format's exact-integer range on the round path: ≤2^23 for f32, ≤2^52 for f64).
fn encode_int_magnitude(fmt: FloatFmt, sign: Int, m: Int) -> Int

/// Ordering of two non-NaN operands; Error(Nil) iff EITHER operand is NaN.
fn fcmp(fmt: FloatFmt, a: Int, b: Int) -> Result(order.Order, Nil)

/// Trapping float→int workers (target width N). Error(InvalidConversionToInteger)
/// on NaN/±Inf; Error(IntOverflow) if the exact truncation is out of [lo,hi]/[0,hi].
fn trunc_trap_s(fmt: FloatFmt, bits: Int, n: Int) -> Result(Int, TrapReason)
fn trunc_trap_u(fmt: FloatFmt, bits: Int, n: Int) -> Result(Int, TrapReason)
```

`gleam/float` (for `square_root`) and the existing `gleam/order` import are needed; add
`import gleam/float`. **Reuse** these existing private helpers verbatim — do not duplicate:
`pow2`, `norm`, `signed`, `int_min_signed`, `low_bits`, `bool_to_i32`, `FloatFmt`/`f32_fmt`/
`f64_fmt`, `FClass`/`classify`, `decompose`, `sign_of`, `flip_sign`, `float_zero`,
`float_inf`, `canonical_nan`, `bits_to_f32`, `bits_to_f64`, `f64_to_bits`,
`f32_round_to_bits`, `decode_float`, `trunc_integer`.

### Algorithm shape (transcribe from the grounded recipe; each line is load-bearing)

**Unary `abs`/`neg`/`copysign` — PURE sign-bit ops, MUST NOT canonicalize NaN:**
```
w_abs(bits)        : case sign_of(fmt,bits) { 1 -> flip_sign(fmt,bits) ; 0 -> bits }
w_neg(bits)        : flip_sign(fmt,bits)                       // always toggle sign
w_copysign(a, b)   : case sign_of(fmt,b) == sign_of(fmt,a) { True -> a ; False -> flip_sign(fmt,a) }
```
These keep the operand's mantissa/payload. The conformance suite asserts
`f32.abs(nan:0x200000) == nan:0x200000` and `copysign` preserves payload, so routing them
through `canonical_nan` would **fail conformance**.

**`round_to_integral(fmt, bits, mode)`** (drives ceil/floor/trunc/nearest — these four DO
canonicalize NaN, per the spec's `nans_N{z}`):
```
classify(fmt,bits):
  CNan       -> canonical_nan(fmt)
  CInf(_)    -> bits                      // return that infinity unchanged
  CZero(_)   -> bits                      // return that signed zero unchanged
  CFinite(s) -> let #(_, sig, exp2) = decompose(fmt, bits)
                if exp2 >= 0 -> bits      // already integral
                else:
                  f = -exp2               // # fractional bits (>0)
                  q = sig / pow2(f)       // truncated magnitude (≥0)
                  r = sig - q*pow2(f)     // remainder, 0 ≤ r < 2^f
                  m = case mode {
                    RTrunc   -> q
                    RCeil    -> if s==0 { q + (if r>0 {1} else {0}) } else { q }   // toward +inf
                    RFloor   -> if s==1 { q + (if r>0 {1} else {0}) } else { q }   // toward -inf
                    RNearest -> half = pow2(f-1)
                                case int.compare(r, half) {
                                  Lt -> q ; Gt -> q+1
                                  Eq -> if q%2==0 { q } else { q+1 } }             // TIES TO EVEN
                  }
                  if m == 0 -> float_zero(fmt, s)              // signed zero = operand's sign
                  else      -> encode_int_magnitude(fmt, s, m)
encode_int_magnitude(fmt,s,m): v = if s==0 {m} else {-m}
  f32 -> f32_round_to_bits(int.to_float(v))   // exact, |v| ≤ 2^23 on this path
  f64 -> f64_to_bits(int.to_float(v))         // exact, |v| ≤ 2^52
```
`w_ceil/floor/trunc/nearest` = `round_to_integral(fmt, bits, R…)`.

**`w_sqrt(bits)`:**
```
CNan -> canonical_nan(fmt) ; CInf(0) -> bits ; CInf(_) -> canonical_nan(fmt)  // -Inf -> NaN
CZero(_) -> bits                                                              // ±0 -> same signed zero
CFinite(1) -> canonical_nan(fmt)                                              // negative -> NaN
CFinite(0) -> let d = decode_float(fmt, bits)
              let assert Ok(s) = float.square_root(d)        // d positive finite -> never Error
              fmt.total==32 ? f32_round_to_bits(s) : f64_to_bits(s)
```
`float.square_root` is only ever reached on positive-finite `d`, so the `let assert Ok` is
genuinely unreachable-on-`Error` — document it. The f32 path through the f64 `s` is correctly
single-rounded (see grounded facts).

**`fcmp` + comparisons** (→ i32 `0`/`1`):
```
fcmp(fmt,a,b):
  CNan,_ | _,CNan       -> Error(Nil)            // NaN present
  CInf(0),CInf(0)       -> Ok(Eq)   ; CInf(1),CInf(1) -> Ok(Eq)
  CInf(0),_ -> Ok(Gt)   ; _,CInf(0) -> Ok(Lt)
  CInf(1),_ -> Ok(Lt)   ; _,CInf(1) -> Ok(Gt)
  _,_       -> da=decode_float(fmt,a) ; db=decode_float(fmt,b)   // both zero/finite -> decodable
               da <. db ? Ok(Lt) : (da >. db ? Ok(Gt) : Ok(Eq))
w_eq = bool_to_i32(fcmp == Ok(Eq))      w_ne = bool_to_i32(fcmp != Ok(Eq))   // NaN -> ne=1, eq=0
w_lt = bool_to_i32(fcmp == Ok(Lt))      w_gt = bool_to_i32(fcmp == Ok(Gt))
w_le = bool_to_i32(fcmp ∈ {Ok(Lt),Ok(Eq)})   w_ge = bool_to_i32(fcmp ∈ {Ok(Gt),Ok(Eq)})
```
`Error(Nil)` (NaN) makes eq/lt/gt/le/ge all `0` and ne `1`. `-0.0` and `+0.0` both decode and
compare neither `<.` nor `>.` → `Ok(Eq)` → `eq=1`, `lt=0`, `ne=0`. **Never** decode ±Inf to a
double (it `badmatch`es) — handle CInf by sign ordering *before* decoding.

**Trapping float→int** (`Result(Int, TrapReason)`):
```
trunc_trap_s(fmt,bits,N): lo = int_min_signed(N) ; hi = pow2(N-1) - 1
  CNan|CInf(_) -> Error(InvalidConversionToInteger)
  CZero(_)     -> Ok(0)
  CFinite(_)   -> j = trunc_integer(fmt,bits)        // EXACT toward-zero, bignum
                  (lo <= j && j <= hi) ? Ok(norm(j,N)) : Error(IntOverflow)
trunc_trap_u(fmt,bits,N): hi = pow2(N) - 1
  CNan|CInf(_) -> Error(InvalidConversionToInteger)
  CZero(_)     -> Ok(0)
  CFinite(_)   -> j = trunc_integer(fmt,bits)
                  (0 <= j && j <= hi) ? Ok(j) : Error(IntOverflow)
```
The 8 public fns pick `fmt`/`N`/signedness. `norm(j,N)` re-encodes the signed result to the
unsigned bit pattern (so `i32_trunc_f32_s(-1.0)` → `0xFFFFFFFF`, never a raw negative `Int`).
emit_core (unit 10) wires these exactly like `idiv_s`: call, `case` on `{ok,_}/{error,R}`,
raise on error.

**int→float convert** (never traps, never overflows to Inf):
```
v = (signed variant) ? signed(bits, M) : bits     // M = source int width; _u uses raw bits
f64 target -> f64_to_bits(int.to_float(v))         // erlang:float = round-ties-even (verified)
f32 target -> f32_round_to_bits(int.to_float(v))
```

**demote / promote:**
```
f32_demote_f64(bits): CNan -> canonical_nan(f32_fmt) ; CInf(s) -> float_inf(f32_fmt,s)
  CZero(s) -> float_zero(f32_fmt,s) ; CFinite(_) -> f32_round_to_bits(bits_to_f64(bits))   // may overflow -> ±Inf
f64_promote_f32(bits): CNan -> canonical_nan(f64_fmt) ; CInf(s) -> float_inf(f64_fmt,s)
  CZero(s) -> float_zero(f64_fmt,s) ; CFinite(_) -> f64_to_bits(bits_to_f32(bits))          // EXACT widening
```
Promote is exact for every non-NaN (no rounding); a signaling f32 NaN promotes to the **quiet
canonical f64 NaN** under the lock.

Every public function gets a `///` doc comment stating: what it computes, that operands/result
are raw bit patterns, the NaN behaviour (canonicalizes vs preserves payload), and — for the
trapping fns — exactly which inputs give `Error(InvalidConversionToInteger)` vs
`Error(IntOverflow)` vs `Ok`.

## Grounded facts you MUST honor

Source: [`exec/numerics`](https://webassembly.github.io/spec/core/exec/numerics.html) and the
verbatim `numerics.rst`; behaviours empirically re-verified on the installed OTP 29 / gleam 1.17.

- **Global rounding:** "All operators use round-to-nearest ties-to-even, except where otherwise
  specified." `fnearest` is round-to-nearest **ties-to-EVEN**: `nearest(2.5)=2`, `nearest(3.5)=4`,
  `nearest(-2.5)=-2`, `nearest(0.5)=0`. **`erlang:round/1` rounds half AWAY from zero**
  (`round(2.5)=3`, `round(-2.5)=-3`) and `floor(x+0.5)` are both WRONG — use the exact
  remainder-vs-half / even-parity tiebreak above.
- **abs/neg/copysign DO NOT canonicalize.** They are deterministic sign-bit ops that preserve
  the NaN payload (spec does not list them in `nans`). Only the nondeterministic-NaN ops
  (arith, min/max, **sqrt, ceil/floor/trunc/nearest, demote, promote, convert-with-rounding**)
  canonicalize. This is the trickiest correctness split in the unit.
- **ceil/floor/trunc/nearest/sqrt short-circuits:** return the operand UNCHANGED for ±Inf and
  the SAME signed zero for ±0; only the finite-nonzero branch does work. Signed-zero results
  also arise on small finite inputs (`ceil(-0.5)=-0`, `floor(0.5)=+0`, `trunc(0.7)=+0`,
  `trunc(-0.7)=-0`, `nearest(0.3)=+0`, `nearest(-0.3)=-0`) — the zero's sign equals the
  operand's. Integer-returning BIFs (`erlang:trunc/round`) and `float(0)` drop this sign.
- **Trapping trunc ranges (exact, asymmetric):** signed `-2^(N-1) ≤ j ≤ 2^(N-1)-1`; unsigned
  `0 ≤ j ≤ 2^N-1`. Use `trunc_integer`'s EXACT bignum so the boundary is precise:
  `i32_trunc_f32_s(2^31)` (= `2147483648.0`) → `Error(IntOverflow)`, but the largest f32 below
  2^31 = `2147483520.0` (`0x4EFFFFFF`) → `Ok`; `-2^31` is exactly representable → `Ok` (INT_MIN).
  NaN and ±Inf → `Error(InvalidConversionToInteger)`. **Two distinct reasons — do not collapse
  them** (`InvalidConversionToInteger` ↦ "invalid conversion to integer"; `IntOverflow` ↦
  "integer overflow").
- **convert sign interpretation:** `_s` uses `signed(bits, M)`; `_u` uses the raw stored bit
  pattern. Mixing them flips negative i32/i64 and i64 ≥ 2^63. None overflow to Inf
  (`max|i64| = 2^63 < f32_max = 2^128`). `erlang:float/1` (= `int.to_float`) is correctly
  ties-to-even for i64/u64→f64 (verified: `float(2^53+1)=2^53`, `float(2^53+3)=2^53+4`,
  `float(2^64-1)=2^64`).
- **i64→f32 single-rounding via the f64 intermediate is CORRECT, not a bug.** `f32_round_to_bits
  (int.to_float(v))` goes i64→f64→f32, but f64's 53 significand bits satisfy the double-rounding
  bound `53 ≥ 2·24 + 2 = 50`, so the result equals the correctly single-rounded f32. Do **not**
  try to avoid the f64 step — it is provably equal to single-rounding and simpler. (See the
  reconciliation note in the return message: the brief's "NOT i64→f64→f32 double-rounding"
  describes the required *result*, which this path delivers.)
- **demote can overflow to ±Inf** (it is `ieee_32` rounding); `<<F:32/float>>` saturates large
  doubles to ±Inf without raising (verified `1.0e300 → 0x7F800000`). promote is EXACT for all
  non-NaN.
- **`<<F:32/float>>` rounds ties-to-even AND saturates** (`16777217.0→2^24`, `16777219.0→2^24+4`,
  `1.0e300→Inf`). `bits_to_f32`/`bits_to_f64` `badmatch` on NaN/Inf bits — classify FIRST. After
  OTP 27, literal `0.0` no longer pattern-matches `-0.0`; compare zeros with `==.`/`<.`, never
  bit/literal patterns.

## Verification — Definition of Done (D8)

Write `test/twocore/runtime/rt_num_floats_test.gleam` asserting the **spec**, not the impl
(no change-detector tests). Cite the spec section in each test. Cover at minimum (f32 and f64):

- **nearest ties-to-even:** `2.5→2`, `3.5→4`, `-2.5→-2`, `0.5→0`, `-0.5→-0` (assert the sign of
  the zero by bit pattern, not by `==.`).
- **ceil/floor/trunc signed zero:** `ceil(-0.5)=-0`, `floor(0.5)=+0`, `trunc(-0.7)=-0`; ±Inf and
  ±0 pass through unchanged; NaN→canonical (`0x7FC00000`/`0x7FF8000000000000`).
- **sqrt:** `sqrt(4)=2`, `sqrt(-1)=`canonical NaN, `sqrt(-Inf)=`NaN, `sqrt(+Inf)=+Inf`,
  `sqrt(-0)=-0` (bit-exact), `sqrt(0x200000-payload NaN)=`canonical.
- **abs/neg/copysign payload preservation:** `abs(nan:0x7FA00000)=0x7FA00000` (NOT canonical),
  `neg(+3)=-3`, `copysign(3.0,-2.0)=-3.0`, `copysign(-3.0,2.0)=+3.0`, `copysign` carries `b`'s
  sign onto `a`'s magnitude+payload.
- **comparisons:** `eq(NaN,1)=0`, `lt(NaN,1)=0`, `ge(NaN,1)=0`, `ne(NaN,1)=1`; `eq(-0.0,+0.0)=1`,
  `lt(-0.0,+0.0)=0`, `ne(-0.0,+0.0)=0`; `lt(-Inf,+Inf)=1`, `gt(+Inf,finite)=1`.
- **trapping trunc boundaries:** `i32_trunc_f32_s(2147483648.0)=Error(IntOverflow)`;
  `i32_trunc_f32_s(2147483520.0)=Ok(2147483520)`; `i32_trunc_f32_s(-2147483648.0)=Ok(0x80000000)`;
  `i32_trunc_f32_s(NaN)=Error(InvalidConversionToInteger)`; `…(±Inf)=Error(InvalidConversionToInteger)`;
  `i32_trunc_f32_s(-1.0)=Ok(0xFFFFFFFF)`; one unsigned case e.g. `i32_trunc_f32_u(-1.0)=Error(IntOverflow)`
  and `i32_trunc_f64_u(4294967296.0)=Error(IntOverflow)`.
- **convert:** `f64_convert_i32_s(-1)`= bits of `-1.0`; `f32_convert_i64_s(16777217)`= bits of
  `16777216.0` (single-rounded), `f32_convert_i64_s(16777219)`= bits of `16777220.0`;
  `f64_convert_i64_u(0xFFFFFFFFFFFFFFFF)`= bits of `2^64`.
- **demote/promote:** `f32_demote_f64(bits of 1.0e300)=0x7F800000` (overflow→+Inf);
  `f64_promote_f32(0x7FA00000 sNaN)=`canonical f64 NaN; `promote` of finite/±Inf/±0 round-trips
  exactly; `demote(-0.0)=-0.0` f32, `promote(-0.0)=-0.0` f64 (bit-exact).

Then: `gleam format --check src test` clean; `gleam build` **zero warnings** (your bodies erase
the 46 `todo` warnings); `gleam test` stays green (≥313, and grows by your new tests). Every
new public fn has a `///` contract comment.

**Proving the goal beyond the unit suite:** these bodies are the numeric oracle for the float
conformance files the capstone (unit 11) enables. Once 06 + 07 (decode) + 08 (validate) + 09
(lower) + 10 (emit) are wired, unit 11 flips these to pass (the brief's proof target):
`f32`, `f64`, `f32_cmp`, `f64_cmp`, `f32_bitwise`, `f64_bitwise`, `float_misc`, `float_exprs`,
and **stops skipping `conversions.wast`'s 67 trapping float→int asserts** (35 "integer
overflow" + 32 "invalid conversion to integer") plus its convert/promote/demote/non-saturating-
trunc returns. A correct `rt_num` here is the necessary condition for that ~12k-assertion float
jump; the allowlist edit itself is unit 11's file (`vendor/ALLOWLIST`), not yours.

## Concurrency

Naturally splits into independent sub-tasks (one file, but disjoint function groups; merge
cleanly):

1. **Unary + sqrt + copysign** (`round_to_integral`, `encode_int_magnitude`, the 16 fns).
2. **Comparisons** (`fcmp` + 12 fns).
3. **Trapping trunc** (`trunc_trap_s/u` + 8 fns).
4. **Convert + demote/promote** (10 fns).

Nothing here must be frozen first beyond `«RTNUM2-SIG-FROZEN»`. All sub-tasks reuse the same
existing helpers and add private workers that don't collide. There are no cross-unit
dependencies — 06 is a leaf in the DAG (unit 10 consumes the *signatures*, already frozen).

## What this leaves for others

- **Unit 10 (emit_core):** maps the new `NumOp` (`FAbs`…`FGe`, `FCopysign`) and `ConvOp`
  (`TruncS/U`, `ConvertS/U`, `Demote`, `Promote`) to these `rt_num` calls — bare `Int` for all
  except the trapping `TruncS/U`, which return `Result` and lower like `IDivS` (`case` +
  `rt_trap:raise`). The frozen seam table in [`01`](01-interface-freeze.md) §B already pins this.
- **Unit 11 (capstone):** adds the float + conversions conformance files to the allowlist and
  records the skip list (the 78 text-format `float_literals` malformed cases, etc., per the
  research allowlist) — gated on this unit's bit-exactness.
