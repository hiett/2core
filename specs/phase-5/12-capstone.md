# Unit 12 — Capstone: the Phase-5 proof-of-goal (complete-surface green + the skip-count drop)

> **1–3 owners · Wave C (last) · depends on the freezes AND the landed work of 01–11.** Read
> [`00-overview.md`](00-overview.md) (H1–H8), the provisional frozen surface, then Phase-4
> [`11`](../phase-4/11-capstone.md) (the full-matrix `driver.pipeline_with` run + the runs-anywhere
> proof you extend) and Phase-3 [`11`](../phase-3/11-capstone.md) (the two-profile conformance run
> and the `Outcome` normalization you reuse). Phases 1–4 are complete and green: **906 tests, 0
> warnings, conformance 15747 / 411 / 0 under every shipped `(mode × state_strategy × mem_tier)`
> binding**, the optimizer proven sound, the trust-tier ladder real, the runs-anywhere headline
> concrete. Phase 5 is the **first phase since Phase 2 to grow the IR** (H7): it completes the
> standardized WebAssembly surface *except SIMD*.

---

## Context

Phase 5 makes one claim only a capstone can prove: **the engine now executes the complete
standardized WebAssembly surface — reference types, bulk memory & table ops, multiple memories,
64-bit memories, non-function imports + the `spectest` host module, and the WAT text format — and
it does so spec-correctly under *both* named modes and *every* shipped `state_strategy × mem_tier`
combination, while the entire Phase-1..4 corpus and previously-passing suite stay byte-identical
(H7).** Unlike Phases 3 and 4 (which added no IR nodes and no spec files, so their capstones were
pure *re-drive-the-old-corpus-under-a-new-axis* proofs), Phase 5 **adds surface**: new `.wast`
categories light up and the pinned suite's **skip count drops materially** while `fail` stays `0`.
So this capstone owns two things the prior capstones did not: (1) an **end-to-end green proof over
the new surface** under the full mode × tier matrix, and (2) the **honest skip-count-drop headline**
— before/after numbers, `fail == 0`, and a *categorized* residual-skip breakdown that states what
is still deferred (SIMD, extended-const, GC-reftypes) rather than hiding it.

Everything fine-grained — the per-op reftype/bulk/table semantics differentials, the WAT
`parse ≡ decode∘wat2wasm` differential, the `spectest`/import link tests, the per-tier runtime
oracle — is **owned by units 02–11**. This unit does **not** re-derive them; it **confirms** they
are green and committed, then adds the **whole-suite headline checkpoints** that only the terminal
unit can make: the matrix run over the enlarged allowlist, the runs-anywhere re-confirmation for the
new surface, the conformance-neutrality proof, the SVG/docs refresh, and the honest close. This
**closes Phase 5**.

The proof surface is six proofs + one image/docs refresh:

| # | Proof | Decision |
|---|---|---|
| 1 | **complete-surface green** — reftypes / bulk / multi-mem / [mem64] / spectest-imports / WAT-only files run `fail == 0` end-to-end under **both** profiles and **every** shipped `(state_strategy × mem_tier)` | H1–H4/H6/H7 |
| 2 | **the skip-count DROP headline** — the pinned suite's skip count drops from **411** to the measured post-Phase-5 count as whole categories light up; **`fail == 0` and `pass` rises**; residual skips **categorized honestly** | overview §1 headline / H8 |
| 3 | **conformance-neutral** — the whole Phase-1..4 acceptance corpus + previously-passing allowlist stay **byte-identical** under both profiles and every `(state_strategy × mem_tier)` (defaults route the new surface away, H7) | H7 |
| 4 | **runs-anywhere re-confirmed for the new surface** — a reftype-table / bulk-memory / multi-memory module runs green under the tier-P `portable` build (`threaded`), grep-verified 0 native + executed byte-identical to the `cell`/`paged` oracle | H3/H6 (G1/G3/G6) |
| 5 | **differential vs `wasmtime` + WAT-from-our-parser confirmed** — unit 11's differential (new surface held to a conformant engine) + the previously-un-`wast2json`-able files running **from our own `parse_script`** are green and committed | H5/overview §1 |
| 6 | **honest close** — what Phase 5 proved; what is deferred (SIMD→Phase 6, memory64-if-cut, extended-const, GC-reftypes, Porffor→Phase 7, a production C NIF) — stated, not dropped | H8 |
| — | **image + docs refresh** — `docs/wasm-conformance.svg` regenerated to the new counts; footnote → Phase-5 scope; a short `docs/phase-5-surface.md` recording the before/after headline | overview §1 |

---

## Deliverables & freeze milestones

**Consumes** (every Phase-5 freeze + landed unit):
- `«IR3-FROZEN»` / `«RT3-SIG-FROZEN»` / `«INSTANTIATE3»` (P5-01) — the reftype `ValType` +
  reference value model, the H2/H3 `Expr` nodes, `Module.memories` + the memory-index axis, the
  memory64 `IdxType`, the import/export state variants, the `TableDecl` reftype tag, the passive/
  droppable segment model, any new `TrapReason`, and the non-function-import + `spectest`
  instantiation/link contract.
- Units 02–08 (landed) — `.ir` round-trips the new surface (02); decode/validate/lower carry it
  through the frontend (03/04/05); `emit_core` lowers every new IR node through the runtime seam and
  routes memory by index (06); `rt_table` (07) and `rt_mem` (08) implement the typed-reference /
  bulk / multi-mem / [mem64] runtime under every tier × strategy.
