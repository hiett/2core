# Phase 4 — Overview & Shared Contracts

> **Read this after the Phase-1, Phase-2, and Phase-3 overviews.** Every decision on those
> pages **still holds** — one owner per file, runtime layers as Gleam modules reached through
> the binding chokepoint with **no ambient authority**, per-stage error types, floats-as-bit-
> patterns, named-label IR, the tier-O `cell` state strategy, the shared optimizer, the two
> named modes, spec-first tests, the strict Definition of Done. This page adds the Phase-4
> decisions **G1–G8**. Phases 1–3 are complete and green: **674 tests, 0 warnings, conformance
> 15747 / 411 / 0 under both profiles**, the optimizer proven sound, and an honest benchmark
> that measured tier-O memory as **~76× slower than hand-written Erlang** — the fact that
> motivates this phase.

---

## 0. Where Phase 4 sits (the platform, one paragraph)

Phase 3 proved the platform **correct, sandboxed, and fast-in-principle** (a sound optimizer,
the Unsafe mode, real CPU metering) — but its honest benchmark measured the **tier-O
paged-immutable-binary memory model** as the dominant cost: every store rebuilds a page, so a
memory-heavy kernel runs 76× slower than hand-written Erlang. Phase 3 also left the platform's
**headline pitch unbuilt**: the *"no OTP, no NIF, runs-anywhere"* tier-P build. Both gaps are the
**trust-tier axis** (high-level §10) — the second axis of the modular design, orthogonal to the
Safe/Unsafe policy axis Phase 3 built. Phase 4 makes it real: the **tier-P `threaded` state
strategy** (a purely-functional instance-state record threaded through generated code — the
runs-anywhere build), and the **tier-O/N memory & table backends** (`atomics` O(1) process-local;
`nif` the raw ceiling) that close the performance gap. No new frontend surface, no new IR node
types: Phase 4 is a **runtime + backend-seam + linker** phase, and its correctness bar is that
**every state strategy × memory tier keeps conformance green** and produces byte-identical results.

---

## 1. The Phase-4 goal (concrete and measurable)

> **Make the trust-tier ladder real.** Generated code runs under a chosen **state strategy**
> (`cell` tier-O, the Phase-2 default, *or* `threaded` tier-P — a purely-functional instance-state
> record threaded through every function, no process dictionary, no OTP-native state) and a chosen
> **memory tier** (`paged` tier-P *or* `atomics` tier-O O(1) *or* `nif` tier-N raw, Unsafe-only).
> A **`portable` (runs-anywhere)** profile — tier-P **instance state + numerics** — runs on a bare
> BEAM with **no native state and no NIF** (the Safe fuel/host cells are node-safe tier-O policy
> overlays) and is provably unable to crash the node; the tier-O `atomics`
> memory closes most of the Phase-3 performance gap. Every combination produces **byte-identical
> spec-correct results** and keeps **constant-space loops + preemption**.

### Acceptance (owned by the capstone)

| Area | Must demonstrate |
|---|---|
| **threaded state (tier-P)** | the whole Phase-1+2 acceptance corpus + spec suite runs under `state_strategy: threaded` with **byte-identical results and traps** to `cell`; a `threaded` build links **no** `rt_state` pdict **instance-state** cell (`'seed'`/`'get'`/`'put'`) and **zero** `atomics`/`ets`/`persistent_term`/NIF native state (the node-safe, process-local tier-O `rt_meter` fuel counter + `rt_host` policy cell are documented, **exempt** policy overlays) |
| **constant space under threaded (G4)** | `sum_to(100000)` and a memory-store loop run in **constant space** under `threaded` (the threaded instance-state record is a fixed-size handle to immutable structures — the loop-carried param does not grow the stack); preemption preserved (verified) |
| **runs-anywhere proof** | a tier-P `portable` build (threaded state + paged memory + bif numerics) loads and runs on a bare BEAM using **zero** `atomics`/`ets`/`persistent_term`/NIF native state **and zero** `rt_state` pdict **instance-state** cell (`'seed'`/`'get'`/`'put'`) — grep-verified; the node-safe tier-O `rt_meter` fuel counter + `rt_host` policy cell (BEAM builtins, cannot crash the node) are documented, **exempt** policy overlays — the "no OTP, no NIF" property |
| **tier-O `atomics` memory** | `atomics`-backed linear memory does O(1) load/store/grow, is **differentially identical** to the `paged`/`rebuild` oracle across `memory_trap`/`address`/`endianness` `.wast`, and is process-local (never shared — the threads non-goal holds); `atomics` **engages only for bounded/capped memories** (effective max ≤ the reserve cap), else the build is **fail-closed rejected** |
| **tier-N `nif` memory (interface + ceiling)** | the `nif` tier interface is defined and **forbidden in Safe** (the linker rejects `Safe + nif` fail-closed); a reference/skeleton proves the interface (the C NIF itself may be documented-deferred where a native toolchain is required) |
| **tier composition & fail-closed** | the linker composes `state_strategy × mem_tier × policy`; **Safe permits tier P or O, never N** (§6) — a Safe profile cannot be constructed with `nif`; the `portable` and `ceiling` profiles are explicit, tested opt-ins |
| **tier-aware differential** | for every shipped `(state_strategy, mem_tier)` combination the acceptance corpus gives identical results; the `rebuild` oracle holds every memory tier to the spec (§11) |
| **benchmark revisit (honest)** | re-run the Phase-3 benchmark with tier-O `atomics` memory (+ threaded where relevant) and report the new numbers vs `paged`, hand-written Erlang, and the native ceiling — **measured**, with methodology, in the committed report |

