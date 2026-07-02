# Unit P5-07 — rt_table extension (reference tables + bulk + multi-table)

> **One owner · Wave A (parallel with 03/04/05/06/08/09/10) · gated on `«IR3-FROZEN»`
> + `«RT3-SIG-FROZEN»` (keystone P5-01) and the multi-table / passive-element `rt_state`
> seam (keystone + P5-09).** Read [`00-overview.md`](00-overview.md) (H1–H8), the
> provisional surface (`scratchpad/provisional-surface.md`), and the two template units
> [`../phase-2/05-rt-table.md`](../phase-2/05-rt-table.md) and
> [`../phase-4/06-rt-table-tiers.md`](../phase-4/06-rt-table-tiers.md) first. You extend the
> three funcref-table backends into **typed reference tables** with the full **reference-types +
> bulk-table** op surface, **multiple tables**, and **passive/droppable element segments** —
> across the `map` / `ets` / `atomics` tiers *and* both `cell` / `threaded` state strategies,
> held **differentially to the oracle**. Your load-bearing constraint: the Phase-2/4
> `call_indirect` dispatch stays **byte-identical and fail-closed**, every new op is
> **eager-bounds-trap** (no partial writes), and `externref` stays **opaque**.

---

## Context

Phases 2 and 4 shipped a funcref table that is **immutable after instantiation**: only
`init_elem` (an active flag-0 element segment) ever writes it, and `call_indirect` reads it
through the proven 3-fault fail-closed dispatch (bounds → null → exact `FuncType`), byte-identical
across `TablePaged` (tier-P, immutable `Dict`), `TableEts` (tier-O, private ETS), and
`TableAtomics` (tier-O, `atomics` occupancy + immutable companion). See §A of
[`../phase-4/06-rt-table-tiers.md`](../phase-4/06-rt-table-tiers.md) — which explicitly noted
that "`table.set`/`table.grow`/`table.fill`/`table.copy` are reference-types ops **deferred to
Phase 5** … where the tier-O `ets`/`atomics` substrates deliver their real O(1)-mutation payoff."

