# Unit 07 — Conformance harness, oracle & Phase-1 corpus

> **Owner: 1 agent (cleanly splits into 3 sub-tasks — see Concurrency). Wave A for the
> engine/fixture/oracle side (independent — start immediately). Freeze deps: only
> `«IR-FROZEN»` (to name trap reasons in the corpus); the "compare-to-our-output"
> assertions go green at the capstone (unit 11) when the real pipeline `Driver` exists.**
> Read [`00-overview.md`](00-overview.md) first; this doc assumes D1–D10.

---

## Context

This unit builds the machinery that answers **"is our compiled output spec-correct?"** —
and, crucially, lets us answer it **before the compiler is finished**. It sits to the
side of the pipeline (see the DAG in [`00-overview.md`](00-overview.md) §3): the
expected-value side is fully independent of our compiler because the official WASM spec
test suite (`.wast`) **bakes the right answers into the test files themselves**. This
unit is the **sole owner** of the oracle + the Phase-1 acceptance corpus, so the capstone
(unit 11) consumes them rather than re-deriving its own. It implements §11
(differential testing) and the §1 acceptance table of the overview.

## Goal

Deliver a Gleam **spec-runner** that drives the official WASM spec-suite commands
(`module` / `assert_return` / `assert_trap` / `assert_invalid` / `assert_malformed`)
through 2core and compares results against the spec's baked-in expected values, **plus**
the **Phase-1 acceptance corpus** (the §1 programs) with spec-sourced expected outputs.
Measurable done: the harness parses and runs the pinned Phase-1 `.wast` allowlist against
a stub driver and the fixtures pass `spectest-interp`'s own check; the corpus is wired so
that unit 11 flips it green by supplying the real pipeline driver.

## Files owned

All under `test/twocore/conformance/**` (D1 — sole owner of the oracle **and** the corpus):

| Path | Purpose |
|---|---|
| `test/twocore/conformance/fixture.gleam` | wast2json JSON → typed `Command`/`Action`/`SpecValue`. Tier-A: no engine. |
| `test/twocore/conformance/oracle.gleam` | Value comparison: bit-pattern equality + NaN-by-class. The single comparison authority. |
| `test/twocore/conformance/registry.gleam` | Tracks *current* + *named* + *registered* module bindings. |
| `test/twocore/conformance/runner.gleam` | Drives a fixture's commands, split by command type, against a `Driver`. |
| `test/twocore/conformance/reference/wasmtime.gleam` | Tier-B reference-engine adapter (authored / random inputs). |
| `test/twocore/conformance/corpus/*.wat` + `*.expected` | The Phase-1 acceptance corpus + spec-sourced expected outputs. |
| `test/twocore/conformance/fixtures/*.json` + `*.wasm` | Vendored, **pinned** normalized fixtures (wast2json output). |
| `test/twocore/conformance/vendor/` | `ALLOWLIST`, `PIN` (testsuite SHA + tool versions), `vendor.sh` (clone→convert→sanity-check). |
| `test/twocore/conformance/conformance_test.gleam` | gleeunit entry: runs the allowlist + corpus. |

## Depends on

- **Engine / expected-value side — INDEPENDENT, build first.** Tier-A needs no compiler
  and no reference engine *at run time*: the spec `.wast` files carry the expected values.
  You can vendor, convert, and validate fixtures with `spectest-interp` on day 1.
- **`«IR-FROZEN»`** (unit 01) — only to spell the corpus' expected **trap reasons**
  against `ir.TrapReason` and to express IR-level expectations. Stub against the strawman
  meanwhile.
- **Compare-to-our-output side — depends on the full pipeline** (decode→validate→lower→
  emit→`build_beam`) + the run/invoke ABI + unit 11's stage driver. **Stub this with a
  `Driver` seam** (below) now; unit 11 supplies the real one. Those assertions are *wired*
  immediately but only **green at unit 11**.
- **wasmtime / wabt** — host toolchain prerequisites (see Grounded facts). Tier-B only.