- Unit 09 (landed) — non-function imports wired as **provided state**, the build-fixed `spectest`
  registry, fail-closed unsatisfied-import, export-of-state, and the `(register …)` mechanism.
- Unit 10 (landed) — `frontend/wasm/wat.gleam` (`parse_module`/`parse_script`/`Script`), the WAT
  text frontend + the `.wast` script command layer.
- Unit 11 (landed) — the conformance **expansion**: the enlarged allowlist (reftype/bulk/multi-mem/
  [mem64]/spectest/WAT-only files), the per-category suites, the differential vs `wasmtime`, and the
  honest pass/skip/fail recount.

**Produces** (terminal — nothing downstream depends on it): the complete-surface matrix run + the
new-surface runs-anywhere proof under `test/twocore/conformance/**`, the refreshed conformance image
+ the before/after headline doc, and the honest close-of-phase statement in `state.md`. No
publish-day-1 stub — this unit consumes every freeze and emits nothing others build on.

---

## Files owned

- `test/twocore/conformance/conformance_test.gleam` *(extend, single-owner)* — the full-matrix run
  now spans the **enlarged** allowlist (P5-11): the new tier-touching files (reftype/table/bulk/
  multi-mem/[mem64]/spectest) join `run_combo`'s per-tier sweep; the WAT-only + pure-numeric files
  stay in the two-profile `run_suite` runs. Asserts `fail == 0 && pass > 0` per binding (proofs 1,3).
- `test/twocore/conformance/new_surface_test.gleam` *(new)* — the **complete-surface end-to-end**
  proof (proof 1): a small capstone-owned set of new-surface modules (a reftype table, a
  bulk-memory kernel, a two-memory module, a `spectest`-importer, and — if it lands — a memory64
  module) driven through `driver.pipeline_with` under both profiles × every shipped combo, each
  spec-correct and byte-identical across bindings. This is the fine-grained backstop behind the
  whole-suite matrix run, over programs *authored to exercise the new nodes deliberately*.
- `test/twocore/conformance/runs_anywhere_test.gleam` *(extend, single-owner)* — add the new-surface
  runs-anywhere checkpoint (proof 4): the reftype-table / bulk-memory / multi-memory modules compile
  under `profiles.portable()` with **zero** native primitives and **zero** `rt_state` instance-cell
  seam, and execute byte-identical to the `cell`/`paged` oracle. Reuses the existing grep + execute
  harness; adds the new-surface programs to its local list.
- `test/twocore/conformance/corpus/*.wat` (+ `.wasm`/`.expected`) *(new fixtures, single-owner)* —
  the handful of new-surface acceptance modules the two tests above drive (see §H — the ownership
  seam vs `combos.corpus_programs`).
- `docs/wasm-conformance.svg` + `scripts/gen-conformance-svg.sh` footnote *(extend)* — regenerated to
  the **new** counts; footnote → Phase-5 scope ("complete surface minus SIMD; skip-count dropped").
- `docs/phase-5-surface.md` *(new)* — the honest before/after headline: the 15747 / 411 / 0 baseline,
  the post-Phase-5 pass/skip/fail, the category breakdown of what lit up, and the categorized
  residual skips (the honest close in prose).
- *(confirm, do **not** re-own)* unit 11's `test/twocore/conformance/**` per-category suites +
  `wasmtime` differential (proof 5); unit 10's `test/twocore/frontend/wasm/wat*_test.gleam`
  differential (proof 5); unit 02's `.ir` round-trip; unit 09's import/spectest link tests. The
  capstone asserts they are green and committed; it does not re-derive them.

> `new_surface_test.gleam` and the `corpus/*.wat` additions are fresh — no ownership collision. The
> per-op runtime/oracle differentials belong to 07/08; the per-category suite + `wasmtime`
> differential belong to 11; this unit owns only the **whole-suite** matrix run, the
> **complete-surface** end-to-end backstop, and the runs-anywhere property.

---

## Depends on

- `«IR3-FROZEN»` / `«RT3-SIG-FROZEN»` / `«INSTANTIATE3»` (01) — the frozen surface every proof
  compiles against.
- Units 02–11 (landed) — a frontend that decodes/validates/lowers the new surface, an `emit_core`
  that lowers it through the seam, runtime tiers that execute it under every strategy, the imports/
  `spectest`/linker contract, the WAT parser, and the conformance expansion.
- `driver.pipeline_with(binding: Binding) -> Driver` (Phase-3, verified in-tree; unchanged) — the
  single binding-parameterized `decode → validate → lower → ir_to_core(_, binding) → build →
  instantiate → invoke` code path. The capstone re-uses it unchanged and only enumerates bindings.
- `combos.gleam` (Phase-4, `test/twocore/tier/`) — `shipped`/`binding_for`/`evaluate`/
  `count_occurrences`/`corpus_programs`. The capstone consumes it read-only (see §H for the corpus
  seam).

---

## A. The matrix — one binding-parameterized driver, now over the new surface