### Honest scope (G8 — do not overstate)

- **`atomics` is the real, node-safe O(1) win; `nif` is the documented ceiling.** Erlang `atomics`
  gives O(1) mutable storage with **no custom native code** (tier-O, cannot crash the node) — that
  is Phase 4's shipped performance lever. Tier-N `nif` (custom C, *can* crash the node) is the
  absolute ceiling; Phase 4 defines its **interface** and its **Safe-forbidden** status, and ships
  a reference/skeleton — the production C NIF may be **explicitly deferred** where it needs a
  native build toolchain. Do not claim a shipped C NIF unless one is actually built and tested.
- **Threads / shared memory remain a hard non-goal.** Every memory tier stays single-threaded /
  process-local (high-level §12). `atomics` is used **process-locally, never shared** — the only
  cost is the atomic barrier, and cross-process sharing is never enabled.
- **`state_strategy` and `mem_tier` are compile-time (B3), like metering.** A `threaded` build and
  a `cell` build are **different `.beam`s** (the calling convention differs); a `nif`-memory build
  and a `paged` build differ only in the linked `rt_mem` module. The single-`.beam` runtime-dispatch
  **B1** (Phase-3-deferred) stays deferred — evaluate but do not assume it lands here.
- **Deferred (state it):** SIMD, reference types, bulk memory, multi-memory, `memory64`, the WAT
  text parser, non-function imports/`spectest` (**Phase 5** — the complete-WASM-engine phase); the
  Porffor JS→WASM bridge (**Phase 6**); Arc/Gleam frontends; exception-handling / GC / stack-switching
  / component model (later). Tier-N numerics (`rt_num` `nif`) is out of scope (numerics stay tier-P `bif`).

---

## 2. The Phase-4 decisions (G1–G8)

Frozen for Phase 4. If you believe one is wrong, raise it with the planner **before** building.

### G1 — The keystone is the `state_strategy` axis (`cell` | `threaded`)

Instance state (the memory handle, mutable globals, the table) is reached today through **one**
`emit_core` state-access seam (`seam_call` — verified: every `MemLoad/Store/Size/Grow`,
`GlobalGet/Set`, `CallIndirect`, and the instantiate seeds route through it). Phase-2's E1 promised
the threaded build would be a **seam *expansion*, not a scattered rewrite** — and it is. The
**`state_strategy`** sub-axis (a new `Binding` field) selects how that seam lowers:
- **`cell`** (tier-O, Phase-2 default) — the seam emits `call '<state_module>':'op'(...)` against
  the per-process pdict cell; generated function arities are unchanged.
- **`threaded`** (tier-P, new) — the seam threads a purely-functional **instance-state record**
  through generated code: every function that touches state takes the record as a parameter and
  **returns the (possibly updated) record** (the uniform-threading rule §10 — mutable backends
  return the same handle, immutable backends return the updated structure, one signature serves
  both). No process dictionary; no OTP-native state; the true "runs-anywhere" build.

This is a **codegen-shape** change confined to `emit_core` + the runtime (G5), **not** a module
swap through the binding — exactly as E1 scoped it. The keystone freezes the `state_strategy`
field, the threaded instance-state record type + tier-P `rt_state` signatures, the seam-expansion
contract, and lands green.

