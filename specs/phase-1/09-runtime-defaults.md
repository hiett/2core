# Unit 09 — Runtime defaults (trap · host deny-all · meter · own-stdlib · bif gate)

> **1 owner; splits into up to 5 fully-parallel sub-tasks (one per module). Wave A→B.**
> Needs **«ABI-FROZEN»** (`instance.gleam`) and `TrapReason` from **«IR-FROZEN»**.
> Freeze the public function **names + arities** with unit **08** (they *are* the
> calling convention emit_core emits); freeze the `rt_bif` gate shape with unit **11**.

---

## Context

These are the five **Safe-mode runtime modules** the generated code calls at run time
(D2). They sit at the very bottom of the pipeline: the backend (`08 emit_core`) emits
direct `call 'twocore@runtime@…':'…'(…)` references to them, and the linker's Safe
`Binding` (`safe_default()` in `instance.gleam`) points at them by module name. They are
small, but they are what makes the Safe security model **real, not asserted** (D9 / §6).
Read [`00-overview.md`](00-overview.md) (D2, D3, D4, D9) and the calling-convention table
in [`01-interface-freeze.md`](01-interface-freeze.md) before writing a line — this doc
does not repeat them.

## Goal

Implement the five Safe-mode runtime **seams** so that, end-to-end on the BEAM:
a trap surfaces as a catchable, **kind-identifiable** Erlang error; a host import under
deny-all is **rejected** (fail-closed); the `charge` metering instrumentation path
**executes**; one or two vetted `own`-stdlib functions return **spec-correct** results via
the positive `call_host` path; and a **non-allowlisted** BEAM target **fails closed**.
Measurable: unit 07/11's `call_host`-under-deny-all program rejects through the full
pipeline, and the `div_s INT_MIN/-1`, `div_u(x,0)` programs trap with the spec's trap kind.

## Files owned

From the ownership map (D1):

| File | Module → BEAM module | Role |
|---|---|---|
| `src/twocore/runtime/rt_trap.gleam`   | `twocore@runtime@rt_trap`   | `raise/1` — turn a `TrapReason` into a catchable error |
| `src/twocore/runtime/rt_host.gleam`   | `twocore@runtime@rt_host`   | `call_host/3` — **deny-all** capability boundary |
| `src/twocore/runtime/rt_meter.gleam`  | `twocore@runtime@rt_meter`  | `charge/1` — minimal fuel seam |
| `src/twocore/runtime/rt_stdlib.gleam` | `twocore@runtime@rt_stdlib` | minimal `own` stdlib (1–2 vetted fns) |
| `src/twocore/runtime/rt_bif.gleam`    | (build-time; not runtime-linked) | `allowlist` gate consulted by `ir_lower` |
| `test/twocore/runtime/rt_{trap,host,meter,stdlib,bif}_test.gleam` | — | the suites |

> **There is no `rt_state.gleam`.** Phase 1 has no threaded instance state (D3d); the
> calling convention in `instance.gleam` covers the (empty) state story. Do not add one.

## Depends on

- **«ABI-FROZEN»** — `instance.gleam`'s documented calling convention + `safe_default()`.
  This is the hard gate: the public **function names and arities of these modules ARE the
  ABI** emit_core emits against. Do not rename or re-arity without re-syncing 08.