Every proof here holds the *program* fixed and varies the *`Binding`*, exactly as Phases 3 and 4
did. Phase 3 generalized the conformance driver to `driver.pipeline_with(binding)`; Phase 4 wired
`ir_to_core` to select the `state_strategy` codegen shape + the tier `mem_module`/`table_module`
from the binding; Phase 5 grows the *IR that flows through that path* but **not the path itself**.
So the capstone re-uses `driver.pipeline_with` unchanged and only enumerates the axis bindings — it
re-implements no compiler logic, exactly the discipline of every prior capstone.

The **shipped matrix** (from `combos.shipped`, unchanged):

```gleam
let base = profiles.safe()   // Cell / Paged / TablePaged — the Phase-2/3/4 oracle posture
combos.cell_paged        // Cell × Paged     — the oracle
combos.threaded_paged    // Threaded × Paged — == the portable core (runs-anywhere)
combos.cell_atomics      // Cell × Atomics   — tier-O O(1) memory, pdict convention
combos.threaded_atomics  // Threaded × Atomics — record-threaded O(1) memory
combos.cell_nif          // Cell × Nif       — the tier-N skeleton (Unsafe-only)
```

Each run reduces to the Phase-3 normalized `Outcome` per `(export, args)` — raw bit pattern (D5);
trap collapsed to the spec phrase via `rt_trap.spec_trap_message`; `Rejected` for a fail-closed
non-build — so two bindings are compared by a single `==` over spec-observable behaviour, **never**
over `.core` text or IR shape (which the strategy/tier is *allowed* to change: a threaded reftype
table has a different arity; an `atomics` bulk-copy is a different term). Phase 5's new observable
surface is entirely captured by this `Outcome`:

- **A reference value** is observed as its spec-visible projection: `ref.is_null` → an `i32` bit
  pattern; a `funcref` reached through `call_indirect` → the callee's result bits or the trap phrase;
  an `externref` round-tripped through a table/global → identity preserved (the same host term back)
  — the suite observes it via `ref.is_null` / an `eq` on a returned externref (spec §4.4.6). The
  capstone never inspects a reference's internal shape; opacity (H6) means there is nothing to
  inspect.
- **A bulk op's effect** is observed as the resulting memory/table **byte image** on a subsequent
  load/`table.get`, or as the trap phrase when the range is out of bounds — both already `Outcome`s.
- **A memory index / address width** is invisible to `Outcome` by construction (H3): a multi-memory
  program observes memory-1 vs memory-0 only through loads that already produce value bits; a
  memory64 program observes `i64` addressing only through the values it loads/stores.

So the same `==`-over-`Outcome` comparison that proved Phases 2–4 correct proves Phase 5 correct —
the new surface added observables, not a new *kind* of observation.

---

## B. Proof 1 — the complete new surface, green end-to-end (H1–H4/H6/H7)

**The bar.** Every Phase-5 feature executes **spec-correctly** through `load → instantiate → invoke`,
under **both** `profiles.safe()`/`unsafe()` and **every** shipped `(state_strategy × mem_tier)`
combination. Two layers prove it, coarse and fine:

**(a) Whole-suite (via `conformance_test.gleam`).** Unit 11 adds the new-surface files to the pinned
allowlist; the capstone's `run_combo` sweep now drives them per-binding. The new **tier-touching**
files — anything that reads/writes a table, a memory, a global, or a reference through instance
state — join the matrix sweep (they are exactly what the tier axis touches). The new **pure** files
(e.g. `ref.is_null` over locals, typed `select` over numeric operands) run under the two full-profile
`run_suite` passes, where any regression surfaces, and are excluded from the ×5 matrix sweep for the
same CI-OOM reason `matrix_skip_numeric` already documents.

**(b) Complete-surface backstop (via `new_surface_test.gleam`).** The whole-suite run is broad but
diffuse; the capstone also drives a **deliberately-authored** set of new-surface modules that each
exercise a specific new node, so a single mis-lowered op fails on a named program rather than
hiding in a large file. Each module is run under both profiles × every combo and asserted (1)
spec-correct against its `.expected`, and (2) byte-identical across all bindings:

| Program | Exercises | Spec anchor |
|---|---|---|
| `reftable` | `ref.null`/`ref.func`/`ref.is_null`, `table.get/set/size/grow/fill`, a null `call_indirect` slot → **trap `uninitialized element`**, a typed `select` over funcrefs, multiple tables + a passive & a declarative element segment + `table.init`/`table.copy`/`elem.drop` | spec §4.4.6 (table/ref instructions); §4.4.7 (`table.init`/`copy`/`elem.drop`); §4.4.8 trap on null indirect slot |
| `externbox` | `externref` held in a table/global, passed to/from a `spectest`-style host fn, `ref.is_null`-tested, and returned to the host **without forgery/inspection** (opacity, H6) | spec §2.3.3 (reference types); §7 embedding |
| `bulkmem` | `memory.fill`/`memory.copy` (overlapping ranges, **memmove**), `memory.init` from a passive data segment, `data.drop` then a re-`init` (dropped ⇒ zero-length no-op / trap), an out-of-bounds op → **trap with no partial write** | spec §4.4.7 (bulk memory); the eager-bounds-trap rule |
| `multimem` | two memories; loads/stores/`memory.size`/`memory.grow`/`memory.copy` **across** memory indices; memory-0 alone stays byte-identical to Phase-4 | spec multi-memory proposal (finalized); §4.4.7 memidx immediate |
| `mem64` *(iff H8 keeps it)* | a 64-bit memory: `i64`-addressed load/store, a large (> 2³²) offset bounds-trap, `memory.size`/`grow` returning `i64` | spec memory64 proposal; §4.4.7 with `i64` address type |
| `spectestimp` | imports `spectest.global_i32`, `spectest.table`, `spectest.memory`, and calls `spectest.print_i32`; `(register …)` a prior module and import its export; an **unsatisfied import fails closed at link time** | spec §7 embedding; the reference-interpreter `spectest` host module; H4 |

