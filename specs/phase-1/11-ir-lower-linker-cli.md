# Unit 11 — `ir_lower`, Linker, Safe Profile & CLI (the capstone)

> **2–4 agents · Wave B (split the long pole).** `11a` lands EARLY (needs only
> `«IR-FROZEN»`); `11b` lands once `«ABI-FROZEN»` + unit `09` are up; `11c`/`11d`
> land LAST (gate on every stage). Read [`00-overview.md`](00-overview.md) first —
> this doc assumes D1–D10.

---

## Context

This is the keystone that assembles the vertical slice and **proves the Phase-1
goal** ([`00-overview.md`](00-overview.md) §1). It supplies the one middle-end
policy pass (`ir_lower`, the `M3` row of high-level §4), the linker + Safe profile
(`rt_instance`, high-level §6/§13), the per-stage CLI (high-level decision #5), and
the end-to-end **differential acceptance** that runs unit `07`'s corpus through the
whole pipeline to the BEAM and diffs against the WASM spec. It owns no numeric,
backend, or frontend logic — it *wires and proves*. Everything upstream feeds it; do
not re-derive their contracts here, follow theirs.

## Goal

A green acceptance suite: **every** corpus program in `07` decodes → validates →
lowers → emits → builds → loads → runs on the BEAM with **spec-correct** results —
numeric edges holding *through codegen*, traps trapping, the loop running in constant
space, and the `call_host` import **rejected fail-closed end-to-end** — plus a CLI
that can dump/inspect each stage independently. That is the measurable Phase-1 done.

## Files owned (D1)

| File | Sub-unit |
|---|---|
| `src/twocore/middle/ir_lower.gleam` | **11a** — IR→IR policy pass. *Reads `ir.gleam` + the `Binding` type only.* |
| `src/twocore/runtime/profiles.gleam` | **11b** — Safe profile + linker. **Imports `instance.gleam`; never edits it.** |
| `src/twocore.gleam` | **11c** — CLI exposing every stage (decision #5). |
| `src/twocore/pipeline.gleam` | **11c** — *completes* the `01` stub: refines `PipelineError` (D4) + stage-driver API. |
| `test/twocore/middle/ir_lower_test.gleam` | 11a |
| `test/twocore/runtime/profiles_test.gleam` | 11b |
| `test/twocore/acceptance_test.gleam` | **11d** — the differential acceptance harness. |

> **Do NOT touch** `runtime/instance.gleam` (owned by `01`) or
> `test/twocore/conformance/**` (the oracle + corpus + expected values are owned by
> `07`; `11d` *invokes* them, never redefines them).

## Depends on

- **11a** — `«IR-FROZEN»` (`ir.gleam`) + `«ABI-FROZEN»` (the `Binding` type). That is
  *all* — it does not need the frontend or backend. **Build and unit-test it against
  hand-written `.ir`/`ir.Module` fixtures and ship it early in Wave B.**
- **11b** — `«ABI-FROZEN»` + unit `09`'s impl modules (`rt_trap`, `rt_host`,
  `rt_meter`, `rt_stdlib`, `rt_bif`). Stub against `instance.safe_default()` meanwhile.
- **11c** — every stage's public interface: `decode`(05), `validate`+`lower`(10),
  `ir_lower`(11a), `emit_core`(08), `build_beam`(04). Stub each behind its frozen
  signature early; wire for real as they land.
- **11d** — *all* of the above green, plus `07`'s corpus + oracle.

## Scope — in / out for Phase 1

**In:**
- `ir_lower`: stdlib resolution against the `own` surface, `rt_bif` allowlist
  enforcement (fail-closed), and `Charge` metering **insertion** (the hook must exist
  now so it is never retrofitted into codegen — D9).
- The **named Safe profile** (a `Binding`) + thin `rt_instance` linker.
- A CLI driving each stage independently and end-to-end.
- The differential acceptance run.

**Out (cite D9 / §1 deferrals):**
- The **Unsafe** profile (aggressive optimizer, passthrough stdlib, open BIFs, tier
  O/N) — Phase 2.
- Breadth of the allowlist / `own` stdlib — Phase 1 ships 1–2 vetted functions only.
- The optimizer (`ir_opt`), linear memory/tables, the WAT parser, the Porffor bridge.
- Fuel **enforcement** (exhaustion → trap). Phase-1 metering is a *wired seam*, not a
  sandbox (D9): `Charge` is inserted, emitted, and counted, nothing more.

---

## Deliverables

### 11a — `ir_lower.gleam`

```gleam
import twocore/ir
import twocore/runtime/instance.{type Binding}

/// Per-stage error (D4) — this pass owns it; there is no shared StageError.
pub type LowerError {
  /// A stdlib `call_host` named a function absent from the `own` surface. Fail-closed.
  UnknownStdlibFn(capability: String, name: String)
  /// A resolved reference would reach a BEAM function not on the `rt_bif` allowlist.
  BifNotAllowed(name: String)
}

/// The minimal capability / stdlib / metering pass (high-level §4 `M3`, §6).
/// Walks every function body and, for `binding.mode == Safe`:
///   1. resolves each stdlib `CallHost` against the Phase-1 `own` stdlib surface,
///      rejecting unknown names with `UnknownStdlibFn` (fail-closed);
///   2. enforces the `rt_bif` allowlist on any retained-BEAM resolution, rejecting
///      with `BifNotAllowed` (fail-closed);
///   3. inserts the `Charge(cost, _)` metering effect (see below).
/// Host-import `CallHost`s (non-stdlib capabilities) are LEFT UNCHANGED — they are
/// rejected at RUN time by `rt_host` `deny_all` (the boundary is exercised e2e, not
/// at build time). Returns the rewritten module, or the first policy violation.
pub fn lower(module: ir.Module, binding: Binding) -> Result(ir.Module, LowerError)
```

- **Stdlib vs host classification.** The `own` stdlib uses one reserved capability
  string (placeholder `"std"`; confirm the exact token with `01`/`09`). Any other
  capability is a host import → untouched by `lower`.
- **Metering insertion (the non-negotiable hook).** Wrap each `Function.body` in
  `Charge(cost, body)`, and wrap each `Loop` body so iterations are metered. Phase-1
  `cost` may be a fixed constant — *the value does not matter; the node's presence
  does.* `emit_core` (08) lowers `Charge(cost, body)` → `call '<meter_module>':'charge'(Cost)`
  then `body`; `rt_meter` (09) keeps its counter out-of-band (D3d: **never** thread a
  state record through generated code).
- **Policy source.** For Phase 1 the Safe allowlist + `own` surface are *tiny* (1–2
  names). Derive them from `binding.mode == Safe`. The name set MUST equal `rt_bif`'s
  allowlist and `rt_stdlib`'s surface (09); add a test that cross-checks so they can't
  drift. (No import of 09's runtime impls — policy is build-time data, D3a.)

### 11b — `profiles.gleam` (linker + Safe profile)

```gleam
import twocore/runtime/instance.{type Binding, Safe, safe_default}

/// The named Phase-1 Safe profile: the build-time `Binding` carrying the vetted
/// `twocore@runtime@rt_*` impl module names (09). The ONLY profile Phase 1 ships.
/// Fail-closed: this is the safe posture and there is no Unsafe constructor here.
pub fn safe() -> Binding { safe_default() }

/// A runnable instance. Phase 1 is thin — no mutable state (D3d), so it carries only
/// the binding; Phase 2 adds memory/table/global handles. `rt_instance` of high-level §13.
pub type Instance {
  Instance(binding: Binding)
}

/// Assemble a runnable instance from a binding (ensures the runtime modules resolve).
pub fn instantiate(binding: Binding) -> Instance
```

- **Single-owner rule (D1):** `profiles.gleam` *imports* `instance.gleam` and never
  edits it. The impl module names live in exactly one place (`safe_default()`); do not
  re-spell `twocore@runtime@*` strings anywhere else.
- **Fail-closed, tested:** `safe().mode == Safe`; there is no API in this file that
  produces an Unsafe binding or relaxes the host/BIF posture (Phase 2 adds it).

### 11c — CLI (`twocore.gleam`) + `pipeline.gleam`

Complete the `01` stub `PipelineError` by wrapping each stage's *own* error (D4):

```gleam
pub type PipelineError {
  DecodeFailed(decode.DecodeError)            // 05
  ValidateFailed(validate.ValidateError)      // 10
  FrontendLowerFailed(lower.LowerError)       // 10  (WASM AST → IR)
  IrLowerFailed(ir_lower.LowerError)          // 11a (IR → IR policy)
  EmitFailed(emit_core.EmitError)             // 08
  BuildFailed(build_beam.BuildError)          // 04
}
```

Expose composable stage-driver functions (the CLI and `11d` both call these, so the
mapping-to-`PipelineError` lives in exactly one place):

```gleam
pub fn source_to_ir(wasm: BitArray) -> Result(ir.Module, PipelineError)        // decode→validate→lower(10)
pub fn ir_to_core(m: ir.Module, b: Binding) -> Result(String, PipelineError)   // ir_lower→emit_core→print .core
pub fn core_to_beam(core: String, mod: String) -> Result(BitArray, PipelineError)
```

CLI subcommands (decision #5 — **each stage independently invokable**):

| Subcommand | Pipeline |
|---|---|
| `to-ir <in.wasm>` | decode → validate → lower(10) → print `.ir` |
| `to-core <in.ir>` | parse `.ir` → **ir_lower** → emit_core → print `.core` |
| `to-beam <in.core>` | parse `.core` → build_beam → write `.beam` |
| `run <in.wasm> <export> <args…>` | source → … → load → invoke → print result |
| `decode` / `validate` / `lower` / `ir-lower` / `emit` / `build` | each finer stage alone, for testing |

Each subcommand prints its stage's typed `Error` to stderr and halts non-zero on
failure; never panic on bad input.

### 11d — the run/invoke ABI + acceptance (FIXED CONTRACT — `07` codes against this)

This is the contract for *how a compiled export is called from the BEAM*. Document it
in `pipeline.gleam` and freeze it, because `07`'s oracle marshals to it too.

```gleam
/// The outcome of invoking a compiled export. `Returned` carries one raw bit pattern
/// per result value; `Trapped` carries the spec trap reason.
pub type RunResult {
  Returned(values: List(Int))
  Trapped(reason: ir.TrapReason)
}

/// Load `beam` (D10: `code:load_binary` into the build VM via the 04 FFI shim) and
/// apply `export`/N. Catches the BEAM exception a trap raises and classifies it.
pub fn invoke(beam: BitArray, mod: String, export: String, args: List(Int)) -> RunResult
```

The contract:
- **Arguments and results are raw unsigned bit patterns as Erlang integers**, matching
  `rt_num`'s one documented convention: an `i32` in `[0, 2^32)`, an `i64` in
  `[0, 2^64)`. **`i64` is an ordinary BEAM bignum** — Erlang integers are
  arbitrary-precision, so nothing special is needed for values past 60 bits.
- **Floats marshal as their raw IEEE-754 bit pattern, as an integer** (D5: never a
  BEAM double) — an `f32` result is in `[0, 2^32)`, an `f64` in `[0, 2^64)`.
- **A trap surfaces as a BEAM exception** raised by `rt_trap` (`call '<trap_module>':'raise'(<reason_atom>)`);
  `invoke` catches it and returns `Trapped(reason)`. The deny-all host rejection
  surfaces the same way (a catchable error) → the acceptance asserts a *rejection*,
  not a normal return.
- The generated module's atom name and the multi-value return shape are owned by `08`;
  Phase-1 corpus functions are single-result, so `values` has length 1.

> **Coordinate with `04`** so the FFI shim's apply path can catch the trap exception
> (or wrap with `gleam_erlang`'s rescue) — do not edit `04`'s `.erl` file; request the
> seam. This catching-apply is part of the fixed contract above.

`11d` then iterates `07`'s corpus: for each program, `source_to_ir` → `ir_to_core`
(with `profiles.safe()`) → `core_to_beam` → `invoke`, and **diffs against the spec
expected value** baked into `07`'s `.wast` (Tier-A oracle). The corpus MUST cover:
`add`, `sum_to` (constant-space loop), `fac`/`fib`, `div_s(INT_MIN,-1)` trap,
`div_u(x,0)` trap, `i32` wraparound, a shift with count ≥ width, a signed/unsigned
divide pair, ≥1 `f32` and ≥1 `f64` program, and the `call_host` import that `deny_all`
**rejects end-to-end** (proven through decode→…→run, not a unit test).

---

## Grounded facts you MUST honor

- **`i64` is a BEAM bignum.** No special marshalling for large `i64` values — Erlang
  ints are arbitrary precision. ([WASM spec, numerics](https://webassembly.github.io/spec/core/exec/numerics.html))
- **Integers at every BEAM boundary are the raw *unsigned* bit pattern** (`rt_num`'s
  one convention). The `.wast` expected `(i32.const -1)` is the pattern `4294967295`;
  the oracle/`invoke` compare unsigned bit patterns, so convert `.wast` signed literals
  to unsigned before passing/comparing.
- **Floats are bit patterns, not doubles (D5).** `f32`/`f64` args and results are
  integers (the IEEE-754 bits). Never round-trip a float result through a BEAM double.
- **Numeric edges hold THROUGH codegen, asserted against the spec** (not the emitter):
  `div_s(INT_MIN,-1)` and `div_u(_,0)` **trap**; `i32` arithmetic wraps two's-complement
  mod `2^32`; **shift counts are masked mod bit-width** (`i32.shl` by `k` is `k mod 32`).
  ([spec/exec/numerics](https://webassembly.github.io/spec/core/exec/numerics.html))
- **Gleam→Erlang mangling (verified, D2):** module path `/`→`@` (`twocore/runtime/rt_num`
  → `twocore@runtime@rt_num`); public fn names emitted verbatim, arity = parameter
  count. The Safe `Binding` carries exactly these mangled names.
- **Namespace hygiene (verified hazard):** generated modules are `twocore@…`,
  hand-written FFI `.erl` are `twocore_…`. **Never** emit/name a module `lists`,
  `maps`, `erlang`, … — a collision can stop the output app from starting.
- **B2 link-time-fixed binding (D3b):** the Safe `Binding` is a *build-time* input;
  no data-driven `apply` of program/attacker-chosen modules (D3a); no runtime record
  threaded through generated code (D3d).
- **The loop is constant-space (verified):** a `letrec` tail loop ran 100k iterations
  in constant space on OTP 29. `11d` must *prove* this for `sum_to` (e.g. assert a
  large `n` returns without unbounded growth), not assume it.
- **D10 loading:** compile to an in-memory `.beam` and `code:load_binary` it into the
  running build VM, then `apply` the export. (Via `04`'s FFI shim.)

### Pitfalls (each one prevents an expensive retrofit)

1. **Do not retrofit metering later.** Insert `Charge` in `11a` now even though Phase-1
   accounting is minimal (D9) — otherwise codegen has to be reopened.
2. **Do not edit `instance.gleam`** from `profiles.gleam` (D1). Import it.
3. **Do not reject host imports at build time** in `ir_lower`. The deny-all rejection
   is a *runtime* property, exercised end-to-end — that is the whole point of the
   `call_host` corpus case.
4. **Honest scope (D9):** this delivers *Safe-mode seams wired and exercised
   end-to-end*, **not a full sandbox.** Say so; do not label the output "sandboxed."
5. **No change-detector tests.** The oracle is the WASM spec's baked-in `.wast`
   expected values, not whatever the emitter prints.

---

## Verification — Definition of Done (D8)

- **Acceptance suite green (the goal):** every `07` corpus program compiles, loads, and
  runs on the BEAM with results **matching the WASM spec** — wrap/shift/divide edges
  exact, `div_s(INT_MIN,-1)` and `div_u(_,0)` `Trapped`, `sum_to` constant-space, the
  `call_host` import **rejected** (`Trapped`/error, not `Returned`). Assert *spec*
  values ([spec test suite](https://webassembly.github.io/spec/core/), [numerics](https://webassembly.github.io/spec/core/exec/numerics.html)),
  never the emitter's output.
- **`ir_lower` fail-closed, tested against hand-written `.ir`:** a stdlib reference
  outside the `own` surface → `Error(UnknownStdlibFn)`; a non-allowlisted BEAM
  resolution → `Error(BifNotAllowed)`; a valid module gains a `Charge` at each function
  body and loop head. Never a panic on bad input.
- **Safe profile fail-closed, tested:** `profiles.safe().mode == Safe`; the binding's
  modules are exactly the vetted `twocore@runtime@rt_*`; no API yields an unsafe
  posture; the `ir_lower` constant policy equals `09`'s allowlist/surface (cross-check
  test, catches drift).
- **CLI proves decision #5:** each subcommand dumps/inspects its stage's output in
  isolation (golden `.ir` / `.core` checks where applicable).
- **Every public function has a doc comment** (contract: what / params & ranges /
  `Result` semantics / failure & panic modes). `gleam format --check src test` clean;
  `gleam build` has **no warnings**.
- **When a bug is found, add the failing spec test first**, then fix.

## Concurrency

Decompose along the file seams — they were chosen to land independently:

- **`11a` first (parallel with all of Wave A):** needs only `«IR-FROZEN»`. Build + test
  against hand-written `ir.Module`/`.ir` fixtures with a stub `Binding`. Ships before
  the frontend or backend exist. **Do this early — it is the long pole's cheap half.**
- **`11b` after `«ABI-FROZEN»` + `09`:** small; the Safe profile + thin linker.
- **`11c`/`11d` last:** gate on every stage. `11c` can be scaffolded early against
  frozen stage signatures (stub each stage) so only the wiring remains when stages land;
  `11d` needs the real pipeline green. The run/invoke ABI (the `RunResult`/`invoke`
  contract) should be **frozen early** so `07` can code its oracle against it in
  parallel — publish it as soon as `11c`'s `pipeline.gleam` skeleton exists.

## What this leaves for others

A working **WASM→BEAM vertical slice** with every stage independently invokable, the
Safe-mode seams wired and proven, and a green spec-differential acceptance suite — the
foundation Phase 2 broadens (Unsafe profile, `rt_mem`/`rt_table`, `ir_opt`, WAT parser,
wider allowlist/stdlib, the Porffor bridge).
