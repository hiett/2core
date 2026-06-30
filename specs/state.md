# Implementation State — what's taken, by whom, and what it leaves

> The swarm's shared ledger. Before claiming work, read it; after finishing, update it.
> It maps the canonical spec ([`00-high-level.md`](00-high-level.md)) onto concrete work
> units and tracks their status. The detailed unit specs live in
> [`phase-1/`](phase-1/). Read [`phase-1/00-overview.md`](phase-1/00-overview.md) first.

**Legend — status:** `unclaimed` · `in-progress (name)` · `blocked (on …)` · `done`
**Legend — freeze milestone:** a published, compiling type stub that unblocks downstream
units (see overview §3). Announce milestones here the moment they land.

---

## Freeze milestones (the real scheduling gates)

| Milestone | Produced by | Status | Unblocks |
|---|---|---|---|
| `«IR-FROZEN»` — `ir.gleam` + `ir-grammar.md` | 01 | **FROZEN ✓** | 02, 08, 10, 11 |
| `«ABI-FROZEN»` — `instance.gleam` (Binding + convention) | 01 | **FROZEN ✓** | 08, 09, 11 |
| `«RTNUM-SIG-FROZEN»` — `rt_num.gleam` signatures (90 fns) | 01 | **FROZEN ✓** | 06, 08 |
| `«CORE-AST»` — `backend/core_erlang.gleam` types | 03 (day 1) | `unclaimed` | 08 |
| `«WASM-AST»` — `frontend/wasm/ast.gleam` types + `DecodeError` | 05 (day 1) | `unclaimed` | 10 (validate) |
| `«FFI-SHIM»` — `twocore_codegen_ffi.erl` (compile+load) | 04 | **published ✓** | 03 (verify), 08/10 (e2e tests) |

---

## Phase 1 — units

Phase-1 goal & honest scope: see [`phase-1/00-overview.md`](phase-1/00-overview.md) §1.