- **Every op is bounds-/type-checked → trap (H6).** `reftable`'s null-slot `call_indirect` traps
  `uninitialized element`; a `table.set` past the end traps `out of bounds table access`; `bulkmem`'s
  OOB `memory.fill` traps `out of bounds memory access` **before any byte is written** (the spec's
  finalized bulk-memory semantics check the whole range first — no partial effect). These trap
  phrases are exactly the ones `rt_trap.spec_trap_message` already maps (H6: likely no new
  `TrapReason`; if the keystone added one, its phrase is asserted here).
- **Passive/droppable segments are instance state (H2).** `bulkmem`'s `data.drop` and `reftable`'s
  `elem.drop` mark a segment empty; a subsequent `*.init` with non-zero length from a dropped segment
  traps (or is a no-op for zero length) per spec. This drop state threads the **existing** state seam
  — `cell` in the pdict, `threaded` in the record — so it is byte-identical across strategies, which
  the matrix sweep proves.
- **`spectest` is a build-fixed provider (H4/D3a).** `spectestimp` links against the literal-`case`
  `spectest` registry (no ambient `apply`); an unsatisfied import is a **link-time** `Rejected`
  `Outcome`, reached identically under every binding (fail-closed, never an ambient default).

---

## C. Proof 2 — the skip-count DROP headline (the phase's proof-of-goal)

Phase 5's headline is the one number the prior three phases could not move: the pinned spec suite's
**skip count drops** as whole categories light up. This is the honest measurement, reported
before/after with a categorized residual.

**The baseline (measured, committed).** Phases 1–4 close at **15747 pass / 411 skip / 0 fail** over
the pinned allowlist. The 411 skips fall into categories the ALLOWLIST already annotates:

| Skip category (pre-Phase-5) | Approx. where | Lit up by |
|---|---|---|
| reference types (`funcref`/`externref` asserts, typed `select`, the reftype multi-table `call_indirect` module) | `select`, `call_indirect`, `global` in-file skips + un-allowlisted `ref_*`/`table_*`/`elem`/`select` files | P5-03/04/05/07 (reftypes + tables) |
| bulk memory & table (`memory.fill/copy/init`, `data.drop`, `table.init/copy`, `elem.drop`) | un-allowlisted `bulk`/`memory_fill`/`memory_copy`/`memory_init`/`table_init`/`table_copy` files | P5-05/07/08 |
| multi-memory | the un-convertible multi-memory files (`memory`/`table`/`memory_grow` variants at the pin) | P5-03/05/08 |
| memory64 | `align --enable-memory64` in-file skips + the memory64 files | P5-08 *(iff H8 keeps mem64)* |
| non-function imports + `spectest` | every file importing `spectest.*` (the biggest single unlock — many files import it) | P5-09 |
| WAT-only / un-`wast2json`-able files, text-format `assert_malformed` | `float_literals`' 78 text-format asserts + the files un-convertible at the pin | P5-10 (our own `parse_script`) |

