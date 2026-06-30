# Unit 06 — `rt_num` numeric fidelity (the `bif` reference impl)

> **1 owner (splittable into 3 sub-tasks — see Concurrency). Wave A. Genuinely
> independent of every other unit.** Only freeze dependency: **«RTNUM-SIG-FROZEN»**
> (the function heads in `runtime/rt_num.gleam`, frozen by unit 01). Semantics are the
> WASM numerics spec — you do not wait on any sibling unit's behaviour.

## Context

This unit fills in the **bodies** of `src/twocore/runtime/rt_num.gleam`, whose
*signatures* unit 01 froze. Per **D2** this module is the single auditable home of
numeric fidelity: the generated Core Erlang calls these functions at run time (it does
**not** inline arithmetic), and per **D3** trapping ops return a `Result` — `rt_num`
**never** calls `rt_trap`; the emitter (`08`) raises. This is the **tier-P `bif`
reference implementation**: every later/optimized/NIF numeric tier is *differentially
tested against this module*, so "spec-correct here" is the definition of correct
everywhere. Read [`00-overview.md`](00-overview.md) (D2/D3/D5/D8/D9) and high-level
[§9.1](../00-high-level.md) first; this doc does not repeat them.

## Goal

Implement the WASM low-level numeric semantics (high-level §9.1) in **pure Gleam** over
BEAM bignums + bit syntax, **exactly**, and prove it with property tests + spec vectors.
Measurable done: every spec-vector in *Verification* passes, the full i32/i64 surface +
conversions + reinterpret + the in-scope float ops are covered, `gleam test` is green,
`gleam format --check` is clean, `gleam build` has zero warnings.

## Files owned

- `src/twocore/runtime/rt_num.gleam` — **bodies** (signatures came from 01; do not
  rename or re-arity the public heads — `08` emits calls against them).
- `test/twocore/runtime/rt_num_test.gleam` — property tests + spec-vector tests.

> The public names/arities and the `Result(Int, TrapReason)`-vs-bare-`Int` shape are
> frozen by 01. If a needed float/conversion head is missing from the frozen stub
> (01 listed integers explicitly and left floats/conversions as `…`), agree the exact
> spelling with the 01 and 08 owners **before** adding it, then update the stub — names
> must match what `08`'s `NumOp → rt_num fn name` map emits.

## Depends on

- **«RTNUM-SIG-FROZEN»** — the only hard dependency. You may start against the strawman
  heads in 01 immediately.
- `twocore/ir.{TrapReason}` — you return `Error(IntDivByZero)` / `Error(IntOverflow)`.
  These constructors are in `ir.gleam` (frozen by 01); import the type, do not redefine.
- A property-testing library is **not** yet a dependency. Add one as a dev dependency
  (e.g. `qcheck`) or use deterministic seeded random + exhaustive small-domain vectors.
  Either is fine; what matters is the assertions target the spec (below), not the impl.

## Scope — in / out for Phase 1

**In (all spec-tested + corpus-covered end-to-end):**

- Full **i32 + i64** integer op set: `add/sub/mul`, `div_s/div_u/rem_s/rem_u`,
  `and/or/xor`, `shl/shr_s/shr_u`, `rotl/rotr`, `clz/ctz/popcnt`, `eqz`,
  `eq/ne/lt_s/lt_u/gt_s/gt_u/le_s/le_u/ge_s/ge_u`.
- **Conversions:** `i32.wrap_i64`, `i64.extend_i32_s/u`, `extend8_s/extend16_s`
  (i32 + i64), `extend32_s` (i64), `reinterpret` (both directions, both widths).
- **Float ops:** `f32/f64` `add/sub/mul/div`, `min/max`, and `trunc_sat_s/u`. These are
  implemented **and property-tested**, and unit 07 must ship **≥1 f32 and ≥1 f64 corpus
  program** so the float path is validated end-to-end. **Per D9: do not ship float code
  the corpus never executes** — coordinate with 07.

**Out (Phase 2, per D9 deferral):**

- Trapping (non-saturating) **float→int** (`trunc_s`/`trunc_u`) — they trap on
  NaN/Inf/out-of-range; deferred.