**Phase 5 is that phase.** The reference-types proposal (finalized into WebAssembly 2.0 / the
living standard, <https://webassembly.github.io/spec/core/>) makes `funcref`/`externref`
**first-class values** and tables **runtime-mutable typed reference stores**: `table.get`,
`table.set`, `table.size`, `table.grow`, `table.fill`. The bulk-memory proposal
(<https://github.com/WebAssembly/bulk-memory-operations>, also finalized into 2.0) adds
`table.init`/`table.copy`/`elem.drop` and **passive/declarative** element segments that carry
**droppable instance state**. Reference-types also lifts the single-table restriction —
`call_indirect` and every table op carry an explicit **table index**, so a module may declare
**many** tables. This unit grows the three backends to cover all of it while keeping the existing
dispatch untouched.

The table is where the D3a **no-ambient-authority** invariant is most at risk (it is the
build-controlled call-graph edge selected by runtime data), and where `externref`-opacity (H6)
lives (Safe code may hold/pass/store/null-test a host reference but never forge or inspect it).
Both properties must survive the new mutable surface unchanged.

---

## Goal

Extend `rt_table` / `rt_table_ets` / `rt_table_atomics` from an immutable funcref store into a
**typed, runtime-mutable, multi-table reference store** implementing — behind the frozen uniform
interface, identically across every `(table_tier × state_strategy)` — the reference-types + bulk
op set:

- **`get`** (read a slot's reference value; `TableOutOfBounds` trap out of range),
- **`set`** (write a reference value; eager `TableOutOfBounds`),
- **`size`** (current slot count),
- **`grow`** (append `delta` slots initialised to a reference value; return the **old size** or
  **`-1`** past `max`/cap; **charge fuel like `memory.grow`** — metered parity with the meter),
- **`fill`** (write a reference value into a run of slots; **eager bounds → trap, no partial
  writes**),
- **`table.init`** (copy a run from a **passive/active** element segment into a table; eager
  bounds against *both* the segment and the table),
- **`table.copy`** (copy a run between two tables; **overlap-correct `memmove`**; eager bounds),
- **`elem.drop`** (mark a passive element segment empty),

plus **multiple tables** (every op carries a table index; index 0 stays byte-identical to
Phase-4) and the **passive-element droppable instance state** threaded through the existing state
seam. The Phase-2/4 `new` / `init_elem` / `call_indirect` / `t_*` heads stay **unchanged** so a
funcref-only single-table module compiles byte-identically (H7); `externref` values are stored
**verbatim and never inspected** (opacity); every new op is **fail-closed** (a bounds/type bug
yields a wrong/missing trap or a node-safe crash, never a host escape).

---

## Files owned

| File | Status |
|---|---|
| `src/twocore/runtime/rt_table.gleam` | **EXTEND (owner-additive)** — the `TablePaged` reftype/bulk/multi-table ops (cell + threaded), generalising the immutable `Dict` core. The Phase-2 cell surface (`new`/`init_elem`/`call_indirect`) and the P4-06 paged `t_*` wrappers stay behaviourally unchanged. |
| `src/twocore/runtime/rt_table_ets.gleam` | **EXTEND (owner-additive)** — the `TableEts` reftype/bulk/multi-table ops (cell + threaded), reusing the in-place ETS substrate. |
| `src/twocore/runtime/rt_table_atomics.gleam` | **EXTEND (owner-additive)** — the `TableAtomics` reftype/bulk/multi-table ops (cell + threaded); `set`/`fill`/`grow`/`init`/`copy` over the `occ` array + companion; the atomics `grow` sharp edge (§G). |
| `test/twocore/runtime/rt_table_reftype_test.gleam` *(new)* | Spec-cited suite for the new ops on `TablePaged`. |
| `test/twocore/runtime/rt_table_ets_reftype_test.gleam` *(new)* | Same suite on `TableEts`. |
| `test/twocore/runtime/rt_table_atomics_reftype_test.gleam` *(new)* | Same suite on `TableAtomics`. |
| `test/twocore/runtime/rt_table_reftype_differential_test.gleam` *(new)* | One op-trace across every `(table_tier × state_strategy)` vs the `TablePaged` oracle (§H). |

**You do NOT own** (describe the seam, do not claim — D1): `runtime/rt_state.gleam` (keystone +
P5-09 — the **tables vector** + the **passive-element drop state**), `ir.gleam` (keystone —
`RefType`, `TableDecl.ref_ty`, the `TableGet/Set/Size/Grow/Fill/Init/Copy`/`ElemDrop` `Expr`
nodes, `ElementSegment` shape, any `TrapReason`), `backend/emit_core.gleam` (P5-06 — lowering the
new nodes + the reference-value ABI), `runtime/rt_meter.gleam` (P3 — `charge`),
`runtime/profiles.gleam` / `instance.gleam` (linker/`Binding`). Any reference-value
representation this unit needs from the keystone is pinned in §A and flagged in Open questions.

---

## Deliverables & freeze milestones

**Produces no freeze milestone** — this unit *consumes* `«IR3-FROZEN»` (the `RefType` /
`TableDecl.ref_ty` / new table `Expr` nodes / `ElementSegment` shape / `TrapReason`),
`«RT3-SIG-FROZEN»` (the keystone-frozen extended `rt_table` signatures, `todo`-free doc-frozen),
and the multi-table + passive-element **`rt_state` seam** (keystone/P5-09). It ships:

1. **The reftype/bulk/multi-table op bodies** in all three backend modules — `get`/`set`/`size`/
   `grow`/`fill`/`table_init`/`table_copy`/`elem_drop`, each in a **cell family** and a **threaded
   family** (`t_*`), total, zero `todo`.
2. **The generalised slot representation** — a table slot now holds a **reference value** (null
   sentinel | `funcref` | `externref`) rather than an always-present funcref entry, with `null`
   distinguishable from every real reference (§A).
3. **The differential** — one op-trace through every `(table_tier × state_strategy)` and the
   `TablePaged` oracle, asserting identical returned values/traps and identical `to_canon` slot
   image after each op (§H).
4. **Conformance readiness** — the engine under `table_get.wast`/`table_set.wast`/`table_size.wast`/
   `table_grow.wast`/`table_fill.wast`/`table_init.wast`/`table_copy.wast`/`elem.wast` (wired by
   P5-11), fail=0 under `map`/`ets`/`atomics` × `cell`/`threaded`.

---

## Depends on (freeze milestones)

- **`«IR3-FROZEN»` (P5-01)** — `RefType { FuncRef ExternRef }`, `TableDecl(name, ref_ty, min,
  max)`, the effectful table `Expr` nodes (`TableGet`/`TableSet`/`TableSize`/`TableGrow`/
  `TableFill`/`TableInit`/`TableCopy`/`ElemDrop`), the `ElementSegment(mode, ref_ty, init)` shape
  (active/passive/declarative), and the `TrapReason` set (reuse `TableOutOfBounds` /
  `UndefinedElement` / `UninitializedElement` / `IndirectCallTypeMismatch`, all already present;
  §A confirms no new reason is needed).
- **`«RT3-SIG-FROZEN»` (P5-01)** — the keystone doc-freezes the extended `rt_table` public heads
  (this unit's §B) so P5-06 emits against them while the bodies land here.
- **The `rt_state` multi-table + passive-element seam (keystone/P5-09)** — the **tables vector**
  accessors (`table_get_at(idx)` / `table_put_at(idx, _)` cell; `table_at(st, idx)` /
  `with_table_at(st, idx, _)` threaded) and the **passive-element drop state** accessors
  (`elem_seg(seg)` / `drop_elem_seg(seg)` cell; `elem_seg_of(st, seg)` /
  `with_elem_dropped(st, seg)` threaded). §C/§D specify the exact contract; the *names* are a
  keystone decision (Open questions #1).
- **`«MEM-TIER-FROZEN»` / `«STATE-STRATEGY-FROZEN»` (P4-01)** — the `table_tier` axis, the uniform
  interface, the threaded `InstanceState` box + closure ABI (all already frozen and green).
- **`ir.{FuncType, TrapReason}` + `rt_trap.spec_trap_message`** — `TableOutOfBounds → "out of
  bounds table access"`, `UndefinedElement → "undefined element"`, `UninitializedElement →
  "uninitialized element"`, `IndirectCallTypeMismatch → "indirect call type mismatch"` (frozen,
  verified in `rt_trap.gleam:79-81`).

---

## A. From the funcref MVP to typed reference tables (the representation)

A Phase-2 table slot was either **absent** (= null/uninitialised) or **present** holding
`#(FuncType, closure)`. Reference types make a slot hold a **reference value**, which for a
`funcref` table is `null | funcref` and for an `externref` table is `null | externref`:

| reference value | runtime term | produced by | consumed by |
|---|---|---|---|
| **null** (either reftype) | the frozen **null sentinel** | `ref.null t` (`RefNull`) | `ref.is_null`, `table.get`; a null funcref reaching `call_indirect` → `UninitializedElement` |
| **funcref** | `#(FuncType, closure)` — the Phase-2 type-tagged entry, promoted to a first-class value | `ref.func $f` (`RefFunc`), a funcref element segment | `call_indirect` (guard 3 reads `FuncType`, invokes `closure`) |
| **externref** | an **opaque BEAM term** (any host value) | the host / an imported/`spectest` global, `table.get` | stored verbatim; only ever `ref.is_null`-tested (never inspected) |

**The load-bearing representation decision.** A table slot generalises from
`Dict(Int, #(FuncType, closure))` (absent = null) to `Dict(Int, RefValue)` where a **missing key
still means null** (a fresh/grown/never-written slot) **and** a present key may hold the **null
sentinel** (a slot explicitly `table.set` to `ref.null`). Both cases are null; `table.get` returns
the null sentinel for either, and `call_indirect` traps `UninitializedElement` for either — the
guard-2 test becomes "the slot's reference value **is** the null sentinel" instead of "the key is
absent" (absent is coerced to the sentinel first). This preserves the Phase-2 dispatch exactly
while making null a first-class stored value.

```gleam
/// A WebAssembly reference value as rt_table stores it: the null sentinel, a funcref
/// (#(FuncType, closure)), or an opaque externref host term. Held OPAQUE as `Dynamic` — this
/// unit stores/returns reference values verbatim and only ever INTERPRETS the funcref shape
/// (for `call_indirect`). The keystone (P5-01) owns the reference VALUE-LAYER representation
/// (the exact sentinel + externref wrapping + the RefNull/RefFunc/RefIsNull lowering); this
/// unit consumes it. See Open questions #2 for the ownership seam.
pub type RefValue = Dynamic
```

- **The null sentinel** is a **single distinguished value** (per H1 "a single distinguished null
  sentinel"), the SAME term for `funcref` and `externref` (reference type is a static/validation
  property; a runtime null is untyped). It **must be distinguishable from every real reference** —
  critically from any `externref` host term. A bare atom (e.g. `null`) is unsafe (a host could
  hand back that atom); the recommendation is a **tagged tuple** the host cannot forge (e.g.
  `#(ref_null)`), with `externref` values wrapped (`#(ref_extern, term)`) so no host term collides
  with the sentinel or with the funcref `#(FuncType, closure)` shape. **This is a keystone
  decision** (Open questions #2); this unit only requires (i) a canonical sentinel it stores and
  compares by value and (ii) that a stored funcref reference exposes its `#(FuncType, closure)` for
  `call_indirect`. Whichever representation the keystone freezes, rt_table treats non-funcref
  reference values as **opaque** and never pattern-matches their internals.
- **`externref` opacity (H6).** rt_table never constructs, forges, inspects, or compares the
  *contents* of an `externref` — it moves the opaque term between slots and values. The only
  comparison rt_table ever makes on a stored value is (a) `== null_sentinel` (guard 2 / `table.get`
  null detection when needed) and (b) the funcref `FuncType == expected_type` (guard 3). Neither
  touches `externref` payload.

**Conformance-neutrality (H7).** The Phase-2/4 `new` / `init_elem` / `call_indirect` /
`t_init_elem` / `t_call_indirect` heads are **unchanged** — they operate on table index 0 through
the existing single-table seam and store funcref entries exactly as before. A funcref-only,
single-table, active-flag-0 module therefore emits byte-identical `.core` and its dispatch is
untouched. The new ops (`get`/`set`/`size`/`grow`/`fill`/`table_init`/`table_copy`/`elem_drop`)
only appear in Phase-5 modules, so they carry an explicit `table_idx` freely with **no**
byte-identity constraint (there is no Phase-4 baseline for them).

---

## B. The frozen uniform interface each tier module implements (`«RT3-SIG-FROZEN»`)

Every tier exposes the same public heads so the emit_core seam (P5-06) calls any of them
identically (the tier is the *module*, chosen by `table_tier`; the family — cell vs threaded — is
chosen by `state_strategy`). Existing heads unchanged; the following are **added**. All WASM
scalar operands (indices, counts, sizes) are raw `Int` (D5); reference values are opaque `Dynamic`
(§A).

```gleam
// ─── cell-backed family (state_strategy: Cell) ─── reaches table `idx` via rt_state.table_get_at

/// Read the reference value at `index` in table `idx`. Ok(ref) in range; Error(TableOutOfBounds)
/// if `index < 0 || index >= size` (spec: "out of bounds table access"). A never-written or
/// grown-into slot reads as the null sentinel.
pub fn get(idx: Int, index: Int) -> Result(RefValue, TrapReason)

/// Write reference value `value` into slot `index` of table `idx`. Ok(Nil) in range;
/// Error(TableOutOfBounds) out of range (eager; no write on trap).
pub fn set(idx: Int, index: Int, value: RefValue) -> Result(Nil, TrapReason)

/// The current slot count of table `idx` (`table.size`). Total.
pub fn size(idx: Int) -> Int

/// Grow table `idx` by `delta` slots, each initialised to `init`. Returns the OLD size on
/// success, or `-1` if `old + delta` exceeds the declared `max` / the safe cap, or `delta < 0`
/// wraps — in which case the table is UNCHANGED and no fuel is charged. On success charges
/// `delta` growth fuel (metered parity with memory.grow, §G).
pub fn grow(idx: Int, delta: Int, init: RefValue) -> Int

/// Fill `count` slots of table `idx` starting at `offset` with `value` (`table.fill`). Eager:
/// Error(TableOutOfBounds) if `offset + count > size` (or `offset < 0`) with NO partial writes.
pub fn fill(idx: Int, offset: Int, value: RefValue, count: Int) -> Result(Nil, TrapReason)

/// Copy `count` reference values from passive/active element segment `seg` (source offset `src`)
/// into table `idx` at `dst` (`table.init`). Eager bounds against BOTH the segment length and the
/// table size; Error(TableOutOfBounds) with NO partial writes on either overflow. A dropped
/// segment has length 0.
pub fn table_init(
  idx: Int, seg: Int, dst: Int, src: Int, count: Int,
) -> Result(Nil, TrapReason)

/// Copy `count` reference values from table `src_idx` (offset `src`) to table `dst_idx` (offset
/// `dst`) with memmove/overlap correctness (`table.copy`). Eager bounds against both; Error with
/// NO partial writes on overflow.
pub fn table_copy(
  dst_idx: Int, src_idx: Int, dst: Int, src: Int, count: Int,
) -> Result(Nil, TrapReason)

/// Mark passive element segment `seg` empty (`elem.drop`). Idempotent; total (dropping an
/// already-dropped / active / declarative segment is a no-op).
pub fn elem_drop(seg: Int) -> Nil

// ─── threaded family (state_strategy: Threaded) ─── the handle/state travels in `st`; a mutating
//     op RETURNS the (possibly rebound) record (the §10 uniform-threading rule).

pub fn t_get(st: InstanceState, idx: Int, index: Int) -> Result(RefValue, TrapReason)
pub fn t_set(st: InstanceState, idx: Int, index: Int, value: RefValue) -> Result(InstanceState, TrapReason)
pub fn t_size(st: InstanceState, idx: Int) -> Int
pub fn t_grow(st: InstanceState, idx: Int, delta: Int, init: RefValue) -> #(Int, InstanceState)
pub fn t_fill(st: InstanceState, idx: Int, offset: Int, value: RefValue, count: Int) -> Result(InstanceState, TrapReason)
pub fn t_table_init(st: InstanceState, idx: Int, seg: Int, dst: Int, src: Int, count: Int) -> Result(InstanceState, TrapReason)
pub fn t_table_copy(st: InstanceState, dst_idx: Int, src_idx: Int, dst: Int, src: Int, count: Int) -> Result(InstanceState, TrapReason)
pub fn t_elem_drop(st: InstanceState, seg: Int) -> InstanceState
```

**Threaded return discipline (the §10 rule, per template §C).** A mutating threaded op returns the
record: for an **immutable** substrate (`TablePaged`) it re-injects a **rebuilt** handle via
`rt_state.with_table_at`; for a **mutable-in-place** substrate (`TableEts`, and the `occ` array of
`TableAtomics`) it returns the **same** `st` (the handle/`tid`/`occ` ref is unchanged) — except
where a mutation also grows the immutable companion (`TableAtomics` `set`/`fill`/`grow`/`init`),
where it re-injects the handle with the grown companion. `t_get`/`t_size` are read-only and return
the value directly (no record). `t_grow` returns `#(old_size_or_-1, st')` (mirroring
`rt_mem.t_grow`'s `#(prev_pages, st')`, `rt_mem.gleam:257`). `t_elem_drop` returns `st'` with the
segment marked dropped.

---

## C. Multi-table state seam (the `rt_state` coordination — NOT owned here)

Phase-2/4 `rt_state.InstanceState` holds a **single** `table: Dynamic` (`rt_state.gleam:90-91`).
Multiple tables require a **vector of table handles** indexed by table index, exactly parallel to
the memories vector P5-08/keystone add for multi-memory. Because `rt_state.gleam` is **owned by the
keystone/P5-09** (D1 — this unit imports it, never edits it), this unit **specifies the seam it
needs** and flags the names for reconciliation (Open questions #1):

| concern | cell accessor (needed) | threaded accessor (needed) |
|---|---|---|
| read table `idx`'s handle | `table_get_at(idx: Int) -> Dynamic` | `table_at(st, idx: Int) -> Dynamic` |
| write table `idx`'s handle | `table_put_at(idx: Int, v: Dynamic) -> Nil` | `with_table_at(st, idx: Int, v) -> InstanceState` |

**Byte-identity for table 0 (H7).** The existing un-indexed `table_get()` / `table_put()` /
`table` / `with_table` heads (used by the unchanged `new`/`init_elem`/`call_indirect`) must remain
and **alias index 0** (`table_get() ≡ table_get_at(0)`), so the funcref-only single-table path is
untouched. The keystone chooses whether the vector is a `List(Dynamic)` (dense; index = position)
or a `Dict(Int, Dynamic)`; this unit only requires `get_at`/`put_at`-by-index with a stable
correspondence to the module's declared table order. All ops read/write table handles **solely**
through this seam (fail-closed on an un-seeded cell / an absent handle, exactly as Phase-2).

> **Why the seam and not a field grab.** Each backend keeps owning its own handle *shape*
> (`Dict`-based `Table`, ETS `tid`, `AtomicsTable`); `rt_state` stores each opaquely as `Dynamic`
> and knows nothing of it (the no-circular-import / opacity invariant, `rt_state.gleam:32-38`).
> The vector just widens the *count* of opaque handles. This unit's bodies coerce the `idx`-th
> `Dynamic` to their own handle type exactly as they coerce the single handle today.

---

## D. Passive element segments + `elem.drop` (droppable instance state)

Reference/bulk element segments come in three modes (`ElemMode`): `ElemActive(table, offset)`,
`ElemPassive`, `ElemDeclarative` (provisional surface §IR Module). Per the bulk-memory /
reference-types semantics (<https://webassembly.github.io/spec/core/exec/modules.html>,
instantiation):

- an **active** segment is written into its table at instantiation (via `init_elem` /
  `init_elem_ref`, §E) **and then dropped** (its runtime element vector becomes empty);
- a **declarative** segment is **immediately dropped** (it exists only to forward-declare
  `ref.func` targets; its runtime element vector is empty from the start);
- a **passive** segment is **retained** as a runtime **element instance** (a vector of reference
  values) that `table.init` can copy from and `elem.drop` empties.

So each element segment has **droppable instance state**: a runtime element vector that is either
its reference values (passive, until dropped) or **empty** (active/declarative after instantiation,
or any segment after `elem.drop`). This is **instance state** — it threads through the existing
state seam (H2: "no new seam"): `cell` holds it in the pdict record, `threaded` threads it in the
`InstanceState`. Again **owned by the keystone/P5-09** (it lives in `rt_state`); this unit
specifies the seam:

| concern | cell accessor (needed) | threaded accessor (needed) |
|---|---|---|
| read segment `seg`'s current element vector (empty if dropped/active/decl) | `elem_seg(seg: Int) -> List(RefValue)` | `elem_seg_of(st, seg: Int) -> List(RefValue)` |
| mark segment `seg` dropped (→ empty) | `drop_elem_seg(seg: Int) -> Nil` | `with_elem_dropped(st, seg: Int) -> InstanceState` |

**Seeding (emit_core/P5-06 + rt_state).** At instantiation the generated `instantiate` seeds each
declared segment's initial element vector: a **passive** segment's reference values, a
**declarative** segment as empty, an **active** segment's values (written into its table via
§E, then dropped). This unit's `table_init`/`elem_drop` **read/mutate** that seeded state through
the seam — it does **not** own the seeding. `elem_drop(seg)` is **idempotent** and total: dropping
an already-empty/active/declarative segment is a no-op (the vector is already empty).

**`table.init` from a dropped segment.** Because a dropped segment's element vector has length 0,
`table_init(idx, seg, dst, src, count)` with `count > 0` fails the eager segment-bounds check
(`src + count > 0` ⇒ trap `TableOutOfBounds`); with `count = 0` (and `src = 0`, `dst ≤ size`) it is
a spec no-op (`Ok`). This is exactly the spec's "init from a dropped/exhausted segment traps for
non-zero length, no-ops for zero length" (<https://github.com/WebAssembly/bulk-memory-operations>).

---

## E. Per-op semantics tables + worked examples (assert the spec, not the impl)

All references below are to the finalized reference-types + bulk-memory semantics in the
WebAssembly core spec: execution
<https://webassembly.github.io/spec/core/exec/instructions.html>, validation
<https://webassembly.github.io/spec/core/valid/instructions.html>, instantiation/segments
<https://webassembly.github.io/spec/core/exec/modules.html>. The `0xFC`-prefixed binary opcodes
(`table.init` `0xFC 12`, `elem.drop` `0xFC 13`, `table.copy` `0xFC 14`, `table.grow` `0xFC 15`,
`table.size` `0xFC 16`, `table.fill` `0xFC 17`) and `table.get`/`table.set` (`0x25`/`0x26`) are
**decoded by P5-03** — this unit receives lowered IR nodes and never sees a byte; the exact bytes
are cited only for orientation and their authority is P5-03 (flag to P5-03 if any differs).

### E.1 `get` / `set` — single-slot, hard bounds trap

| op | in-range result | out-of-range (`i < 0 ∨ i ≥ size`) |
|---|---|---|
| `table.get x` (`get(x, i)`) | `Ok(slot[i])` — the stored reference value; a never-written / grown-into slot yields the **null sentinel** (not a trap) | `Error(TableOutOfBounds)` — "out of bounds table access" |
| `table.set x` (`set(x, i, v)`) | `Ok(Nil)` — `slot[i] := v` (v may be `ref.null` → stores the sentinel) | `Error(TableOutOfBounds)`, **no write** |

Spec: `table.get`/`table.set` trap iff the index is `≥` the table length
(exec/instructions.html — Table Instructions). Validation (P5-04) guarantees `v`'s reftype matches
the table's; rt_table stores whatever reference value it is handed.

### E.2 `size` / `grow`

| op | semantics |
|---|---|
| `table.size x` (`size(x)`) | returns the current slot count. Total, no trap. |
| `table.grow x` (`grow(x, delta, init)`) | append `delta` slots each initialised to `init`; return the **old size** on success. Return **`-1`** (unchanged, nothing charged) if `old + delta` would exceed the declared `max` (or the safe cap, or overflow the `2³²` element limit). §G covers fuel. |

Spec: `table.grow` returns the previous size, or `0xFFFFFFFF` (i.e. `-1` as `i32`) on failure, and
must respect the table's maximum (exec/instructions.html; reference-types proposal). The
`-1`-on-failure / old-size-on-success contract mirrors `rt_mem.grow` (`rt_mem.gleam:155-168`).
Worked: table `min=1, max=Some(3)`, one null slot. `grow(0, 2, r)` → `Ok`-returns `1`, size now 3,
slots 1–2 hold `r`. A further `grow(0, 1, r)` → returns `-1` (would exceed `max=3`), size stays 3.

### E.3 `fill` — eager range, no partial writes

`table.fill x` (`fill(x, d, v, n)`): write `v` into slots `d, d+1, …, d+n-1`.

| condition | result |
|---|---|
| `d + n ≤ size` (and `d, n ≥ 0`) | `Ok(Nil)` — `n` slots set to `v` |
| `d + n > size` | `Error(TableOutOfBounds)`, **NO slot written** (all-or-nothing) |

Spec: `table.fill` traps if `d + n` exceeds the table length, **before** any store
(exec/instructions.html; the finalized bulk semantics are eager — trap-before-write, no partial
effect). Worked: `size=5`; `fill(0, 3, r, 5)` traps (`3+5=8 > 5`) and slots 3,4 stay null (proving
no partial write); `fill(0, 3, r, 2)` fills exactly slots 3,4.

### E.4 `table.init` — from a segment, eager bounds against BOTH lengths

`table.init x y` (`table_init(x, y, d, s, n)`, `x`=table, `y`=elem segment): copy `n` reference
values from segment `y`'s element vector (starting at `s`) into table `x` (starting at `d`).

| condition | result |
|---|---|
| `s + n ≤ len(seg)` **and** `d + n ≤ size` | `Ok(Nil)` — `n` values copied |
| `s + n > len(seg)` **or** `d + n > size` | `Error(TableOutOfBounds)`, **NO write** |

Spec: `table.init` traps if either the source range exceeds the segment's element count **or** the
destination range exceeds the table length, before any write (bulk-memory proposal; exec/
instructions.html). A **dropped** (or active/declarative) segment has `len(seg) = 0`, so any
`n > 0` traps and `n = 0` no-ops (§D). Worked: passive segment `[a,b,c]`, table `size=5` all null;
`table_init(0, 0, 1, 0, 3)` fills slots 1,2,3 with a,b,c. Then `elem_drop(0)`; a later
`table_init(0, 0, 0, 0, 1)` traps (`len(seg)` now 0, `0+1 > 0`).

### E.5 `table.copy` — memmove overlap correctness, eager bounds

`table.copy x y` (`table_copy(x, y, d, s, n)`, `x`=dst table, `y`=src table): copy `n` reference
values from table `y` (offset `s`) to table `x` (offset `d`).

| condition | result |
|---|---|
| `s + n ≤ size(y)` **and** `d + n ≤ size(x)` | `Ok(Nil)` — `n` values copied, **overlap-correct** |
| `s + n > size(y)` **or** `d + n > size(x)` | `Error(TableOutOfBounds)`, **NO write** |

Spec (exec/instructions.html — `table.copy`): trap if either range is out of bounds, before any
write; then copy with **memmove** semantics so an overlapping same-table copy is correct. The spec
order rule: **if `d ≤ s` copy indices in ascending order; otherwise copy in descending order** —
equivalently, snapshot the whole source slice `[s, s+n)` **before** writing the destination. For
the immutable `TablePaged` this falls out for free (read the source slots into a list, then fold
them into the destination `Dict`); the mutable `TableEts`/`TableAtomics` backends **must** either
snapshot-then-write or honour the ascending/descending direction rule (§H). Worked overlap:
single table `[0:a,1:b,2:c,3:d,4:_]`; `table_copy(0,0, 2, 1, 3)` (dst=2,src=1,n=3, `d>s` →
descending / snapshot) yields `[0:a,1:b,2:b,3:c,4:d]` — **not** `[…,2:b,3:b,4:b]` (the naive
ascending in-place bug). And `table_copy(0,0, 1, 2, 3)` (dst=1,src=2,n=3, `d≤s` → ascending) is
also correct via snapshot. Cross-table copies never overlap and take either path.

### E.6 `elem.drop`

`elem.drop y` (`elem_drop(y)`): set segment `y`'s element vector to empty. Idempotent, total (§D).
Spec: `elem.drop` marks the segment "dropped"; a subsequent `table.init` from it behaves as a
zero-length segment (exec/modules.html; bulk-memory proposal).

### E.7 Active reftype/expr segment writes (`init_elem` / `init_elem_ref`)

The Phase-2 `init_elem(offset, entries: List(#(FuncType, closure)))` stays **unchanged** for the
**funcref-funcidx active** fast path (byte-identity, §A). Active segments that are **expression**
form, **externref**, contain **`ref.null`**, or target a **non-zero table** lower (P5-06) to a
generalised writer:

```gleam
/// Write an active element segment's reference VALUES into table `idx` at `offset` (all-or-
/// nothing: Error(TableOutOfBounds) if `offset + len > size`, no partial write). Generalises
/// `init_elem` to arbitrary reference values (funcref | externref | null) and any table index.
pub fn init_elem_ref(idx: Int, offset: Int, refs: List(RefValue)) -> Result(Nil, TrapReason)
pub fn t_init_elem_ref(st: InstanceState, idx: Int, offset: Int, refs: List(RefValue)) -> Result(InstanceState, TrapReason)
```

An active segment whose range exceeds the table traps at instantiation (`TableOutOfBounds`), per
the modern semantics (active init = `table.init` + `elem.drop`, both eager). Whether P5-06 routes
the funcref fast path through `init_elem` or unifies on `init_elem_ref` is P5-06's byte-identity
call; this unit provides both so either choice is available (Open questions #3).

---

## F. TrapReason mapping (no new reason)

| op | trap | `TrapReason` | `spec_trap_message` |
|---|---|---|---|
| `table.get`/`set` OOB | out-of-bounds index | `TableOutOfBounds` | `"out of bounds table access"` |
| `table.fill`/`init`/`copy` OOB | range exceeds table/segment | `TableOutOfBounds` | `"out of bounds table access"` |
| active elem segment OOB (instantiation) | range exceeds table | `TableOutOfBounds` | `"out of bounds table access"` |
| `call_indirect` index OOB | index ≥ size | `UndefinedElement` | `"undefined element"` |
| `call_indirect` null slot | null reference | `UninitializedElement` | `"uninitialized element"` |
| `call_indirect` type mismatch | funcref type ≠ expected | `IndirectCallTypeMismatch` | `"indirect call type mismatch"` |

All six already exist (`ir.gleam:601-611`, `rt_trap.gleam:73-81`) — **no new `TrapReason`** (H6 /
provisional surface confirm: reuse). `table.grow` does **not** trap (returns `-1`). Note the
deliberate split: `call_indirect`'s index OOB is `UndefinedElement` ("undefined element"), whereas
the reference-types `table.get`/`set`/`fill`/`init`/`copy` index/range OOB is `TableOutOfBounds`
("out of bounds table access") — these are **different spec messages** for different ops
(exec/instructions.html), and the suite's `assert_trap` strings distinguish them, so rt_table must
not conflate them.

---

## G. `table.grow` fuel — metered parity with the meter

`memory.grow` charges `delta * page_bytes` fuel on the **success path only** so a metered module
cannot allocate to the page cap with zero CPU accounting, and so **metered+threaded is
byte-identical to metered+cell** (`rt_mem.gleam:163-168` cell, `:257-266` threaded — the G7 trap
bar). `table.grow` gets the analogous charge:

- **cell `grow`** charges `rt_meter.charge(delta)` (one fuel unit per appended slot) on the
  **success** path, **after** the max/cap check passes and **before** returning the old size; the
  `-1` path charges **nothing** (nothing allocated) — mirroring `rt_mem.grow`.
- **threaded `t_grow`** charges the **same** `delta` on its success path, so metered+threaded ≡
  metered+cell for `table.grow` (parity, the G7 bar).
- the charge is **proportional to slots allocated** (a big grow is not O(1)-cheap, E3), consistent
  with the memory-grow rationale.

> **Coordinate with the meter (Open questions #4).** `rt_meter.charge/1` (`rt_meter.gleam:155`)
> takes an abstract cost; `rt_mem` uses *bytes*. A table slot is one reference word, so `delta`
> (slots) is the natural unit, but the exact multiplier (1 vs a slot-cost constant) must be **the
> same in cell and threaded** and agreed with the meter owner so the fuel budget stays coherent
> across the mem/table ops. Whichever constant is chosen, it is applied identically in both
> families and only on success.

---

## H. Tier × state-strategy composition (map/ets/atomics × cell/threaded)

The two axes stay orthogonal (template §C): `state_strategy` chooses where the handle lives and how
it is reached; `table_tier` chooses the handle substrate. Every new op is implemented **once per
tier**, in a cell and a threaded family, over that tier's substrate — with **identical
observable behaviour** (the differential, below). How each substrate realises the new *mutation*:

| op | `TablePaged` (immutable `Dict`) | `TableEts` (in-place ETS) | `TableAtomics` (`occ` + companion) |
|---|---|---|---|
| `get` | `dict.get` → sentinel if absent | `ets:lookup` → sentinel if `[]` | `atomics:get`; `0` → sentinel, else companion value |
| `set` | rebuild `Dict` (cell: `table_put_at`; threaded: `with_table_at`) | `ets:insert` in place (threaded: same `st`) | assign dense key, `atomics:put` in place, grow companion (threaded: handle w/ grown companion) |
| `size` | field read | field read | field read |
| `grow` | new `Table{size+delta, slots+inits}` | new `EtsTable{size+delta}`, `ets:insert` inits | **§G-sharp-edge**: extend logical `size`, `atomics:put` inits within pre-allocated capacity, grow companion; if capacity exhausted & no `max`, pre-allocate to cap or return `-1` (never silent) |
| `fill` | fold inits into `Dict` | `ets:insert` loop | `atomics:put` loop + companion inserts |
| `table_init` | read seg refs, fold into `Dict` | `ets:insert` loop | `atomics:put` + companion loop |
| `table_copy` | snapshot src slice (list), fold into dst `Dict` | **snapshot src slice first**, then `ets:insert` (memmove) | **snapshot src dense keys/values first**, then `atomics:put` (memmove) |
| `elem_drop` | via `rt_state` elem-seg seam (tier-agnostic) | same | same |

**The `TableAtomics` `set`/`fill`/`grow`/`init` sharp edge (template §E).** The `occ` array is
mutated in place (O(1) `atomics:put`), but the companion `Dict(dense_key → RefValue)` is immutable,
so any op that adds/overwrites a slot **rebuilds the companion** (structural sharing keeps it
cheap) and, threaded, re-injects the handle with the grown companion (`occ` ref stable). Overwrite
(`set` on a filled slot) assigns a **new** dense key and leaves the old companion entry orphaned
(monotonic `next`, template's design) — correct, but the companion grows with writes; acceptable
for the MVP surface (Open questions #5 notes the compaction non-goal). **`grow`** inherits
`rt_mem_atomics`'s pre-allocation edge: the array is fixed-size at creation, so `new` pre-allocates
to the effective `max` (or, absent a `max`, a safe cap), and `grow` extends the logical size within
that capacity — a grow beyond capacity **fails closed** (`-1`), never a silent under-allocation.

**The differential (§F of the template, the G7 bar).** `TablePaged` is the oracle. The differential
test (`rt_table_reftype_differential_test.gleam`) drives **one op-trace** — `new`; a mix of
in-range/OOB `set`/`fill`/`table_init`/`table_copy`/`grow`; interleaved `get`/`size`; `elem_drop`
then `table_init` from the dropped segment — through **each shipped `(table_tier ×
state_strategy)`** and the `TablePaged` oracle, asserting after every op: identical `Ok`/`Error
(reason)`, identical returned values (`get`'s reference value compared via `ref.is_null` +, for
funcref, `FuncType` tag — closures are not comparable, §to_canon), identical `size`, and identical
`to_canon` slot image. `to_canon` extends to reference values: `None` = null slot, `Some(RefTag)`
where `RefTag` distinguishes null/funcref-`FuncType`/externref-present (externref payload is opaque,
so the tag records *presence*, not identity). Identical behaviour across all tiers is this unit's
headline invariant.

---

## Effect / soundness / security note

- **`externref` opacity (H6).** rt_table stores `externref` values **verbatim** and never
  constructs, forges, inspects, compares, or reveals their host payload — it moves the opaque term
  between slots and values, and the only value-comparisons it ever makes are `== null_sentinel`
  (null detection) and funcref `FuncType == expected_type` (guard 3), neither of which touches
  `externref` contents. Safe code can hold/pass/store/null-test an `externref` but cannot read
  through it; the capability model is unchanged.
- **Fail-closed bounds (H6).** Every new op is bounds-checked → trap: `get`/`set` (hard
  `TableOutOfBounds`), `fill`/`init`/`copy` (**eager**, whole-range check before any write, so a
  failed op leaves the table exactly as it was — no partial effect), `grow` (returns `-1` past
  `max`/cap, never over-allocates). The worst case of a bounds bug is a wrong/missing trap or a
  node-safe process crash — **never a host escape**. `table.init` also bounds-checks the **segment**
  length (a dropped segment is length 0).
- **No ambient authority (D3a), preserved.** The `call_indirect` dispatch is **unchanged** —
  build-controlled closures, invoked directly, never `apply/3` on data-derived names. The new ops
  move reference *values* (funcref = a build-controlled `#(FuncType, closure)`, externref = an
  opaque term) between slots without ever turning runtime data into a module/function atom. A
  funcref that later reaches `call_indirect` is still the build-controlled closure the element
  segment / `ref.func` produced. The generated-code security invariant (P5-06 extends the D3a test)
  is unchanged: the seam emits `call '<table_module>':'get'/'set'/…'(…)` regardless of tier.
- **Fail-closed state (E3).** Cell ops read handles/segments via the `rt_state` seam, which raises
  node-safe on an un-seeded cell (never fabricates an empty "succeeding" table); threaded ops
  require the handle/segment present in `st`. An absent handle is an internal-invariant violation,
  not a WASM trap.
- **Process-local; tier-O never NIF (G6).** `private` ETS + a non-shared `atomics` ref, confined to
  the instance process (E1) — never cross-process, never shared memory. There is no `nif` table
  tier, so `table_tier` cannot violate Safe-forbids-nif; Safe permits all three.
- **Raw bits (D5) / conformance-neutral (H7).** Scalar operands are raw-bit `Int`; a funcref-only
  single-table module's dispatch and emitted `.core` are byte-identical to Phase-4 (the new ops
  never appear in it).

---

## Verification — Definition of Done (D8: assert the spec, not the impl)

Write the spec-cited suites (cite exec/instructions.html, valid/instructions.html,
exec/modules.html, the reference-types + bulk-memory proposals), **not** whatever the code emits.
For each backend module (`rt_table`, `rt_table_ets`, `rt_table_atomics`), and mirroring the Phase-2/4
suites:

1. **`get`/`set` round-trip + bounds.** `set(0, 2, r)` then `get(0, 2)` → `Ok(r)`; `get`/`set` at
   `index = size` and `index = -1` → `Error(TableOutOfBounds)` with the frozen message; a
   never-written / grown-into slot `get`s the null sentinel (not a trap). Storing `ref.null` then
   `get` returns null; `call_indirect` to that slot traps `UninitializedElement`.
2. **`size`/`grow`.** `size` tracks writes/grows; `grow(0, delta, r)` returns the old size and
   appends `delta` slots holding `r`; a grow past declared `max` (and past the safe cap) returns
   `-1` and leaves size/contents unchanged; `grow(0, 0, r)` returns the current size, no-op.
3. **`grow` fuel parity (§G).** With a seeded fuel budget, a successful `grow(0, delta, r)` charges
   the same cost in the cell and threaded families (assert `rt_meter.fuel_consumed` delta equal
   across families); the `-1` path charges nothing; a grow whose cost exceeds the remaining budget
   surfaces `FuelExhausted` identically to `memory.grow`.
4. **`fill` eager, no partial writes.** `fill(0, d, r, n)` with `d + n > size` (and the exact
   off-by-one `d + n = size + 1`) → `Error(TableOutOfBounds)` **and** every slot the failed fill
   would have touched still reads its prior value (prove no partial write); an in-range fill sets
   exactly its run.
5. **`table.init` (both bounds + dropped segment).** From a passive segment `[a,b,c]`:
   `table_init(0, y, d, s, n)` copies exactly `[s, s+n)`; `s + n > len(seg)` **or** `d + n > size`
   → `Error(TableOutOfBounds)`, no write; after `elem_drop(y)`, `table_init` with `n > 0` traps and
   `n = 0` no-ops (dropped = length 0).
6. **`table.copy` memmove (the overlap corner).** The two worked overlapping same-table copies of
   §E.5 (`d > s` descending and `d ≤ s` ascending) produce the **snapshot-correct** result, not the
   naive in-place smear; a cross-table copy moves values between two distinct tables; OOB on either
   the source or the destination range → `Error(TableOutOfBounds)`, no write.
7. **`elem.drop` idempotent + declarative/active semantics.** `elem_drop` twice is a no-op the
   second time; a declarative segment reads as length-0 from the start; an active segment reads as
   length-0 after instantiation (a `table.init` from it with `n > 0` traps).
8. **Multiple tables.** Two declared tables of different `min`/reftype: an op on table 1 never
   touches table 0; a `table.copy` between them moves values; each table's `size`/`get` are
   independent. (Prove the vector seam routes by index.)
9. **`externref` opacity.** An `externref` table round-trips an opaque host term through
   `set`/`get`/`fill`/`grow`/`copy`/`init` **bit-identically** and rt_table never inspects it;
   `ref.is_null` on a stored non-null externref is false, on the sentinel is true. (rt_table stores
   the term the test hands it and returns the same term.)
10. **Both families (Cell **and** Threaded).** Every case above runs through the cell heads (seed a
    pdict cell) **and** the threaded heads (over an `InstanceState`), asserting the threaded ops
    return the record per the §10 rule (mutable-in-place → same handle; immutable/companion-growing
    → rebuilt handle) and that `t_grow` returns `#(old_or_-1, st')`.
11. **Tier differential (§H).** The one op-trace through every `(table_tier × state_strategy)` and
    the `TablePaged` oracle → identical values/traps/`size`/`to_canon` after each op.
12. **Trap messages frozen.** `spec_trap_message(TableOutOfBounds) == "out of bounds table
    access"`; the `call_indirect` trio unchanged (`"undefined element"` / `"uninitialized element"`
    / `"indirect call type mismatch"`). Guards against drift.
13. **D3a (per module).** Grep-backed + review assertion that no backend `apply/3`s a data-derived
    name, builds a module/function atom from inputs, or stores anything but build-supplied
    closures / opaque reference values / integers.
14. **Conformance (wired by P5-11, proven here).** rt_table is the engine under
    `table_get.wast` / `table_set.wast` / `table_size.wast` / `table_grow.wast` / `table_fill.wast`
    / `table_init.wast` / `table_copy.wast` / `elem.wast` (and the reftype/multi-table parts of
    `call_indirect.wast` and `select.wast`) — **fail=0** under `TablePaged`/`TableEts`/`TableAtomics`
    × `cell`/`threaded`. `call_indirect.wast`'s previously-skipped multi-table module now runs.

**Gate:** `gleam format --check src test` clean; `gleam build` **zero warnings** (no lingering
`todo`); `gleam test` stays green (906 + your new tests); every new public function/type carries a
`///` contract doc (D8). **Done = the suites + the differential + the cited `.wast` files pass**,
never "it compiles."

---

## What this unit leaves

- **P5-06 (emit_core):** lowers `TableGet/Set/Size/Grow/Fill/Init/Copy`/`ElemDrop` to
  `call '<table_module>':'get'/'set'/'size'/'grow'/'fill'/'table_init'/'table_copy'/'elem_drop'(…)`
  (cell) or the `t_*` heads (threaded), `case`ing `{ok,V}`/`{error,R}` (raise on error) and
  threading `St` per the §10 rule; keeps the funcref-active/single-table path emitting the
  unchanged `init_elem`/`call_indirect` (byte-identity, H7); constructs each reference value
  (`RefNull` → the null sentinel, `RefFunc` → `#(FuncType, closure)`, externref from the host);
  seeds each element segment's runtime vector (passive kept, active written+dropped, declarative
  empty) into `rt_state` at instantiation; extends the D3a security test.
- **Keystone/P5-09 (`rt_state`):** owns the **tables vector** (`table_get_at`/`table_put_at`/
  `table_at`/`with_table_at`, with `table_get() ≡ table_get_at(0)` for byte-identity) and the
  **passive-element drop state** (`elem_seg`/`drop_elem_seg` + threaded twins). This unit consumes
  both; the names are reconciled with the keystone (Open questions #1).
- **P5-08 (rt_mem):** the sibling multi-region + passive-**data** segment machinery (memory.init/
  copy/fill, data.drop) — the same seam pattern for memories; coordinate the memories-vector /
  passive-segment seam shape so tables and memories thread state identically.
- **P5-11 (conformance):** adds the `table_*.wast` / `elem.wast` / reftype files to the allowlist,
  reports the skip-count drop, and proves fail=0 under every `(mode × state_strategy × mem_tier ×
  table_tier)` binding.

---

## Open questions (for the planner / cross-unit sync)

1. **The `rt_state` multi-table + passive-element seam names/shape.** This unit needs
   `table_get_at(idx)`/`table_put_at(idx,_)` (cell) + `table_at(st,idx)`/`with_table_at(st,idx,_)`
   (threaded), and `elem_seg(seg)`/`drop_elem_seg(seg)` (+ threaded twins), with `table_get() ≡
   table_get_at(0)` preserved for byte-identity. `rt_state.gleam` is keystone/P5-09-owned — please
   **freeze these exact names and the vector representation** (`List` vs `Dict`) in `«RT3-SIG-
   FROZEN»`. Recommendation: a dense `List(Dynamic)` indexed by declared table order for tables
   (mirrors the memories vector) and a `Dict(Int, List(RefValue))`-plus-dropped-set for element
   segments (sparse; segments are referenced by index and most are dropped early).
2. **The reference-value representation ownership + the null sentinel.** rt_table needs (i) a
   canonical **null sentinel** it stores and compares by value, and (ii) the funcref
   `#(FuncType, closure)` projection for `call_indirect`. The keystone (P5-01, H1) owns the value
   layer. Recommendation: keystone freezes a forge-proof tagged sentinel (`#(ref_null)`), wraps
   `externref` (`#(ref_extern, term)`) so no host term collides, and **keeps funcref as the
   existing `#(FuncType, closure)`** so `call_indirect`/`init_elem` are unchanged (byte-identity).
   Confirm whether the sentinel + predicates live in a shared `runtime/rt_ref` (importable by
   rt_table + emit_core) or on the keystone module. If funcref wrapping changes, `call_indirect`'s
   guard-2/3 in **three** backends must be revisited — flag before freezing.
3. **`init_elem` vs `init_elem_ref` for active segments.** Does P5-06 keep the Phase-2
   `init_elem(offset, entries)` fast path for funcref-funcidx active segments (preserving
   byte-identity) and use `init_elem_ref(idx, offset, refs)` only for expr/externref/`ref.null`/
   multi-table segments (this unit's recommendation, §E.7), or unify everything on `init_elem_ref`?
   The latter is cleaner but changes the emitted call for every funcref module and breaks H7
   byte-identity — so this unit provides **both** and recommends the fast-path split. Planner to
   confirm the emit_core contract.
4. **`table.grow` fuel unit (meter coordination).** `rt_mem` charges `delta * page_bytes`; a table
   slot is one word, so `delta` (slots) is proposed. Confirm the exact multiplier with the
   `rt_meter` owner so the fuel budget stays coherent across mem/table grows, and that it is applied
   identically in cell and threaded (the G7 parity bar) and only on success.
5. **`TableAtomics` companion compaction (non-goal).** `set`/`fill` on already-filled slots assign
   fresh dense keys and orphan old companion entries (monotonic `next`), so the companion grows with
   overwrite-heavy workloads. Correct but unbounded-ish; a compaction pass is a deliberate non-goal
   for the MVP surface (matches the template's forward-compat framing). Confirm this is acceptable,
   or whether `set` should reuse the slot's existing dense key when present (an optimisation that
   complicates the immutable-companion invariant).
6. **`table.copy` cross-tier direction rule vs snapshot.** This unit specifies memmove via
   **snapshot-then-write** for the mutable backends (simplest provably-correct), rather than the
   spec's ascending/descending direction rule. Behaviourally identical (both are memmove); flagging
   only so the differential's expectation (§H) is understood — the observable result is the memmove
   image regardless of technique.