## Scope — in / out for Phase 1

**In:**
- Vendor `github.com/WebAssembly/testsuite` **at a pinned commit**; an explicit `.wast`
  allowlist; wast2json conversion to normalized fixtures.
- A spec-runner for `module`/`assert_return`/`assert_trap`/`assert_invalid`/
  `assert_malformed`, **split by command type** (frontend-only vs full-pipeline).
- The oracle: bit-pattern equality for ints/floats; NaN matched by class + payload.
- The Phase-1 acceptance corpus (§1) with spec-sourced expected values.
- A wasmtime adapter for Tier-B (authored fixtures + property/random inputs).

**Out (Phase 1):**
- `call_indirect.wast` / `table*.wast` / `memory*.wast` — defer to when `rt_table`/`rt_mem`
  land (Phase 1.5/2; D9, overview §1). The allowlist excludes them.
- `assert_exhaustion` / `assert_uninstantiable` / `assert_unlinkable` command kinds (no
  memory/tables/multi-module-linking in Phase 1).
- Post-MVP proposal files (GC `array*.wast`/`i31.wast`/`call_ref.wast`, SIMD
  `*_relaxed_*.wast`, legacy exceptions) — Phase-1 cannot decode them; the **pin** keeps
  them out.
- The WAT text parser (overview §1 / D9): use `wat2wasm` to author corpus `.wasm`, never a
  parser of ours.

## Deliverables

### 1. Fixture acquisition + pin (`vendor/`)

`vendor.sh`: `git clone` the testsuite, **`git checkout <PIN sha>`**, copy only the
`ALLOWLIST` files, run `wast2json` on each → `fixtures/<name>.json` + `fixtures/<name>.N.wasm`,
then run `spectest-interp fixtures/<name>.json` and assert `"N/N tests passed"` before the
fixtures are trusted/committed. `PIN` records the testsuite SHA **and** wabt + wasmtime
versions (CI installs and checks these).

`ALLOWLIST` (VERIFIED present in the testsuite root — do not add others):
```
i32 i64 int_exprs int_literals const local_get local_set local_tee
block loop if br br_if br_table return labels select nop call
conversions traps func fac
```

### 2. Fixture model (`fixture.gleam`)

Parse the wast2json JSON. **Every command is an object with a `type`.** Model exactly the
five Phase-1 command kinds and the two action kinds:

```gleam
pub type Command {
  ModuleCmd(line: Int, name: Option(String), wasm: String)      // a per-module .wasm to load
  Register(line: Int, as_name: String, module: Option(String))  // names a module for later invokes
  AssertReturn(line: Int, action: Action, expected: List(SpecValue))
  AssertTrap(line: Int, action: Action, text: String)           // expected trap-message SUBSTRING
  AssertInvalid(line: Int, wasm: String, text: String)          // FRONTEND-only (validator)
  AssertMalformed(line: Int, wasm: String, text: String)        // FRONTEND-only (decoder)
}

pub type Action {
  Invoke(field: String, args: List(SpecValue), module: Option(String))
  Get(field: String, module: Option(String))
}

/// A spec value. Ints and float-bits hold the RAW UNSIGNED bit pattern (decimal-string in
/// the JSON). NaN expectations carry only a CLASS, never a concrete bit pattern.
pub type SpecValue {
  I32Val(bits: Int)
  I64Val(bits: Int)
  F32Bits(bits: Int)   // 0..2^32, raw IEEE-754 binary32 bits
  F64Bits(bits: Int)   // 0..2^64, raw IEEE-754 binary64 bits
  F32Nan(NanKind)
  F64Nan(NanKind)
}

pub type NanKind { Canonical  Arithmetic }
```

### 3. The oracle (`oracle.gleam`)

One public comparison function — the **only** place result equality is decided:

```gleam
/// True iff `actual` satisfies the spec's `expected`. Ints and concrete floats compare by
/// EXACT bit pattern. A NaN expectation matches by CLASS + payload constraint (many bit
/// patterns are valid) — NEVER by bit-equality.
pub fn matches(actual: SpecValue, expected: SpecValue) -> Bool
```