- The rest of the float surface (`sqrt`, `floor`, `ceil`, `nearest`, `abs`, `neg`,
  `copysign`, float compares, `f32↔f64` `promote`/`demote`, `convert_iN`).
- Anything memory/table/SIMD related.

## Deliverables

### One private representation + three private helpers (freeze these first — see Concurrency)

**THE ONE CONVENTION:** an `iN` value is stored as a **non-negative bignum in
`[0, 2^N)`** (the raw unsigned bit pattern). A float is stored as the **raw IEEE-754 bit
pattern** (an `i32` for `f32`, an `i64` for `f64`) — *never* a native BEAM double (D5).

```gleam
// width modulus: m(W32) = 0x1_0000_0000, m(W64) = 0x1_0000_0000_0000_0000
fn modulus(w: IntWidth) -> Int

// TRUE non-negative modulo. norm(x, m) = ((x % m) + m) % m.
// DO NOT use bare `%`/`int.remainder` for wrapping: Gleam/Erlang remainder follows the
// DIVIDEND's sign and pushes negative intermediates below 0, corrupting the bit pattern.
fn norm(x: Int, w: IntWidth) -> Int

// signed interpretation: signed(u) = u if u < 2^(N-1) else u - 2^N.
fn signed(u: Int, w: IntWidth) -> Int

// encode(s) = norm(s, w)   (the inverse of `signed`, for storing a signed result)
```

**Sign-agnostic ops** (operate on raw bits, never call `signed`):
`eq/ne/and/or/xor/shl/shr_u/rotl/rotr/clz/ctz/popcnt/eqz/lt_u/gt_u/le_u/ge_u`.
**Signed ops** (call `signed` first): `div_s/rem_s/shr_s/lt_s/gt_s/le_s/ge_s` and the
`extend_s` family. Every test must include **high-bit-set operands** for both variants.

### Integer ops (per width; bodies)

| Family | Semantics (N = 32 or 64, M = 2^N) |
|---|---|
| `add/sub/mul` | `norm(a + b)`, `norm(a - b)`, `norm(a * b)`. No traps. |
| `div_u` | `b == 0` → `Error(IntDivByZero)`; else `Ok(a / b)` (a,b unsigned, truncates). |
| `rem_u` | `b == 0` → `Error(IntDivByZero)`; else `Ok(a % b)`. |
| `div_s` | `b == 0` → `Error(IntDivByZero)`; `signed(a)==-2^(N-1) && signed(b)==-1` → `Error(IntOverflow)`; else `Ok(encode(trunc(signed(a)/signed(b))))` (truncates toward zero). |
| `rem_s` | `b == 0` → `Error(IntDivByZero)`; else `Ok(encode(signed(a) rem signed(b)))`. **`rem_s(INT_MIN,-1) == 0`, NOT a trap.** Result takes the sign of the dividend. |
| `and/or/xor` | `int.bitwise_*` on raw bits. |
| `shl` | `k = b mod N`; `norm(a * 2^k)`. |
| `shr_u` | `k = b mod N`; `a / 2^k` (a ≥ 0 so truncation == floor). |
| `shr_s` | `k = b mod N`; `encode(floor(signed(a) / 2^k))` — **arithmetic** (sign-filling) shift. |
| `rotl` | `k = b mod N`; `norm((a * 2^k) bor (a / 2^(N-k)))`. |
| `rotr` | `k = b mod N`; `norm((a / 2^k) bor (a * 2^(N-k)))`. |
| `clz/ctz` | leading / trailing zero count by **bit scan**; `clz(0)=N`, `ctz(0)=N`. |
| `popcnt` | count of set bits by bit scan. |
| `eqz` | `a == 0` → `1` else `0`. |
| `eq/ne` | raw-bit compare → i32 `0/1`. |
| `lt_u/gt_u/le_u/ge_u` | raw-bit compare → i32 `0/1`. |
| `lt_s/gt_s/le_s/ge_s` | compare `signed(a)`,`signed(b)` → i32 `0/1`. |

**Every comparison returns an i32 `0`/`1`** — including the `i64_*` comparisons.