**The proof (whole-suite, via `conformance_test.gleam` + `docs/phase-5-surface.md`).** The capstone
runs the **enlarged** allowlist (P5-11's addition) and asserts, honestly:

```gleam
// Post-Phase-5 totals (measured by the run; the exact numbers are recorded in phase-5-surface.md):
assert total.fail == 0                 // the invariant — no category lit up wrong
assert total.pass > 15747              // pass STRICTLY rises (new files + newly-passing in-file asserts)
assert total.skip < 411                // skip STRICTLY drops (categories lit up)
```

- **`fail == 0` is the hard invariant.** Lighting a category up is only real if it lights up
  *correct*: a mis-lowered `memory.copy` or a wrong null-slot trap would flip a formerly-skipped
  assertion to **fail**, not pass. `fail == 0` over the enlarged suite is the whole-phase net.
- **The strict inequalities are the headline.** `pass` must strictly rise and `skip` must strictly
  drop — a change-detector-proof, spec-sourced statement (the expected values are baked into the
  vendored `.wast`/JSON, not our output). The *exact* post-Phase-5 pass/skip counts are **measured by
  the run**, not asserted as magic numbers here (per D8: no change-detector); `phase-5-surface.md`
  records them as the committed before/after.
- **The residual is categorized, honestly (H8).** Whatever still skips after Phase 5 is stated by
  category in `phase-5-surface.md`, never left as an opaque number:
  - **SIMD** — the `v128` value type + ~236 lane instructions → **Phase 6** (the single largest
    proposal; overview §1). Every `simd_*` file and every in-file `v128` assert stays a *categorized*
    skip, printed by `print_skip_reasons`.
  - **extended-const** — `global.wast`'s `$z3`/`$z5` extended-constant-expression inits are a
    *separate* proposal, not Phase-5 scope; they stay skipped, categorized.
  - **GC-proposal reference types** — typed function references + `struct`/`array`/`i31` are the GC
    proposal (later); anything exercising them stays skipped.
  - **memory64 — iff cut (H8).** If memory64 is honestly deferred to Phase 6, its files stay
    skipped, categorized as "memory64 → Phase 6" — never claimed. If it lands, they pass and this
    row disappears.
  - **genuinely un-runnable at the pin** — anything that needs a proposal or tool feature outside
    Phase-5 scope is a *stated* parse-skip (P5-10's scope-honesty rule: an explicit categorized
    skip, never a silent mis-parse).

The honest reading: Phase 5 does not reach 0 skips (SIMD alone is thousands of assertions) — it
reaches **"complete surface minus SIMD"**, and says so in numbers.

---

## D. Proof 3 — conformance-neutral (H7)

**The bar (H7).** A module with **one 32-bit memory, funcref-only active elements, function-only
imports, and no bulk/ref ops** compiles **byte-identically** to Phase-4. The IR grew, but the
*defaults* route the new surface away: `memories = [MemoryDecl(_, _, Idx32)]`, `TableDecl.ref_ty =
FuncRef`, `ElemMode = ElemActive`, `DataMode = DataActive(0, _)`, mem index `0` everywhere. So the
entire Phase-1..4 acceptance corpus and every previously-passing allowlist assertion must produce
the *same* `Outcome` under Phase-5 code as they did before.

Two assertions carry it, and they are **already in the suite** — the point of proof 3 is that they
did **not move**:

- **The prior allowlist counts are unchanged where the category is unchanged.** The pure-numeric
  files (`i32`/`i64`/`f32`/`f64`/`conversions`/…) and the Phase-2 memory/table/global files stay at
  their Phase-4 pass counts under both profiles and every combo (their skips only *drop* where a
  formerly-skipped in-file assert lit up — never rise). A Phase-5 change that perturbed a Phase-4
  result (an accidental mem-index-0 regression, a reftype tag leaking into a funcref table) would
  flip one of these to fail.
- **The corpus stays byte-identical across bindings.** `new_surface_test.gleam`'s cross-binding
  `==`-over-`Outcome` (proof 1b) *includes* the legacy corpus programs where they overlap; and the
  existing Phase-4 corpus differential (unit 09, confirmed in §F) re-runs unchanged — the capstone
  confirms it stays green, i.e. Phase-5 did not perturb the tier axis.

The strongest form of proof 3 is **byte-level, at the emitter**: for a Phase-4 module (one 32-bit
memory, funcref active table, function-only imports, no bulk/ref ops), the Phase-5 `emit_core`
output is **textually identical** to what Phase-4 emitted. Unit 06 owns that emitter-level
byte-identity test (the H7 default-neutrality assertion in `emit_core`); the capstone **confirms** it
is green and adds the whole-suite behavioural neutrality above. (The capstone does not re-own an
`emit_core` test — D1.)

---

## E. Proof 4 — runs-anywhere re-confirmed for the new surface (H3/H6 — G1/G3/G6)

Phase 4 proved the tier-P `portable` build (`Threaded` state + `Paged` memory + `bif` numerics,
Safe) runs the *Phase-4* corpus on a bare BEAM. Phase 5 grew the surface, so the runs-anywhere
property must be **re-confirmed for the new nodes**: a reftype table, a bulk-memory kernel, and a
multi-memory module must *also* run under `portable` with no native code and no crashable instance
state. `runs_anywhere_test.gleam` extends its existing harness (unchanged shape) with the new-surface
programs:

**(a) Grep-verified (static).** The `profiles.portable()` `.core` of `reftable`/`bulkmem`/`multimem`
links **zero** `atomics`/`ets`/`persistent_term`/NIF and emits **zero** `rt_state` pdict
*instance-cell* seam — and **non-vacuously** names the threaded runtime families the new nodes route
through:

```gleam
// New-surface programs carry the SAME zero-native / zero-instance-cell property (G1/G6):
for name in ["reftable", "bulkmem", "multimem"] {
  let core = portable_core(name)
  assert count(core, "atomics") == 0 && count(core, "ets") == 0
  assert count(core, "persistent_term") == 0 && count(core, "load_nif") == 0
  assert count(core, "'seed'") == 0            // no pdict instance-cell seam (Threaded)
}
// Non-vacuity: the new nodes DO route through the threaded runtime (a real replacement, not absence):
assert count(portable_core("reftable"), "'t_table_get'") > 0   // threaded reftype table accessor
assert count(portable_core("bulkmem"),  "'t_mem_fill'")  > 0   // threaded bulk-memory family
assert count(portable_core("multimem"), "rt_state")      > 0   // memories vector lives in the record
```

> **Seam note (P5-07/08 naming).** The exact threaded accessor atoms (`t_table_get`, `t_mem_fill`,
> the memories-vector accessor) are **owned by units 07/08**. The capstone greps for whatever names
> those units froze; the strings above are placeholders pinned to the `t_*` convention P4-03
> established. If 07/08 name them differently, the capstone's grep tokens follow — flagged in Open
> questions so the reconcile pass keeps them in sync.

**(b) Executed (dynamic).** The new-surface corpus runs under `profiles.portable()` through
`load → instantiate → invoke` on a bare BEAM, byte-identical to the `cell`/`paged` oracle
(`profiles.safe()`) — values and traps alike. This re-confirms that the reference value model, the
bulk ops, the passive-segment drop state, and the memories vector all thread through the
purely-functional record without a native backend and without a crashable pdict cell.

**The security posture (H6, G6).** Because no native code is linked, the worst case of a
bounds/type bug in the new surface under `portable` is a **wrong/missing trap or a node-safe process
crash — never a host escape**. `externref` opacity holds by construction (a `portable` build cannot
forge one — there is no native seam to do so). This is the same "runs on a bare BEAM, provably
unable to take over the VM" property Phase 4 proved, now covering the whole surface (spec §7
*Embedding*: the embedder's memory-safety invariant holds when the whole subsystem is immutable BEAM
values). The one honest caveat is unchanged: a Safe `portable` build keeps the node-safe tier-O
`rt_meter` fuel counter + `rt_host` policy cell (pdict, present on every BEAM) — asserted *present*,
exactly as the Phase-4 proof documents.