### G2 — The memory trust-tier ladder: `paged` (P) → `atomics` (O) → `nif` (N)

`rt_mem`'s backend is selected by a **`mem_tier`** axis (a `Binding` field / the linked
`mem_module`), all behind the same interface (uniform behaviour signatures §10; a pure value-
threaded `mem_*` core already exists):
- **`paged`** (tier-P, Phase-2) — immutable-binary rebuild-on-write; universal, sparse-friendly,
  the benchmark bottleneck.
- **`atomics`** (tier-O, **new**) — O(1) process-local mutation backed by Erlang `atomics` (no
  custom native code; cannot crash the node). The shipped performance lever. `grow` under `atomics`
  is the sharp edge (fixed size at creation → pre-allocate to the **effective/capped max**); a no-max
  module with no cap is a **fail-closed link-time rejection** (`atomics` requires a bounded max ≤ the
  reserve cap) — never a silent 4 GiB pre-allocation and **never a silent `paged` fallback**; any
  degrade, if permitted, must be **explicit and reported**, per §10 — handle it explicitly.
- **`nif`** (tier-N, **new**, Unsafe-only) — raw O(1) native memory; the ceiling; **never in Safe**.
  Interface + Safe-forbidden status + a reference; the production C NIF may be documented-deferred.

`rt_table` gets `ets`/`atomics` tiers analogously. Every tier passes one **interface-conformance
suite** and is **differentially tested against the `rebuild` oracle** (§11) — done = passes the
suite, and the oracle itself is held to explicit spec-corner tests (E4).

### G3 — Tiers compose into deployment profiles; tier ⟂ policy (with one constraint)

The trust-tier axis (P/O/N) is **orthogonal** to the Safe/Unsafe policy axis (Phase 3), but they
compose with one hard constraint: **Safe permits tier P or O, never N** (§6). New named profiles the
linker composes (`state_strategy × mem_tier × policy`):
- **`portable`** (the runs-anywhere headline) — **tier-P instance state + numerics**: `threaded`
  state + `paged` memory + `bif` numerics, Safe policy. No native state, no NIF, cannot crash the
  node, runs on a bare BEAM (the Safe CPU-fuel counter + host-policy cell are node-safe, process-
  local tier-O policy overlays — **Safe permits tier P or O, never N**). The maximally-safe posture.
- **`ceiling`** (the perf build) — Unsafe + `atomics` (or `nif`) memory + `cell` state + aggressive
  optimizer. The fastest build.
- The existing `safe()`/`unsafe()` keep their Phase-3 meaning (tier-O `cell` + `paged`), now
  explicitly one point in the composed space.

### G4 — The threaded build must preserve constant-space loops & preemption

Threading a state record adds a **loop-carried parameter** and returns a **new record per store** —
the exact concern E1 flagged. Phase 4 must **prove** the tail-`apply` back-edge stays constant-space
under `threaded`: the instance-state record is a **fixed-size handle** to immutable structures (a
box of the mem/table/globals values), so threading it through the loop does not grow the stack, and
each store rebinds the box, not the whole loop frame. Preemption holds (it is ordinary BEAM code).
This is a **tested acceptance property** (`sum_to(100000)` and a store-loop in constant space under
threaded), not an assertion.

### G5 — The IR carries no handle operand (tier-agnostic); the retrofit is confined

Per E1, the IR's memory/global/table nodes are **tier-agnostic** — they carry **no handle operand**.
So `threaded` vs `cell` is **provably confined to `emit_core` (the seam) + the runtime**; there is
**no IR change and no frontend change**. Likewise the memory/table tiers are confined behind
`rt_mem`/`rt_table`. This is what makes a deep calling-convention change (threading a record through
every function) a *localized* seam expansion rather than a platform rewrite.

### G6 — Security & fail-closed for the tiers

- **Tier-N (`nif`) can crash the node → forbidden in Safe.** The linker **rejects** a `Safe + nif`
  binding fail-closed (there is no constructor that yields it). Tier-N is Unsafe-only.
- The **`portable` build is the maximally-safe posture** — **tier-P instance state + numerics**, no
  ambient native code, cannot crash the node, runs anywhere (the Safe fuel/host cells are node-safe
  tier-O policy overlays). This is the high-level pitch's "provably unable to take over the VM".
- **Memory bounds-checks hold in every tier** (the §11 security invariant): a bounds bug's worst case
  is a wrong/missing trap or a node-safe process crash, **never a host escape** (tiers P/O are
  memory-safe by construction; tier-N is the one place native code runs, gated to Unsafe/opt-in).