### Conversions (bodies)

- `i32_wrap_i64(x) = x mod 2^32` (drop high 32 bits → `norm(x, W32)`).
- `i64_extend_i32_u(x) = x` (identity; `x ∈ [0,2^32) ⊂ [0,2^64)`).
- `i64_extend_i32_s(x) = norm(signed(x, W32), W64)`.
- `extendK_s(x) = norm(signed(x mod 2^K, K-bit), W)` — sign-extend the low **K** bits.
  e.g. `i32_extend8_s(0x80) == 0xFFFFFF80`.
- `reinterpret` (`i32↔f32`, `i64↔f64`) = **identity on our Int representation** — the
  stored bit pattern is unchanged; only the static IR type differs. Implement as
  `fn(a) { a }` and document *why* it is a no-op (we already store floats as bits).

### Float ops (bodies) — CRITICAL representation

Floats arrive and leave as **Int bit patterns**. Per op:

1. **Classify** each operand from its bits (sign / exponent / mantissa fields):
   NaN, ±Inf, ±0, or finite. (f32: 1+8+23 bits; f64: 1+11+52 bits.)
2. **NaN in or NaN produced → return the POSITIVE CANONICAL NaN.**
   `f32 = 0x7FC00000`, `f64 = 0x7FF8000000000000`. (Locked: canonical-only, no payload
   propagation — see Grounded facts.)
3. **±Inf / ±0** handled by IEEE rules on the bit patterns (e.g. `Inf + (-Inf)` →
   canonical NaN; `x / 0` → signed Inf; `0/0` → NaN; signed-zero results).
4. **All-finite** path only: decode bits → double, compute, re-encode:
   ```gleam
   // f64 decode:   let assert <<f:float-size(64)>> = <<bits:int-size(64)-big>>
   // f64 re-encode: let <<out:int-size(64)-big>> = <<value:float-size(64)>>  in `out`
   ```
   For **f32**, round to single after **every** op via a 32-bit float round-trip on the
   finite result: `let <<bits32:int-size(32)-big>> = <<value:float-size(32)>>` (the
   32-bit construct rounds-to-nearest-ties-to-even and yields the f32 pattern directly).
   `fadd/fsub/fmul/fdiv` are round-to-nearest ties-to-even.
5. **`fmin/fmax`:** either NaN → canonical NaN; `(+0,-0)` → **-0 for min, +0 for max**
   (signed zero — only reliable on bit patterns; BEAM `min`/`max` and `==` can't tell
   `+0.0` from `-0.0`); else numeric min/max with Inf handled by IEEE.
6. **`trunc_sat_s`:** NaN→`0`; `-Inf`→`-2^(N-1)`; `+Inf`→`2^(N-1)-1`; else truncate
   toward zero and clamp to `[-2^(N-1), 2^(N-1)-1]`, then `encode` to unsigned bits.
   **`trunc_sat_u`:** NaN→`0`; `≤0`/`-Inf`→`0`; `+Inf`→`2^N-1`; else truncate toward
   zero and clamp to `[0, 2^N-1]`.

### Documentation (D8)

Every public function gets a `///` doc comment stating its **spec semantics**, the
**meaning of `Ok`/`Error`** for trapping ops, and its **trap conditions**. Cite the spec
op. Module doc `////` states THE ONE CONVENTION and the canonical-NaN lock.

## Grounded facts you MUST honor

> Verified against <https://webassembly.github.io/spec/core/exec/numerics.html>. Honor
> exactly; each is a known expensive-to-retrofit pitfall.

- **THE ONE CONVENTION** (repeat): store `iN` as a non-negative bignum in `[0, 2^N)`.
  `signed(u)=u if u<2^(N-1) else u-2^N`. `encode(s)=norm(s)`. `norm(x)=((x%M)+M)%M`.
  **PITFALL:** bare `%`/`int.remainder` follows the dividend's sign — using it to "wrap"
  produces negative values and corrupts the bit pattern. Always go through `norm`.