- **«IR-FROZEN»** — `twocore/ir.{type TrapReason}` (for `raise`'s parameter type) and
  the trap-reason set.
- **Stub-against-meanwhile:** start immediately against the strawman `TrapReason` and the
  `Binding`/convention table in `01`. The only thing that can churn under you is the exact
  name/arity list — so **agree that list with 08 first** (it is short; see Deliverables).
- `rt_bif`'s gate is consulted by **`ir_lower` (11)** at build time — coordinate its shape
  with 11. (`rt_bif` is **not** in the `Binding` record because it is not runtime-linked.)

## Scope — in / out for Phase 1

**In:**
- `rt_trap`: `error`-class raise with a `{wasm_trap, Kind}` reason; distinct kind atom per
  trap reason.
- `rt_host`: `deny_all` only — always reject, fail-closed (D4/D9).
- `rt_meter`: one minimal, **observable** fuel seam so the instrumentation path is proven.
- `rt_stdlib`: 1–2 tiny, auditable, spec-checkable `own` functions reachable via `call_host`.
- `rt_bif`: enforce a small vetted allowlist; non-allowlisted target fails closed.

**Out (deferred, D9 — do not build):**
- `rt_host` `whitelist`/`open`; granting capabilities. (Phase 2.)
- `rt_meter` budgets, rich per-op accounting, trap-on-exhaustion. (Phase 2.)
- The **breadth** of the allowlist and the `own` stdlib; the `passthrough` (Unsafe) stdlib;
  `open` BIFs. (Phase 2.)
- Trust tiers O/N; any NIF. Phase-1 runtime is **tier-P** (see Grounded facts).

## Deliverables

Concrete signatures (doc-comment every one per D8 — what / params / return / failure modes).

```gleam
//// rt_trap.gleam — Safe-mode trap surface (tier-P; cannot crash the node).
import twocore/ir.{type TrapReason}

@external(erlang, "erlang", "error")           // error-class; catchable; NOT throw/exit
fn erlang_error(reason: a) -> b

type Tag { WasmTrap }                            // 0-field ctor → Erlang atom 'wasm_trap'

/// Raise the WASM trap `reason` as a catchable Erlang error `{wasm_trap, Kind}`, where
/// `Kind` is the snake_case atom of the `TrapReason` constructor. NEVER returns
/// (diverges); typed `-> a` so it composes in any position the emitter places it.
pub fn raise(reason: TrapReason) -> a {
  erlang_error(#(WasmTrap, reason))
}
```

```gleam
//// rt_host.gleam — Safe-mode capability boundary: deny_all. Fail-closed (D4/D9).

/// The deny-all host dispatcher. EVERY call is rejected — there is no configuration,
/// argument, or capability string that makes it return. Raises a catchable
/// `{capability_denied, Capability, Name}` error. Phase-2 replaces this module with a
/// whitelist/open variant; Phase-1 ships ONLY deny-all, so Safe cannot be reconfigured
/// open (the fail-closed-by-construction property — TEST it).
pub fn call_host(capability: String, name: String, args: List(a)) -> b
```

```gleam
//// rt_meter.gleam — minimal fuel seam (D9). Process-local; cannot crash the node.

/// Charge `cost` fuel for the current process, then return `Nil` (the emitter discards
/// it and proceeds to the charged expression). Phase-1 ACCUMULATES into a process-local
/// counter so the seam is observable/testable; it does NOT yet enforce a budget or trap
/// on exhaustion (Phase 2). `cost` is a non-negative reduction-style estimate.
pub fn charge(cost: Int) -> Nil

pub fn fuel_consumed() -> Int   // test/Phase-2 support: read the running total
pub fn reset_fuel() -> Nil      // test support: zero the counter
```

```gleam
//// rt_stdlib.gleam — the minimal `own` stdlib (Safe). Tiny + auditable by design.

/// gcd(a, b): the greatest common divisor (Euclid). Tier-P, total, no trap, no host
/// access. The positive `call_host` → `own` path resolves to this (via ir_lower, 11).
/// Returns an Int. Pick ONE primary like this + at most one more; coordinate the
/// capability/name → fn mapping with 08 and 11.
pub fn gcd(a: Int, b: Int) -> Int
```

```gleam
//// rt_bif.gleam — Safe `allowlist` gate. BUILD-TIME (consulted by ir_lower, 11).

pub type BifTarget { BifTarget(module: String, function: String, arity: Int) }
pub type BifError  { NotAllowlisted(BifTarget) }

/// Is this concrete BEAM target on the small vetted Safe allowlist?
/// Returns Ok(Nil) if permitted, Error(NotAllowlisted(_)) otherwise (FAIL CLOSED — an
/// unknown target is rejected, never assumed safe). Total. The allowlist is a fixed,
/// small, build-controlled set; there is no Safe configuration that opens it (Phase 1).
pub fn check(target: BifTarget) -> Result(Nil, BifError)

pub fn allowlist() -> List(BifTarget)   // the vetted set, for audit + tests
```

**Algorithm shape / wiring:**
- `raise` and `call_host` *diverge* (raise an error). `charge` returns `Nil`. `gcd` returns
  an `Int`. `check` returns a `Result` (consumed by Gleam build-time code, not generated
  code).
- The **positive stdlib path**: `ir_lower` (11) recognises a `CallHost(capability, name)`
  whose `(capability, name)` is an `own`-stdlib entry, gates the resolved BEAM target
  through `rt_bif.check`, and rewrites it to a direct call into `rt_stdlib`. The
  **negative host path**: a `CallHost` to an un-granted host import stays a `call_host`
  into `rt_host` → deny-all → reject. You own the targets + the gate; **11 owns the
  rewrite, 08 owns the emit** — agree the `(capability,name) → rt_stdlib fn` map across
  08/09/11.

## Grounded facts you MUST honor

These were verified against the toolchain/spec; ignoring them forces a retrofit.

1. **Names/arities ARE the ABI.** `instance.gleam` documents the convention; emit_core
   emits exactly `call 'twocore@runtime@rt_trap':'raise'(R)`, `…rt_host':'call_host'(Cap,
   Name, Args)`, `…rt_meter':'charge'(Cost)`. **Freeze `raise/1`, `call_host/3`, `charge/1`
   (and the `rt_stdlib` fn names) with 08.** Verified: a Gleam module path maps to an
   Erlang module by replacing `/` with `@`; **public function names emit verbatim**, arity
   = parameter count.

2. **Gleam → Erlang value shapes (load-bearing for the ABI).** If generated code
   destructures a return value, the shape must match Gleam's compilation:
   - A **0-field custom-type constructor → snake_case atom** of its name. So
     `IntDivByZero → int_div_by_zero`, `IntOverflow → int_overflow`,
     `Unreachable → unreachable`, `IndirectCallTypeMismatch → indirect_call_type_mismatch`,
     `MemoryOutOfBounds → memory_out_of_bounds`. **A `TrapReason` value *is* its trap-kind
     atom** — this is why both trap paths converge (next fact).
   - `Ok(x) → {ok, x}`, `Error(e) → {error, e}`, `Nil → nil`, `#(a, b) → {a, b}`.

3. **Two trap paths, one atom.** The static `Trap(IntDivByZero)` node lowers to
   `call '…rt_trap':'raise'('int_div_by_zero')` (emitter passes the literal atom). The
   trapping-numeric path has `rt_num` return `{error, IntDivByZero}` and the emitter
   `case`s + calls `raise` with that `Reason`. Because `IntDivByZero` compiles to
   `int_div_by_zero` either way, **both deliver the identical atom** to `raise`. Keep
   `raise`'s parameter typed `TrapReason`.

4. **`raise` uses `erlang:error/1`, error-class — PITFALL.** It must surface as a
   *catchable error* so unit 07's harness can `try … catch error:{wasm_trap, Kind}` and map
   `Kind` to the spec's expected trap-message substring. **Do not** use Gleam `panic`
   (raises a `gleam`-flavoured term, not `{wasm_trap,_}`), nor `throw`/`exit` (wrong
   class). The reason term shape is exactly `{wasm_trap, Kind}` — freeze it with 07.

5. **WASM-spec trap-kind ↔ message (for 07's matcher — assert THIS, not the impl).**
   Per the WASM spec traps (<https://webassembly.github.io/spec/core/exec/instructions.html>)
   and the spec suite's `assert_trap` strings:
   | `TrapReason` | kind atom | spec message substring |
   |---|---|---|
   | `IntDivByZero` | `int_div_by_zero` | `integer divide by zero` |
   | `IntOverflow`  | `int_overflow`    | `integer overflow` |
   | `Unreachable`  | `unreachable`     | `unreachable` |
   Per §9.1: `div_s INT_MIN/-1` ⇒ `IntOverflow`; `_/0` ⇒ `IntDivByZero` (these are
   produced by `rt_num` in 06 — agree the atom with 06/08).

6. **Tier-P, transitively — PITFALL.** All Phase-1 runtime is **tier-P** (pure Gleam, no
   NIF, *cannot crash the node*). This claim only holds if every dependency holds it too:
   `erlang:error/1` raises (does not crash the node) ✔; any `gleam_stdlib` function you call
   must itself be tier-P safe — **verify each before calling it** (a `let assert`/partial
   function on a runtime value is a sandbox hole; §5 totality rule).

7. **Fail-closed is a TESTED property (D4).** `deny_all` rejects unconditionally; a
   non-allowlisted `rt_bif` target rejects; and **the Safe profile cannot be reconfigured
   into an unsafe posture** — Phase 1 simply ships no `whitelist`/`open`/`open-bif` variant
   to flip to. Test the rejection behavior, not the message text.

8. **Namespace hygiene.** Generated/compiled BEAM modules are `twocore@…`; any hand-written
   FFI test helper `.erl` is `twocore_…`. Never name a module `lists`, `maps`, `erlang`, ….

> **`rt_meter` mechanism + a flagged tension.** The brief permits the fuel counter in the
> **process dictionary**; that is process-local and node-safe, but the high-level §10 tier
> taxonomy classifies process-dictionary state as **tier-O**, not strict tier-P. Recommended
> Phase-1 resolution: use the pdict accumulator (it makes the seam *observable*, hence
> testable) and document it as "node-safe, OTP-native state — the node-safe boundary of
> tier-P." The strict-tier-P alternative is a pure no-op `charge`, but a no-op cannot be
> *observed*, so the seam can only be verified structurally in 08. Surface this choice in
> `state.md` so the planner can confirm which the meter seam should be.

## Verification — Definition of Done (D8)

Tests assert **security / spec behavior**, never "whatever the code emits."

- **`rt_trap`** — *spec trap taxonomy.* Assert `raise(reason)` raises an **error-class**
  exception whose reason is `{wasm_trap, kind}`, with `kind` the distinct atom per
  `TrapReason`, and that each `kind` maps to the WASM-spec message substring in Grounded
  fact 5. (Catch via a one-line `twocore_rt_test_ffi.erl` `try … catch error:R -> {error,R}`
  helper — namespace-hygienic.) The *kinds are distinguishable* and *match the spec* — not
  "raise returns X."
- **`rt_host`** — *fail-closed security.* For a spread of `(capability, name, args)`,
  `call_host` **always** rejects (never returns a value, never silently succeeds). Plus the
  **e2e** in 07/11: the `call_host`-import-under-deny-all program is **rejected through the
  full pipeline** (typed rejection, not a wrong result, not a panic).
- **`rt_meter`** — *seam exists end-to-end.* `reset_fuel()`; run an **`08 emit_core`
  fixture** whose IR contains `Charge` nodes; assert `fuel_consumed()` equals the summed
  cost (the instrumentation path executed). Also assert `charge(c)` returns `Nil` and is
  total for `c ≥ 0`. (This asserts OUR documented `charge` contract — metering is a policy
  seam, not a WASM-spec concept, D9.)
- **`rt_stdlib`** — *spec-correct math.* `gcd` against the **mathematical definition**
  (Euclid), not the code: `gcd(12,18)=6`, `gcd(18,12)=6`, `gcd(0,5)=5`, `gcd(5,0)=5`,
  `gcd(17,5)=1`, `gcd(0,0)=0`. Plus the **positive `call_host` → `own`** path exercised e2e
  in 07/11 (a program reaches `gcd` and gets the right answer).
- **`rt_bif`** — *fail-closed allowlist.* An allowlisted `BifTarget` ⇒ `Ok(Nil)`; any
  non-allowlisted target ⇒ `Error(NotAllowlisted(_))`. Assert the *closing*, and that there
  is no Safe path to `open` (the type/profile simply offers none).
- **Gate:** `gleam format --check src test` clean; `gleam build` with **no warnings**;
  **every public function doc-commented** with its contract and failure/divergence modes
  (D8); `gleam test` green before and after.
- **Prove the goal:** `div_u(x,0)` / `div_s(INT_MIN,-1)` trap with the right kind, the
  deny-all import rejects e2e, and the `own` function returns spec-correct results — all
  through 07/11's harness.

## Concurrency

**Splits cleanly into 5 parallel sub-tasks**, one per module + its test file. The seam is
clean because the modules **do not import each other** (only `rt_trap` imports
`twocore/ir` for `TrapReason`). The single shared prerequisite is the **ABI freeze**: pin
the public function **names + arities** (`raise/1`, `call_host/3`, `charge/1`, the
`rt_stdlib` fn names) with 08 first — after that, the five agents proceed independently.
`rt_bif`'s `BifTarget`/`check` shape must be pinned with **11** before 11 wires the gate,
but its implementation is independent of the other four.

## What this leaves for others

- **08 (`emit_core`)** — the runtime modules its binding chokepoint targets exist:
  `raise/1`, `call_host/3`, `charge/1`, and the resolved `rt_stdlib` calls.
- **11 (`ir_lower`/linker)** — can resolve `own`-stdlib `call_host` nodes to `rt_stdlib`
  targets, gate them through `rt_bif.check`, insert `charge`, and instantiate the Safe
  `Binding` knowing every module it names is implemented and fail-closed.
- **07 (conformance)** — can run the deny-all rejection e2e, match trap kinds to spec
  messages, and check the positive `own`-stdlib result against its definition.