- The `rebuild` oracle holds every tier to the spec; the codegen no-ambient-authority invariant
  (D3a) holds under threaded (the seam still emits fixed `twocore@runtime@*` calls).

### G7 — No new frontend surface, no new IR node types; conformance-neutral

Phase 4 adds **no** `Expr`/`NumOp`/`ConvOp`/`TrapReason` variants and **no** `.ir` grammar changes.
The structural changes are: the `Binding` gains `state_strategy` + `mem_tier` (+ `table_tier`)
axes; `emit_core`'s seam expands to the threaded shape; new `rt_mem`/`rt_table` backend modules.
Both state strategies and all shipped memory tiers must keep the corpus + spec suite green
(`fail=0`) with byte-identical results — Phase 4 is conformance-neutral, a pure implementation-tier
expansion.

### G8 — Honest scope

See §1. `atomics` is the shipped O(1) win; `nif` is the interface + ceiling (C impl may be deferred).
Threads/shared-memory stays a hard non-goal (`atomics` process-local). `state_strategy`/`mem_tier` are
compile-time (B3); single-`.beam` B1 stays deferred. SIMD / reftypes / bulk-memory / multi-memory /
memory64 / WAT-parser / imports are **Phase 5**; the Porffor bridge is **Phase 6**. The performance
claim is **re-measured**, not asserted.

---

## 3. Dependency DAG — freeze milestones

```
WAVE 0   01 KEYSTONE (one owner):
            «STATE-STRATEGY-FROZEN» (Binding.state_strategy + threaded InstanceState record +
              tier-P rt_state sigs + the emit_core seam-expansion contract)
            «MEM-TIER-FROZEN» (Binding.mem_tier/table_tier + the rt_mem/rt_table backend interface +
              the Safe-forbids-nif linker rule)
                 │                                    │
   ┌─────────────┼───────────────┬────────────────────┼──────────────┬─────────────┐
   ▼ «STATE»     ▼ «STATE»        ▼ «MEM-TIER»          ▼ «MEM-TIER»   ▼ «MEM-TIER»  ▼ «STATE»+«MEM»
 ┌──────────┐ ┌───────────┐  ┌───────────┐  ┌──────────┐  ┌──────────┐  ┌──────────┐
 │02 emit    │ │03 rt_state│  │04 rt_mem  │  │05 rt_mem │  │06 rt_    │  │07 linker │
 │ threaded  │ │ threaded  │  │ atomics   │  │ nif      │  │ table    │  │ + profiles│
 │ seam      │ │ (tier-P)  │  │ (tier-O)  │  │ (tier-N, │  │ tiers    │  │ (compose,│
 │ expansion │ │           │  │           │  │ iface)   │  │ (O)      │  │ fail-cls)│
 └──────────┘ └───────────┘  └───────────┘  └──────────┘  └──────────┘  └──────────┘
   WAVE A        WAVE A          WAVE A         WAVE A        WAVE A        WAVE B
        ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌────────────────────────────────┐
        │08 pipeline│  │09 tier    │  │10 bench  │  │ 11 CAPSTONE: every (strategy × │
        │ + CLI     │  │ differ-   │  │ revisit  │  │  tier) conformance green +     │
        │ (select)  │  │ ential    │  │ (honest) │  │  runs-anywhere proof + report  │
        └──────────┘  └──────────┘  └──────────┘  └────────────────────────────────┘
          WAVE B         WAVE B         WAVE B                 WAVE C
```

- **The threaded seam expansion (02) is the critical path** — the deepest codegen change. It needs
  only the frozen `state_strategy` contract + the tier-P `rt_state` signatures (03), not their
  bodies. Start it first.
- **The memory/table tiers (04/05/06) parallelize** behind the frozen `rt_mem`/`rt_table` interface —
  independent runtime work, differentially tested against the oracle.
- **The linker (07) composes** the axes and enforces Safe-forbids-nif fail-closed.

*(Proposed unit split — the scoping agents may refine, as in Phase 3.)*

---

## 4. File-ownership map (D1)

> Single owner per file. Several units **extend** existing files (single-owner, additive). The
> keystone makes deliberate, documented cross-file reaches (extending `Binding` breaks every
> constructor).