---

## F. Proof 5 — differential vs `wasmtime` + WAT-from-our-parser (H5; confirmed, not re-derived)

The two claims that make the new surface *trustworthy* rather than merely *green* are owned by units
10 and 11; the capstone confirms they are green and committed and adds one end-to-end checkpoint each.

**Differential vs `wasmtime` (unit 11).** The new surface's expected values are, wherever the
executable is on `PATH`, cross-checked against a conformant engine (`wasmtime`) — not only against the
values baked into the vendored `.wast` — exactly as the Phase-1 Tier-B oracle does, skipping
gracefully when `wasmtime` is absent. The capstone asserts unit 11's differential suite passes as
part of `gleam test`; it does not re-run `wasmtime` itself. A reftype/bulk/multi-mem result that
matched the baked `.wast` but diverged from `wasmtime` (a stale pin) would go red in unit 11.

**WAT-from-our-parser (unit 10 — the real payoff of H5).** The suite files that were
**un-`wast2json`-able at the pin** — the reason so many files skipped at all — now run **from our own
`parse_script`**: the conformance runner drives them through `frontend/wasm/wat.gleam`'s `Script`
directly, no external `wat2wasm`/`wast2json`. The capstone confirms:

```gleam
// The differential DoD (unit 10): our parser is equivalent to the reference tool over the corpus.
assert wat_diff_suite_is_green()          // parse_module ≡ decode∘wat2wasm ; parse_script ≡ wast2json
// The payoff (this capstone's checkpoint): at least one previously-un-convertible file now PASSES
// through our own parse_script — the skip it was becomes a pass, proving H5 unblocked the suite.
assert wat_only_file_runs_from_our_parser("<a previously-un-wast2json-able allowlist file>")
```

This is the concrete link between H5 (the parser is a first-class frontend, not a fixture crutch) and
proof 2 (the skip drop): a chunk of the skip-count drop is *specifically* files that only run because
we now parse them ourselves. `phase-5-surface.md` attributes that slice of the drop to the WAT parser
explicitly.

---

## G. Conformance refresh + the honest close (overview §1 / H8)

**Image refresh.** Regenerate `docs/wasm-conformance.svg`
(`RUN_VENDOR=1 scripts/gen-conformance-svg.sh`) to the **new** counts (unlike Phases 3–4, the numbers
**do** move — that is the point of a surface phase). Update the generator footnote from "Phase 4:
green under every shipped tier — conformance-neutral" to **"Phase 5: complete WebAssembly surface
minus SIMD — reference types, bulk memory, multi-memory[, memory64], `spectest` imports, and the WAT
text parser; skip-count dropped, `fail == 0` under every shipped tier."** The generator reads the
`TOTAL` line from the same conformance test, so the image tracks the enlarged allowlist automatically.

**The before/after doc (`docs/phase-5-surface.md`).** A short, honest artifact:

- the **15747 / 411 / 0** baseline and the post-Phase-5 pass/skip/fail (measured);
- the **category breakdown** of what lit up (reftypes / bulk / multi-mem / [mem64] / spectest / WAT),
  with the WAT-parser-attributable slice called out (§F);
- the **categorized residual skips** (SIMD → Phase 6; extended-const; GC-reftypes; memory64-if-cut);
- one line per proof pointing at the test file that proves it.

**The honest close of Phase 5 (committed in `state.md`):**

- **Proved:** the engine executes the **complete standardized WebAssembly surface except SIMD** —
  reference types (`funcref`/`externref` as first-class values; `ref.null/func/is_null`; `table.get/
  set/grow/size/fill`; typed `select`; multiple tables; active + passive + declarative element
  segments), bulk memory & table ops (`memory.fill/copy/init`, `data.drop`, `table.init/copy`,
  `elem.drop` with overlap-correct memmove + eager-bounds-trap + droppable segments), multiple
  memories, non-function imports + the `spectest` host module + `(register …)`, and the WAT text
  parser — all **spec-differentially correct** (held to the baked `.wast` + `wasmtime`), under **both
  modes** and **every shipped `state_strategy × mem_tier`**, **conformance-neutral by default** (H7),
  and **runs-anywhere** for the new surface (tier-P `portable`, grep-verified + executed). The
  **skip count dropped materially** with `fail == 0`.