| Unit | Doc | Owner / status | Depends on (freeze) | What it leaves when `done` |
|---|---|---|---|---|
| **01** Interface freeze | [`01`](phase-1/01-interface-freeze.md) | **done** | — | IR types, `.ir` grammar, runtime ABI, rt_num signatures (90 fns, `todo` bodies → 06), PipelineError stub all frozen; neutrality review signed off; 3 golden `.ir` + strawman test green. The keystones exist. |
| **02** `.ir` printer & parser | [`02`](phase-1/02-ir-textual-form.md) | `unclaimed` | `«IR-FROZEN»` | `.ir` round-trips; every stage can dump/load IR as the inter-stage contract (D7). |
| **03** Core Erlang AST & printer | [`03`](phase-1/03-core-erlang-backend.md) | `unclaimed` | — (self-frozen) | A `.core` AST + verified pretty-printer; `08` can build Core Erlang and get compilable text. |
| **04** `build_beam` driver & FFI | [`04`](phase-1/04-build-beam-driver.md) | **done** | — | `.core` text → loaded `.beam` proven (hand-written `.core` compiled, loaded, ran on BEAM); the `«FFI-SHIM»`; `gleam_erlang` added. |
| **05** WASM decoder & AST | [`05`](phase-1/05-wasm-decoder.md) | `unclaimed` | — | `.wasm` → WASM AST (`«WASM-AST»`); LEB128 + fail-closed decoding; frontend input ready. |
| **06** `rt_num` numerics (`bif`) | [`06`](phase-1/06-rt-num-numerics.md) | `unclaimed` | `«RTNUM-SIG-FROZEN»` | The single source of numeric-fidelity truth (tier-P reference impl), property-tested vs the spec. |
| **07** Conformance harness & corpus | [`07`](phase-1/07-conformance-harness.md) | `unclaimed` | — (engine side); IR/backend (compare side) | The spec-suite oracle + the Phase-1 acceptance corpus; "is our output spec-correct?" answerable. |
| **08** `emit_core` (IR → Core) | [`08`](phase-1/08-emit-core.md) | `unclaimed` | `«IR-FROZEN»`,`«CORE-AST»`,`«ABI-FROZEN»`,`«RTNUM-SIG-FROZEN»` | The backend: structured control → `letrec`+tail-calls; the binding chokepoint; codegen security-invariant test. |
| **09** Runtime defaults | [`09`](phase-1/09-runtime-defaults.md) | `unclaimed` | `«ABI-FROZEN»` | `rt_trap`/`rt_host`(deny-all)/`rt_meter`(fuel)/`rt_stdlib`(own min)/`rt_bif`(allowlist) — the Safe seams. |
| **10** WASM validate & lower | [`10`](phase-1/10-wasm-validate-and-lower.md) | `unclaimed` | `«WASM-AST»` (validate); `«IR-FROZEN»` (lower) | `full` validation (security boundary) + WASM AST → shared IR. |
| **11** ir_lower, linker, Safe profile, CLI (capstone) | [`11`](phase-1/11-ir-lower-linker-cli.md) | `unclaimed` | all of the above | The `ir_lower` pass, the linker + Safe profile, the per-stage CLI (decision #5), and the **end-to-end differential acceptance** — Phase-1 goal proven. |

---

## High-level spec coverage — which §/decision each unit "takes"

> So nothing in the canonical spec is silently dropped, and so two units don't claim the
> same ground. "Taken" = an owning Phase-1 unit exists. "Deferred" = explicitly Phase-2+.

| High-level spec item | Taken by | Notes |
|---|---|---|
| §3 IR core types | 01 | Full surface frozen now (lock-now decisions #1/#2/#4). |
| §3 `.ir` textual form | 01 (grammar), 02 (impl) | The inter-stage contract (D7). |
| §3 dual value model + explicit conversions | 01 (types), 06 (numeric semantics) | Floats as bits (D5). Term layer is lock-now placeholder. |
| §3 optional linear memory | 01 (IR models it) | **Runtime deferred** — no `rt_mem` in Phase 1 (corpus has no memory). |
| §3 `call_host` capability node | 01 (IR), 08 (lowering), 09 (deny-all) | Exercised end-to-end (D9). |
| §3 `trap` / `charge` effects | 01 (IR), 08 (emit), 06 (trap raise), 09 (rt_meter) | Metering **seam** wired now (D9). |
| §4 FW WASM frontend (decode/validate/ssa/structure) | 05 (decode), 10 (validate+lower) | `full` validator only; `subset`/`assume_valid` deferred. |
| §4 M1 IR core + textual form | 01, 02 | |
| §4 M2 optimizer (`ir_opt`) | — | **Deferred to Phase 2.** |
| §4 M3 stdlib + capability lowering (`ir_lower`) | 11 (ir_lower) | Minimal: capability/stdlib resolution + `charge` insertion. |
| §4 B1 emitter (`emit_core`) | 08 | `core_text` format; `cerl_ast` alt deferred. |
| §4 B2 driver (`build_beam`) | 04 | `forms`/in-memory path (via `core_scan`/`core_parse`); `file` fallback. |
| §4 R-num numerics (`bif`) | 06 | tier-P reference impl; `nif` deferred. |
| §4 R-trap traps | 09 | `error` impl. |
| §4 R-state instance state | 01/08 (calling convention) | tier-P; **no threaded record in Phase 1** (D3d) — no mutable state. |
| §4 R-host host/capability dispatch | 09 | `deny_all` (default); `whitelist`/`open` deferred. |
| §4 R-meter metering | 09 | minimal `fuel`; `none` is the Unsafe default (deferred). |
| §4 R-std standard library | 09 (runtime), 11 (resolution) | `own` minimal (1–2 fns); breadth + `passthrough` deferred. |
| §4 R-bif BEAM-function gate | 09 | `allowlist` (enforced minimal); `open` deferred. |
| §4 R-mem / R-tab linear-memory subsystem | — | **Deferred to Phase 2.** |
| §4 I instantiation (`rt_instance`) | 11 (linker) | Safe profile only; Unsafe deferred. |
| §5 backend lowering (letrec/tail-calls, calls, numerics, traps) | 08 | Verified loop template in the unit doc. |
| §5 codegen security invariants | 08 (test) | No ambient-authority `apply` (D3a); asserted structurally. |
| §6 Safe mode | 09 + 11 (seams) | **Seams wired & exercised, not a full sandbox (D9).** |
| §6 Unsafe mode | — | **Deferred to Phase 2.** |
| §9.1 numeric fidelity invariants | 06 | Property-tested + end-to-end via the corpus. |
| §9.2 preemptive/compiled execution | 08 (tail-calls) + 04 (it's real BEAM code) | Verified: a `letrec` tail loop ran 100k iters in constant space on OTP 29. |
| §11 differential testing (spec `.wast`) | 07 | Tier-A (expected baked in `.wast`) + Tier-B (engine oracle). |
| §11 interface-conformance suites | each unit's "Verification" | Done = suite passes, not "compiles" (D8). |
| §8.2 Porffor JS→WASM bridge | — | **Deferred to Phase 2+.** |
| §8.3/§8.4 Arc/Gleam frontends | — | **Deferred (later phases).** |
| §12 WAT text parser | — | **Deferred to Phase 2** (use `wat2wasm` for fixtures). |
| §12 bulk memory / reftypes / SIMD / tail-call proposal / threads | — | Deferred / non-goal per §12/§26. |

---

## Phase 2 preview (not yet specced into units)

Once Phase 1's vertical slice is green, the natural next wave (to be broken down later):
broaden WASM 1.0 coverage (full `br_table`/`call_indirect`, globals, `memory` load/store);
the `rt_mem` tiers (`rebuild`→`paged`→`atomics`) + `rt_table`; the `baseline` optimizer;
the WAT parser; the Unsafe profile (passthrough stdlib, open BIFs, `aggressive` optimizer);
broaden the `own` stdlib + BIF allowlist; then the Porffor bridge + its ABI `rt_host` shim.

---

## Change log

- **Unit 04 landed (build_beam + FFI shim).** A hand-written `.core` module compiled,
  loaded via `code:load_binary`, and ran on the BEAM with correct results (incl.
  hot-replace), and malformed `.core` returns a typed `BuildError` (no panic).
  `gleam_erlang v1.3.0` added. Two real bugs were corrected in the unit-doc's "verified"
  shim (they only surface when called *from Gleam*, not from an Erlang shell): the
  scan/parse error branches returned a bare binary instead of a `[Binary]` list, and
  `load_module`'s filename must be an Erlang charlist (`unicode:characters_to_list`), not
  a Gleam-`String` binary. Both fixed + documented inline in `twocore_codegen_ffi.erl`.
- **Unit 01 landed (interface freeze).** IR types, runtime `Binding` ABI + calling
  convention, the complete 90-function `rt_num` signature set (`todo` bodies, owned next
  by unit 06), and `PipelineError` are frozen. `gleam build` clean except the 90
  sanctioned `todo` warnings; `gleam test` green (7); neutrality review (D6) passed.
  Two notes for downstream: (a) the seeded `ir-grammar.md`/golden examples were corrected
  to **strict ANF** (the original nested `num` exprs in `return`/`if` operand positions,
  which the `Value`-typed fields forbid); (b) `rt_num` stub args are underscore-prefixed
  (`_a`,`_b`) to keep the build warning-free — unit 06 restores `a`/`b` with the bodies.
- **Planning, post-review reconciliation (initial drafting):** after the unit docs were
  drafted, these refinements were folded back into the frozen foundations so the
  contracts are internally consistent:
  - `Function` carries **named params** (`params: List(Local)` + `result`), with
    `signature/1` deriving the `FuncType` — closing the `%p0`/`%p1` round-trip gap
    between `ir.gleam` and `ir-grammar.md` (flagged by unit 02). Grammar updated.
  - `«RTNUM-SIG-FROZEN»` now requires the **complete** Phase-1 `rt_num` name list
    (integers + i64 mirror + conversions + floats), by a fixed naming rule — so units 06
    and 08 don't race on spellings (flagged by 06/08).
  - `CallHost` has **two fates**: `ir_lower` (11) rewrites a resolved `own`-stdlib call
    into a direct `rt_stdlib` call; a genuine host import stays a deny-all `call_host`.
    `rt_bif` is a **build-time** gate consulted by `ir_lower`, not a `Binding` field /
    runtime call — its gate shape freezes with unit 11 (flagged by 09/11).
  - Tier framing corrected: Phase-1 compute is tier-P; the **metering** counter may be
    tier-O (pdict), which Safe permits (P or O, never N) — unit 09 may instead ship a
    pure no-op `charge` (flagged by 09).
  - `ir_lower` reads `ir.gleam` **+ the `Binding` type** (for `mode`/policy); the
    ownership note was relaxed accordingly (flagged by 11).
  - Dependency note added: units 04/08/09 will `gleam add gleam_erlang` (flagged by 04).
  - `00-overview` §3 DAG/prose numbering corrected (decoder = 05, build_beam = 04,
    validate+lower = 10; `«WASM-AST»` unblocks 10) (flagged by 05).