| Unit | File(s) | Notes |
|---|---|---|
| **01** keystone | `runtime/instance.gleam` (`state_strategy`/`mem_tier`/`table_tier` fields + enums) · `runtime/rt_state.gleam` (threaded record type + tier-P sigs) · `backend/emit_core.gleam` *(seam contract doc)* · `runtime/profiles.gleam` *(reach — green)* | `«STATE-STRATEGY-FROZEN»` / `«MEM-TIER-FROZEN»`. Land green. |
| **02** threaded seam | `src/twocore/backend/emit_core.gleam` | Expand `seam_call`/`instantiate` to thread the instance-state record when `state_strategy: threaded`; the deepest change; extend the security-invariant test. |
| **03** rt_state threaded | `src/twocore/runtime/rt_state.gleam` | Owns **only** the tier-P purely-functional instance-state record + globals (`fresh`/`t_global_get`/`t_global_set` + the mem/table field seam), no pdict; does **not** import `rt_mem`/`rt_table` (opacity preserved). |
| **04** rt_mem atomics | `src/twocore/runtime/rt_mem_atomics.gleam` *(new module)* · `src/twocore/runtime/rt_mem.gleam` *(owner-additive)* | tier-O `atomics` O(1) backend in the **new** module; owner-additive **paged threaded wrappers** in the existing `rt_mem` (`t_load`/`t_store`/`t_size`/`t_grow`/`t_init_data` + `to_flat(mem)` + the `Dynamic`→`Mem` coercion); `t_grow` **charges fuel on success** (metered parity, G7); `atomics` `grow` pre-allocation; differential vs oracle. |
| **05** rt_mem nif | `src/twocore/runtime/rt_mem_nif.gleam` *(new module)* + FFI | tier-N `nif` interface (new module) + Safe-forbidden + reference/skeleton (C impl may be deferred). |
| **06** rt_table tiers | `src/twocore/runtime/rt_table_ets.gleam` · `src/twocore/runtime/rt_table_atomics.gleam` *(new modules)* · `src/twocore/runtime/rt_table.gleam` *(owner-additive)* | tier-O `ets`/`atomics` table backends in the **new** modules; owner-additive **paged threaded wrappers** (`t_init_elem`/`t_call_indirect`) in the existing `rt_table`. |
| **07** linker + profiles | `src/twocore/runtime/profiles.gleam` (extend) | `portable`/`ceiling` profiles; compose axes; **Safe-forbids-nif** fail-closed. |
| **08** pipeline + CLI | `src/twocore/pipeline.gleam`, `src/twocore.gleam` (extend) | select `state_strategy`/`mem_tier` per profile; CLI flags; every stage independently invokable. |
| **09** tier differential | `test/twocore/**` | every `(strategy × tier)` combination gives identical corpus results; constant-space-under-threaded. |
| **10** benchmark revisit | `smoke/**`, `docs/phase-4-benchmark.md` | re-measure with `atomics` (+ threaded); honest numbers vs `paged`/hand-written/native. |
| **11** capstone | `test/twocore/conformance/**`, `docs/` | conformance `fail=0` for every shipped combination + the runs-anywhere proof + refreshed image. |

---

## 5. How to claim & complete (same as Phases 1–3)

Read this page → your unit doc → [`specs/state.md`](../state.md). Set status `in-progress`; confirm
your freeze milestones; build to the Definition of Done (D8: **spec-cited** tests, doc comments on
every public function, `gleam format --check src test` clean, **zero warnings**, and your unit's
conformance/interface suite passing — "done" is *the suite passes*, never "it compiles"). Update
`state.md` with what you leave. When in doubt about a foundational decision, **ask the planner**.
The manager QA-gates (`format`/`build`/`test` + conformance `fail=0` + a spec-DoD read) and
commits+pushes each unit to `main`.

---

## 6. Deferred to Phase 5+ (explicit — stated, not dropped)

- **Phase 5 (a complete WASM engine):** reference types (externref/funcref, `table.get/set/copy/
  fill`, typed `select_t`, `elem.wast`); bulk memory (`memory.fill/copy/init`, `data.drop`);
  multi-memory; `memory64`; the WAT text parser; non-function imports + the `spectest` module; SIMD.
- **Phase 6 (the second frontend):** the Porffor JS→WASM bridge (+ the Porffor-ABI `rt_host` shim)
  → "JS on the BEAM."
- **Later:** Arc as a native JS frontend; the Erlang/Gleam frontend; exception-handling, GC,
  stack-switching, the component model; the single-`.beam` runtime-dispatch **B1** binding; tier-N
  numerics.