- **Did not prove / explicitly deferred (H8):** **SIMD → Phase 6** (the single largest proposal, its
  own focused phase); **memory64** shipped *iff its `.wast` files actually ran* — if quality forced
  the cut, it joins SIMD in **Phase 6**, stated not claimed; **extended-const** and **GC-proposal
  reference types** (typed function refs + `struct`/`array`/`i31`) are separate proposals, later; the
  **Porffor JS→WASM bridge → Phase 7** ("JS on the BEAM"); a **production C NIF** for tier-N memory
  stays documented-deferred (the interface + skeleton ship, the C impl needs a native toolchain);
  Arc/Gleam frontends, exception-handling / GC / stack-switching / the component model, and the
  single-`.beam` runtime-dispatch **B1** binding remain deferred. **WASI** stays an `rt_host`
  implementation, out of core. No performance claim beyond Phase 4's — Phase 5 is a surface phase; its
  only performance obligation is **negative** (constant-space loops + preemption preserved, no
  regression), which proofs 3–4 carry.

---

## Effect / soundness / security note

- **No ambient authority survives the new surface (D3a/H6).** The reference/table/bulk seam still
  emits fixed `twocore@runtime@*` module atoms with literal function names; `spectest` and every host
  function are a **build-fixed literal `case`** (no `apply/3`); an `externref` is an opaque BEAM term
  Safe code can hold/pass/null-test but never forge or inspect; the only runtime-data input reaching a
  control transfer is still the integer `call_indirect` index (now through a *typed reference* slot
  that traps on null/type-mismatch). Unit 06 extends the D3a security-invariant test to the new nodes;
  proof 4's grep is the structural cross-check.
- **Every new op is bounds-/type-checked → trap, before any write (H6).** Table access OOB →
  `TableOutOfBounds`; null reference where a value is required → `UninitializedElement`;
  `call_indirect` type mismatch → `IndirectCallTypeMismatch`; a bulk op out of range →
  `MemoryOutOfBounds`/`TableOutOfBounds` **eagerly** (no partial effect). The worst case of a bounds
  bug is a wrong/missing trap or a node-safe crash — never a host escape. A tier cannot be unsound and
  pass: an unsound bulk-copy (wrong overlap direction, a partial write on a trap) changes an
  `Outcome`, so "green" means *every observable was preserved across every tier and both modes*, not
  "it compiled." Proof 1's whole-suite run is the net; units 07/08's oracle differential is the
  op-by-op microscope behind it.
- **Imports fail closed (H4/H6).** An unsatisfied import is a link-time `Rejected` `Outcome`, reached
  identically under every binding; imported globals/tables/memories are **provided state**, not the
  deny-all `call_host` capability — the capability model for host *functions* is unchanged. No
  unsafe-by-omission path: a module that names no import map for a required import does not silently
  get an ambient default.
- **Floats-as-bits (D5) unchanged.** Reference values are term-layer; numeric values in the new
  surface (a memory64 `i64` address, a global holding an `f64` reference-adjacent value) are still raw
  bit patterns, never a BEAM-double round-trip — so NaN payloads and `-0.0` stay byte-identical across
  `paged`/`atomics`/`threaded` for every new op that touches memory.
- **Fail-closed default (D4).** Every run that does not name a tier-P/N posture or an Unsafe mode is
  `cell`/`paged`/Safe; the new surface adds observables, not a new default posture.

---

## Verification — Definition of Done (D8)

- **Proof 1 green (complete surface):** `reftable`/`externbox`/`bulkmem`/`multimem`/`spectestimp`
  (+`mem64` iff H8 keeps it) run spec-correct against `.expected` and byte-identical across **both**
  profiles × **every** shipped `(state_strategy × mem_tier)`; the enlarged allowlist is
  `fail == 0 && pass > 0` per binding. Cites spec §2.3.3 (reference types), §4.4.6 (table/ref
  instructions), §4.4.7 (bulk memory/table), §4.4.8 (null-slot trap), §7 (embedding); the
  multi-memory + memory64 proposal docs for those two.
- **Proof 2 green (the headline):** over the enlarged suite, `fail == 0`, `pass > 15747` (strictly),
  `skip < 411` (strictly); the exact post counts are measured and recorded in `phase-5-surface.md`
  with the category breakdown and the **categorized** residual skips (SIMD/extended-const/GC/mem64-if-
  cut) — no opaque number, no change-detector magic constant.
- **Proof 3 confirmed (neutral):** the Phase-1..4 corpus + prior allowlist counts are unchanged where
  the category is unchanged (skips only drop, never rise; no formerly-passing assert flips); unit 06's
  emitter-level byte-identity test (Phase-4 module ⇒ byte-identical `.core`) is green in `gleam test`.
- **Proof 4 green (runs-anywhere, new surface):** `reftable`/`bulkmem`/`multimem` under
  `profiles.portable()` grep **zero** native primitives + **zero** `rt_state` instance-cell seam, name
  the threaded new-surface families non-vacuously, and execute byte-identical to the `cell`/`paged`
  oracle (spec §7 embedding).
- **Proof 5 confirmed:** unit 11's `wasmtime` differential + unit 10's `parse_module ≡ decode∘wat2wasm`
  / `parse_script ≡ wast2json` suites pass in `gleam test`; at least one previously-un-`wast2json`-able
  file runs green **from our own `parse_script`**.
- **Image + docs:** `docs/wasm-conformance.svg` regenerated to the new counts; footnote → Phase-5
  scope; `docs/phase-5-surface.md` committed with the before/after + categorized residual.
- **`gleam format --check src test` clean; `gleam build` ZERO warnings; `gleam test` stays green
  (≥ 906, now higher); conformance `fail == 0` across every shipped combination.** Done = **the suites
  pass**, never "it compiles."