- **WRAP:** `add/sub/mul = norm(a±b / a*b)`. No traps, ever.
- **TRAPS — the copy-paste minefield:**
  - `div_u`/`rem_u` trap **iff** `divisor == 0`.
  - `div_s` traps **iff** `divisor == 0` **OR** (`signed(a) == -2^(N-1)` AND
    `signed(b) == -1`) → that second case is `Error(IntOverflow)`.
  - `rem_s` traps **ONLY** on `divisor == 0`. **`rem_s(INT_MIN, -1) == 0`** is NOT a
    trap (the classic copy-paste bug — `rem_s` ≠ `div_s` on the overflow case).
  - **PITFALL:** Gleam's `/` and `%` are **TOTAL** — `x / 0 == 0` and `x % 0 == 0`, they
    silently do **not** trap. You **must** check `divisor == 0` explicitly and return
    `Error(IntDivByZero)` *before* dividing. A change-detector test that just calls
    Gleam `/` will *pass while being spec-wrong*; the spec test `div_u(5,0) ==
    Error(IntDivByZero)` is what catches it.
  - Division truncates toward zero; `rem` takes the sign of the dividend (BEAM `div`/`rem`
    already do this for the *signed* operands).
- **SHIFTS/ROTATES:** count `k = operand mod N` (i32 mod 32, i64 mod 64) → **shift by N
  == identity, by N+1 == by 1**. `shl=norm(a*2^k)`; `shr_u=a div 2^k`;
  `shr_s=encode(floor(signed(a)/2^k))` (Gleam `/` truncates — for negatives use floor /
  an arithmetic `bsr`, never truncating `/`); `rotl=norm((a*2^k) bor (a div 2^(N-k)))`;
  `rotr` likewise. **`k==0` needs care** (`N-k==N`, so `2^(N-k)=2^N` and `a div 2^N=0`,
  `a*2^N` gets cut by `norm` → rotate-by-0 is identity). `clz(0)=N`, `ctz(0)=N`,
  `popcnt` = a **bit scan** (NOT a float `log2`). Comparisons return i32 `0/1`.
- **CONVERSIONS:** `i32.wrap_i64 = x mod 2^32`; `i64.extend_i32_u = x`;
  `i64.extend_i32_s = signed_32(x) mod 2^64`; `extendK_s = signed_K(x mod 2^K) mod 2^N`
  (low K bits sign-extended); `reinterpret` = pure bit cast (identity on our rep).
- **FLOATS — CRITICAL:** do **not** store f32/f64 as native BEAM doubles — BEAM doubles
  **cannot hold NaN/Inf** (arithmetic raises `badarith`, and `<<F:64/float>>` fails to
  match NaN/Inf bits). Store the **raw IEEE bit pattern**. Classify from bits; NaN in /
  NaN out → **positive canonical NaN**; handle Inf and sign-of-zero by IEEE; decode →
  double → re-encode only on the all-finite path; round f32 to single after **every** op
  by a 32-bit float round-trip.
  - **EXTRA PITFALL (verify):** BEAM float arithmetic **raises `badarith` on overflow**
    instead of yielding `±Inf`, and building a 32-bit float from an out-of-single-range
    double also raises. Round-to-nearest *can* overflow to `Inf` (spec-correct). So the
    finite path must detect overflow (e.g. wrap the compute, or range-check the result)
    and yield the correctly-**signed Inf** bit pattern — do not let `badarith` escape.
- **NaN DECISION (spec-permitted freedom):** the spec does **not** mandate bit-exact NaN
  payload propagation — always emitting the positive canonical NaN is conformant (the
  deterministic profile *requires* it). **LOCK "canonical NaN only" into the `rt_num`
  contract.** Do not attempt payload propagation.

## Verification — Definition of Done (D8)

Tests assert the **WASM spec**, never "whatever the code emits" (no change-detector
tests). Cite the spec in the test. Use property-based tests where a law holds; use
spec vectors for the edges. The required spec-vector assertions:

- `i32_div_s(0x80000000, 0xFFFFFFFF) == Error(IntOverflow)` (INT_MIN / -1 **traps**);
  the i64 mirror `i64_div_s(0x8000_0000_0000_0000, max) == Error(IntOverflow)`.