NaN matching (per the spec, below): split a NaN's bits into sign / exponent (all-ones) /
payload; a value is a NaN of that width iff exponent is all-ones and payload ≠ 0; then
*canonical* ⇔ payload == the single MSB bit, *arithmetic* ⇔ payload MSB set (rest
arbitrary); **sign ignored** for both.

### 4. Module registry (`registry.gleam`)

`.wast` interleaves `(module …)` definitions with commands; an `assert_*`/`invoke` targets
the **most-recently-defined** module unless it names one (or a `register`-ed name). Model
*current* + a *named* dict + a *registered* dict from the start. A one-module-per-file
assumption **mis-binds invokes** (e.g. `call.wast` defines several modules per file).

### 5. The runner + the `Driver` seam (`runner.gleam`)

The runner is parameterized over a `Driver` so the harness is independent of the pipeline.
**Split execution by command type up front** (the partition fact):

```gleam
pub type Driver {
  Driver(
    /// decode+validate ONLY — for assert_invalid/assert_malformed. Ok(Nil) = accepted.
    check_frontend: fn(BitArray) -> Result(Nil, String),
    /// full pipeline: load .wasm → loaded .beam instance (D10).
    instantiate: fn(BitArray) -> Result(Instance, String),
    /// run an export; Trapped carries the runtime trap reason atom-as-string.
    invoke: fn(Instance, String, List(SpecValue)) -> InvokeResult,
  )
}

pub type InvokeResult {
  Returned(List(SpecValue))
  Trapped(reason: String)   // e.g. "int_div_by_zero" from rt_trap:raise
  DriverError(String)       // pipeline failure, distinct from a spec trap
}
```

Routing: `assert_invalid`/`assert_malformed` → `check_frontend` and assert a typed
`Error` (D4 fail-closed — **never feed these to `instantiate`/wasmtime**, which reject
them). `assert_return`/`assert_trap` → `instantiate` + `invoke`, compared via the oracle.
A stub `Driver` (everything `DriverError("unimplemented")`) lets the harness + fixtures be
built and the parsing/oracle tested **now**; unit 11 swaps in the real driver.

### 6. The Phase-1 acceptance corpus (`corpus/`)

The §1 programs. **Source every numeric-edge expected value from the vendored `.wast`** so
the answer comes from the spec, not a hand-written oracle:

| Program | Source of expected value |
|---|---|
| `add(i32,i32)` | authored `.wat` (trivial plumbing); answer is self-evident / cross-checked by wasmtime |
| `sum_to(n)` loop | authored `.wat`; cross-check the closed form via wasmtime (Tier-B) |
| `fac` / `fib` | `fac` ← vendored `fac.wast` (allowlisted!); `fib` authored, wasmtime cross-check |
| `div_s(INT_MIN,-1)` trap | `i32.wast` `assert_trap` "integer overflow" |
| `div_u(x,0)` trap | `i32.wast` `assert_trap` "integer divide by zero" |
| i32 wraparound | `i32.wast` / `int_exprs.wast` (wrapping add/mul) |
| shift count ≥ width | `i32.wast` shl/shr cases with count ≥ 32 (spec masks count mod 32) |
| signed/unsigned divide pair | `i32.wast` `div_s` vs `div_u` on a value that differs |
| one f32 + one f64 | float **bits/reinterpret** ← `const.wast`/`conversions.wast` (Tier-A); one f32.add + one f64.add **op** authored, wasmtime cross-check (covers unit 06's float path) |
| one `call_host` import | authored `.wat` with a host import; expected = **rejected end-to-end under deny-all** (D9/D4), a typed `Error`/trap — *not* a spec value |

### 7. Tier-B reference adapter (`reference/wasmtime.gleam`)

Shell out to `wasmtime` to produce expected values for **authored** corpus programs and
random/property inputs (where the `.wast` carries no answer). Flags go **before** the file.

## Grounded facts you MUST honor

**Toolchain (VERIFIED — not installed here; macOS).** `brew install wabt wasmtime`. wabt
provides `wat2wasm`, `wast2json`, `spectest-interp`. `wat2wasm add.wat -o add.wasm`.
Document this as a **prerequisite**; **CI must install and PIN versions** (record them in
`vendor/PIN`).

**`.wast` is a superset of `.wat`** interleaving `(module …)` with commands. `assert_*`
targets the most-recently-defined / named / registered module. **PITFALL:** track *current
module* + a *named registry* from the start — a one-module-per-file assumption mis-binds
invokes (`call.wast` et al. define multiple modules per file).

**Tier-A key insight (VERIFIED).** The spec `.wast` files **already contain the expected
values** — you need **no reference engine** to know the right answer for spec files (only
for your own / random inputs). Structure the harness so Tier-A needs **no engine at run
time** — this is what lets you validate instruction-by-instruction **before the compiler is
done**. Reserve `wasmtime` / `spectest-interp` for Tier-B (and for one-time fixture
validation).

**wast2json JSON shape (VERIFIED).** Every command is an object with a `type`.
`assert_return = {type, line, action:{type:"invoke", field, args:[{type,value}]},
expected:[{type,value}]}`. **ALL numeric `value`s are JSON STRINGS** (i64 and float bits
exceed JSON number precision — parse as integers, never as JS/JSON floats). Integers are
the **DECIMAL of the unsigned bit pattern**.

**PITFALL — floats are bit patterns, not numbers (VERIFIED).** For `f32`/`f64`, the
`value` string is the **DECIMAL OF THE RAW IEEE-754 BIT PATTERN**, e.g. `f32 1.0 →
"1065353216"` (= `0x3F800000`), **not** `"1.0"`. Parse it as integer bits and reinterpret;
otherwise **every float test is silently wrong**. This matches D5 (we store floats as raw
bits, never BEAM doubles) — so our result *is already* the bit pattern; compare directly.

**PITFALL — NaN never compares by bit-equality (VERIFIED).** Expected NaN appears as the
literal strings `"nan:canonical"` / `"nan:arithmetic"`. Match by **NaN class + payload
constraint**, per
<https://webassembly.github.io/spec/core/syntax/values.html#floating-point> and
<https://webassembly.github.io/spec/core/exec/numerics.html>:
- **canonical** — payload **MSB = 1, all other payload bits 0**; either sign.
- **arithmetic** — payload **MSB = 1, remaining bits arbitrary**; either sign.

Bit layout (use these as test vectors): for **f32**, sign = bit 31, exponent = bits 30..23
(all-ones for NaN), payload = bits 22..0; canonical NaN payload = `0x400000`, so canonical
f32 NaN = `0x7FC00000`. For **f64**, sign = bit 63, exponent = bits 62..52 (all-ones),
payload = bits 51..0; canonical NaN payload = `0x8000000000000`, so canonical f64 NaN =
`0x7FF8000000000000`. "Arithmetic" ⇔ `payload & MSB ≠ 0`.

**`assert_trap` carries an expected message SUBSTRING (VERIFIED):** `"integer divide by
zero"`, `"integer overflow"`, `"out of bounds"`, `"unreachable"`. Map our runtime trap
reason (`rt_trap:raise('int_div_by_zero')` etc., per the `ir.TrapReason` enum) to the
expected substring; check by **substring containment**, not exact string. **PITFALL:**
integer traps live in **`i32.wast`/`i64.wast`/`conversions.wast`** as `assert_trap`
(`div_s INT_MIN/-1` overflow, div/rem by zero), **not only** in `traps.wast` — the corpus
must source them from those files.

**PARTITION (VERIFIED).** `assert_invalid` (typecheck) and `assert_malformed` (decode)
exercise the **frontend only** (decoder/validator) and need **no execution engine** —
**never** feed them to the backend or to `wasmtime` (which rejects them). `assert_return`/
`assert_trap` exercise the **full pipeline** through Core Erlang on the BEAM. **Split the
harness by command type up front** (the `runner.gleam` routing above).

**wasmtime ≥ v14 CLI (VERIFIED):** flags go **before** the file —
`wasmtime run --invoke 'add(2, 3)' add.wasm`. **PIN the version** (the older positional
form was removed). Tier-B only.

## Verification — Definition of Done (D8)

- **Spec-grounded, not change-detector (D8).** The oracle asserts what the **spec** says
  should happen: expected values come from the vendored `.wast` (baked in) and the IEEE/WASM
  NaN-class rules above — **never** from "whatever our code emitted". Cite the spec
  (<https://webassembly.github.io/spec/core/>) in tests for any hand-derived expectation.
- **Fixtures are trustworthy before use:** `vendor.sh` runs `spectest-interp
  fixtures/<name>.json` and requires `"N/N tests passed"` for every allowlisted file; a
  failing/mismatched fixture set fails the build.
- **Self-tests of the harness machinery (run NOW, no compiler needed):**
  - the JSON parser round-trips a known `assert_return` command incl. the `f32 1.0 →
    "1065353216"` vector (assert we reconstruct bits `0x3F800000`, **not** a parsed float);
  - the oracle accepts *every* canonical f32/f64 NaN bit pattern and *rejects* a non-NaN
    and a wrong-class NaN; accepts arithmetic NaNs with assorted payloads/signs;
  - the registry binds an `invoke` to the correct module when a file defines two modules
    and registers one;
  - `assert_invalid`/`assert_malformed` route to `check_frontend` only (proved with a
    spy/stub `Driver` that fails if `instantiate` is called for them).
- **Allowlist runs:** `conformance_test.gleam` parses + drives the full pinned allowlist
  against the stub `Driver`; frontend-only assertions can already be checked once unit
  05/10 land; full-pipeline assertions are wired and **expected-pending** until unit 11.
- **Corpus is spec-sourced:** each numeric-edge corpus expectation references the vendored
  `.wast` file + line it came from (not a hand-typed oracle).
- **Proving the goal:** when unit 11 supplies the real `Driver`, the §1 acceptance table
  passes end-to-end (decode→…→loaded `.beam`→`apply`), including the two traps, the
  wraparound + shift-masking, the divide pair, the f32+f64 programs, and the deny-all
  `call_host` rejection — with **zero change to harness or fixtures**.
- `gleam format --check src test` clean; `gleam build` no warnings; every public function
  has a contract doc comment (D8).

## Concurrency

Freeze the **`Driver`, `SpecValue`, and `Command` types first** (a half-day mini-freeze),
then split three ways with no further coordination:
1. **Harness machinery** — `fixture.gleam` + `oracle.gleam` + `registry.gleam` +
   `runner.gleam` + `vendor/`. Fully independent (only `«IR-FROZEN»` for trap-reason names).
2. **Acceptance corpus** — `corpus/*.wat` + `*.expected`, authored via `wat2wasm`,
   numeric edges sourced from the vendored `.wast`. Needs the frozen `SpecValue` type only.
3. **wasmtime Tier-B adapter** — `reference/wasmtime.gleam`. Fully independent.

The `Driver` seam is also the temporal seam: everything above is buildable and testable
against a **stub** driver before the pipeline exists; unit 11 substitutes the real driver
to turn the compare-to-our-output assertions green.

## What this leaves for others

- **Unit 11 (capstone)** gets the oracle + corpus to run the Phase-1 **differential
  acceptance** — it supplies a real `Driver` and proves the §1 goal; it owns no fixtures.
- **Units 05 (decode) / 10 (validate+lower)** get the `assert_malformed` / `assert_invalid`
  partition as a **per-instruction frontend conformance** suite they can run independently
  (frontend-only, no engine) the moment their stages compile.
- **Unit 06 (`rt_num`)** can cross-check its property tests against the same vendored
  numeric `.wast` edge cases (shared source of spec truth).