- Update `state.md`: announce Phase 5 proven, with the honest close (§G) and the deferred set.

---

## What this unit leaves

Phase 5 is proven: the engine executes the **complete standardized WebAssembly surface except SIMD**.
Reference types are first-class term-layer values (funcref/externref, `ref.*`, the full table/select
surface, active + passive + declarative elements); bulk memory & table ops are spec-exact (memmove
overlap, eager-bounds-trap, droppable segments); multiple memories and 64-bit memories are a
memory-index + address-width axis confined to the seam + runtime; non-function imports are provided
state wired through a real instantiation contract with the `spectest` host module and `(register …)`;
and the WAT text parser is a first-class frontend that unblocked the previously-un-convertible suite
files. All of it is spec-differentially correct under both modes and every shipped
`state_strategy × mem_tier`, conformance-neutral by default, and runs-anywhere for the new surface —
and the pinned suite's **skip count dropped materially with `fail == 0`**, reported honestly with
categorized residuals.

**Deferred, stated not dropped (H8):** **SIMD** — the `v128` value type + ~236 lane instructions →
**Phase 6** (the single largest proposal, given its own focused phase); **memory64** joins it *iff*
cut from Phase 5 (claimed only if its `.wast` files ran); **extended-const** and **GC-proposal
reference types** (typed function refs + `struct`/`array`/`i31`) are separate proposals, later; the
**Porffor JS→WASM bridge → Phase 7** ("JS on the BEAM"); a **production C NIF** for tier-N memory
stays documented-deferred; and later — Arc/Gleam frontends, exception-handling / GC / stack-switching
/ the component model, the single-`.beam` runtime-dispatch **B1**. **WASI** stays an `rt_host` impl,
out of core. Phase 5 completes the *surface*; the second frontend (Phase 7) and SIMD (Phase 6) are the
next moves.

---

## Open questions (for the planner / cross-unit sync)

1. **New-surface acceptance corpus ownership (the seam vs `combos.corpus_programs`).** The runs-
   anywhere proof (§E) and the complete-surface backstop (§B) need a handful of *new-surface* corpus
   modules (`reftable`/`bulkmem`/`multimem`/`spectestimp`/[`mem64`]). `combos.corpus_programs` (the
   list the Phase-4 runs-anywhere test iterates) lives in `test/twocore/tier/combos.gleam` — a
   **Phase-4 file (P4-09-owned)**, not this unit's. **Proposal:** the capstone owns its new-surface
   modules under a **capstone-local** `test/twocore/conformance/corpus/*.wat` + a local list in
   `new_surface_test.gleam`/`runs_anywhere_test.gleam`, rather than reaching into `combos.gleam`. If
   the reconcile pass would rather these join `combos.corpus_programs` (so unit 09's tier differential
   also sweeps them), that is a P4-09/P5-11 co-ownership decision to pin — flagged so the module set is
   not double-owned or orphaned.

2. **Which new-surface files go in the ×5 matrix vs the two-profile run (CI OOM).** Phase 4 already
   excludes the ~13.5k pure-numeric assertions from the ×5 sweep (`matrix_skip_numeric`) to avoid CI
   OOM. The new tier-touching files (reftype/bulk/multi-mem/spectest) *should* be in the matrix (they
   exercise the tier axis); the new pure files (typed `select` over numerics, `ref.is_null` over
   locals) should not. **Proposal:** P5-11 tags each new allowlist file tier-touching-or-not, and the
   capstone's `run_combo` keep-filter uses that tag rather than a hand-maintained list. Needs P5-11
   sync on the classification.

3. **memory64 in the matrix — present iff it landed (H8).** The `mem64` backstop program and the
   memory64 allowlist files must be asserted **only if** P5-08 actually shipped memory64 and its
   `.wast` files run. **Proposal:** gate the `mem64` rows behind a single capstone constant (e.g.
   `mem64_shipped: Bool` read from a P5-01/P5-08 predicate) so the capstone is honest either way — it
   claims memory64 in the close *only* when the rows are live. If cut, the `mem64` files stay a
   categorized skip, and the close says "memory64 → Phase 6."

4. **Threaded accessor names for the new-surface grep (§E).** The runs-anywhere grep needs the exact
   threaded runtime atoms P5-07/08 froze for the new nodes (`t_table_get`, `t_mem_fill`, the
   memories-vector accessor, the passive-segment drop-state accessor). Placeholders here follow the
   P4-03 `t_*` convention; the capstone's tokens must track whatever 07/08 name. **Proposal:** 07/08
   publish the threaded accessor names in `«RT3-SIG-FROZEN»` so the capstone greps a documented set,
   not a guessed one.

5. **`spectest` imported state under `threaded`.** `spectestimp` imports a `spectest.memory`/`.table`/
   `.global` — *provided state* that P5-09 wires into the instance. Under the `threaded` strategy this
   provided state must live in the **record** (not a pdict cell), or the `spectest`-importing files
   fail under `threaded_paged`/`threaded_atomics`. The capstone's matrix sweep would catch a
   divergence, but it should be **confirmed** that P5-09 threads imported state through both
   strategies. **Proposal:** confirm in reconcile that the imported-state wiring is strategy-agnostic
   (record for `threaded`, pdict for `cell`) — a known `rt_state` seam already flagged in the overview
   §4 as the 08/09/keystone co-ownership to pin.