- `i32_rem_s(0x80000000, 0xFFFFFFFF) == Ok(0)` (**NOT** a trap).
- All four of `div_s/div_u/rem_s/rem_u` on divisor `0` → `Error(IntDivByZero)`
  (this is the proof Gleam's total `/` is **not** used — a wrong impl returns `Ok(0)`).
- `i32_shl(a, 32) == a` and `i32_rotl(a, 32) == a` (count `mod N` → identity);
  `i32_shl(a, 33) == i32_shl(a, 1)`; same for i64 at 64/65.
- `i32_shr_s(0x80000000, 1) == 0xC0000000` (sign fill), and `shr_u` differs (`0x40000000`).
- `i32_extend8_s(0x80) == 0xFFFFFF80`; `i32_extend16_s(0x8000) == 0xFFFF8000`.
- `i32_wrap_i64(0x1_0000_00AB) == 0x000000AB` (high bits dropped).
- `reinterpret` round-trips: `f32_reinterpret_i32(i32_reinterpret_f32(x)) == x`.
- `f32_min(+0.0_bits, -0.0_bits) == -0.0_bits` (i.e. `0x80000000`), and
  `f32_max(+0.0_bits, -0.0_bits) == +0.0_bits` (`0x00000000`).
- `(NaN op x)` and `(x op NaN)` → canonical NaN bits for every float op
  (`f64`: `0x7FF8000000000000`; `f32`: `0x7FC00000`).
- `trunc_sat_u(NaN) == 0`; `trunc_sat_s(+Inf) == 2^(N-1)-1` (INT_MAX);
  `trunc_sat_u(-1.0) == 0`.

**Property laws to assert (spec-derived, width-parametric):**

- `signed(encode(s)) == s` for `s ∈ [-2^(N-1), 2^(N-1)-1]`; `norm` output always in
  `[0, 2^N)`.
- `add` is commutative and `add(a, sub(0, a)) == 0` mod 2^N; `mul` commutative.
- `and/or/xor` agree with a reference computed on Gleam's arbitrary-precision bit ops
  masked to N.
- `popcnt(a) + popcnt(bitnot_N(a)) == N`; `clz(a) + ` (bit-length scan) consistent;
  `clz(0)==ctz(0)==N`.
- `rotl(rotr(a, k), k) == a`; `rotl(a, k) == rotr(a, N-k)`.
- For finite, in-range doubles: `f64_*` agrees with a host IEEE oracle bit-for-bit
  (you may compute the oracle in Erlang/Gleam on the decoded double for the finite case).

**Process gate:** `gleam format --check src test` clean; `gleam build` no warnings;
`gleam test` green; every public fn documented (contract + trap conditions). When a bug
is found, add the failing **spec** test first, then fix.

## Concurrency

This unit splits cleanly into **three parallel sub-tasks once the shared private
helpers are frozen** (`modulus` / `norm` / `signed` / `encode` and the float
classify/decode/encode helpers — write and land these tiny helpers + their tests
**first**, in one commit, as the internal "mini-freeze"):

1. **Integer ops** (`add`…`ge_s`, both widths) — the bulk; purely over `norm`/`signed`.
2. **Conversions + reinterpret** — small, isolated, depends only on `norm`/`signed`.
3. **Float ops** (`f*_add/sub/mul/div/min/max`, `trunc_sat_*`) — the float
   classify/encode helpers; coordinate with **07** for the f32+f64 corpus programs.

The seam is the private-helper set: everything signed/unsigned reduces to it, so once
it is correct and stable the three streams don't touch each other's functions. Keep one
agent owning the helper file region to avoid merge churn.

## What this leaves for others

- **08 (`emit_core`)** can emit `call 'twocore@runtime@rt_num':'<fn>'(...)` for every
  numeric `NumOp`/`ConvOp`, trusting these bodies for fidelity — the binding chokepoint
  now has a real numeric target.
- **07 (conformance)** gets the reference values for the integer/float corpus programs.
- **Later tiers** (`nif`/optimized numerics) are **differentially tested against this
  module** — it is the single source of numeric-fidelity truth (D2). Keep it pure and
  exact; speed is a Phase-2 concern.
