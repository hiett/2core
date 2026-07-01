# Unit 06 — rt_table trust-tiers (`ets` / `atomics`, tier-O; G2)

> **One owner · Wave A (parallel with 02/03/04/05) · gated on `«MEM-TIER-FROZEN»`
> + `«STATE-STRATEGY-FROZEN»` (keystone unit 01).** Read
> [`00-overview.md`](00-overview.md) (G1–G8) and
> [`01-interface-freeze.md`](01-interface-freeze.md) §A.2 / §B first, then the
> Phase-2 analog [`../phase-2/05-rt-table.md`](../phase-2/05-rt-table.md). You build the
> **tier-O funcref-table backends** — `TableEts` and `TableAtomics` — behind the frozen
> uniform `rt_table` interface. Your one job: keep the **3-fault fail-closed
> `call_indirect` dispatch byte-identical across every tier** (bounds → null → exact
> `FuncType`), with **no ambient authority** (D3a) and **process-local** state (the
> threads non-goal), so a tier is a pure module swap the linker (07) resolves.

The Phase-2 `rt_table` (`TablePaged`, tier-P) is the immutable sparse-`Dict` funcref table
+ the proven 3-fault dispatch (unit P2-05, green under `call_indirect.wast`). Phase 4 adds
two **tier-O** siblings selected by the frozen `Binding.table_tier` axis (`TableEts` /
`TableAtomics`, `«MEM-TIER-FROZEN»`). There is **no `nif` table tier** (§A) — every table
tier is node-safe, so `table_tier` can never violate Safe-forbids-nif (keystone §B.1); the
whole Safe/Unsafe policy constraint (G6) lives on `mem_tier`, never here.

---

## Deliverables & freeze milestones

**Produces no freeze milestone** — this unit *consumes* `«MEM-TIER-FROZEN»` (the
`table_tier` axis + the uniform `rt_table` interface, keystone §B.2) and
`«STATE-STRATEGY-FROZEN»` (the threaded closure type + the `t_init_elem`/`t_call_indirect`
heads, keystone §A.2). It ships two backend modules, each a total implementation of the
frozen interface (real, zero `todo`), the owner-additive **paged threaded wrappers**
(`t_init_elem`/`t_call_indirect`) in the existing `rt_table.gleam`, plus the tier differential:

1. **`rt_table_ets.gleam`** (tier-O, `TableEts`) — a **private, process-local** ETS table
   mapping slot-index → `#(FuncType, closure)`. Closures live natively in ETS; O(1)
   mutable-in-place; the natural closure-native tier-O backend (§D).
2. **`rt_table_atomics.gleam`** (tier-O, `TableAtomics`) — an `atomics` array of per-slot
   dense entry keys (0 = null) beside an immutable `#(FuncType, closure)` companion (BEAM
   `atomics` cannot hold funs, so the funs stay in the companion — the honest sharp edge,
   §E). O(1) integer-slot read; forward-compatible with Phase-5 `table.set`/`table.grow`.
3. Each module implements **both op families** — the **cell-backed** family
   (`state_strategy: Cell`) and the **threaded** family (`state_strategy: Threaded`) — so
   every tier composes with either state strategy (§C), plus a differential **canon hook**.
4. **`rt_table_ets_test.gleam` / `rt_table_atomics_test.gleam`** + a shared **tier
   differential** driving one op-trace through every `(table_tier × state_strategy)` and the
   `TablePaged` oracle, asserting identical values/traps/type-tag image (§F).

> **Freeze-honoured file decision (keystone §B.1 supersedes overview §4).** The overview §4
> map's shorthand "`rt_table.gleam (extend)`" is superseded by the keystone for the tier
> **backends**: each tier-O backend is its **own file** (a link-time module swap needs distinct
> atoms, and D1 gives each file one owner). This unit therefore **READs** `rt_table.gleam` (the
> frozen paged reference + the 3-guard algorithm to replicate exactly), **OWNs** the two new
> sibling backend modules, **and** — owner-additive, per the reconciled ownership decision — owns
> the **paged threaded wrappers** (`t_init_elem`/`t_call_indirect`) it adds to `rt_table.gleam`
> itself. So one owner per set of functions: P2-05 owns the frozen paged cell surface, **this
> unit** owns the paged threaded wrappers there (not unit 03 — unit 03 owns only `rt_state.gleam`
> and imports neither `rt_mem` nor `rt_table`).

---

## Files owned / depends on

| File | Status |
|---|---|
| `src/twocore/runtime/rt_table.gleam` | **EXTEND (owner-additive)** — the paged threaded wrappers `t_init_elem`/`t_call_indirect` over the frozen immutable `Dict` core (P2-05's cell surface untouched). |
| `src/twocore/runtime/rt_table_ets.gleam` | **NEW** — the `TableEts` backend. |
| `src/twocore/runtime/rt_table_atomics.gleam` | **NEW** — the `TableAtomics` backend. |
| `src/twocore_rt_table_ets_ffi.erl` *(if needed)* | **NEW** — thin `ets:new/2`/`ets:lookup`/`ets:insert` + `atomics:*` shims (namespaced, like `twocore_rt_state_ffi`). |
| `test/twocore/runtime/rt_table_ets_test.gleam`, `…_atomics_test.gleam`, `…tier_differential_test.gleam` | **NEW** — spec-cited suites. |

**Depends on:** `«MEM-TIER-FROZEN»` (the `TableTier` enum + `table_tier` field + the tier→module
map + the uniform interface, §B.1/§B.2); `«STATE-STRATEGY-FROZEN»` (the `InstanceState` box +
the threaded closure type `#(FuncType, fn(InstanceState, List(Int)) -> #(List(Int),
InstanceState))` + the `t_init_elem`/`t_call_indirect` heads, §A.2); `ir.{FuncType,
TrapReason}` (`UndefinedElement`/`UninitializedElement`/`IndirectCallTypeMismatch`/
`TableOutOfBounds` + their `rt_trap.spec_trap_message` strings, all frozen). You do **not** edit
`instance.gleam`, `rt_state.gleam`, `emit_core.gleam`, `profiles.gleam`, or the conformance
allowlist.

---

## A. The tier ladder for funcref tables (`TablePaged` → `TableEts` / `TableAtomics`)

Per G2 the table backend is selected by `Binding.table_tier`, all behind one uniform interface
(§B.2). The keystone froze three variants (`«MEM-TIER-FROZEN»`, no `nif` variant):

| `table_tier` | `table_module` (linker maps, unit 07) | Tier | Owner | Substrate |
|---|---|---|---|---|
| `TablePaged` | `"twocore@runtime@rt_table"` | P | P2-05 (+06 threaded) | immutable sparse `Dict` |
| `TableEts` | `"twocore@runtime@rt_table_ets"` | O | **this unit** | private ETS table |
| `TableAtomics` | `"twocore@runtime@rt_table_atomics"` | O | **this unit** | `atomics` + immutable companion |

**Honest scope (G8 — do not overstate the tier-O table win).** Unlike `rt_mem` (every store
rebuilds a page, so tier-O `atomics` is the shipped O(1) *store* lever), a Phase-4 funcref table
is **immutable after instantiation**: only `init_elem` ever writes it —
`table.set`/`table.grow`/`table.fill`/`table.copy` are reference-types ops **deferred to Phase 5**
(overview §6). So `TablePaged` already dispatches in O(1) (`dict.get`, no rebuild), and the tier-O
backends buy little raw call-time speed today. Their real value is (i) **uniformity** (a profile
picks one substrate for *all* mutable state) and (ii) **Phase-5 readiness** (an `ets`/`atomics`
table makes runtime `table.set`/`table.grow` O(1) when reftypes land). Unit 10's benchmark
reports the table tiers as *equivalent-or-marginal* on the MVP corpus, not a headline speedup.

**Every table tier is node-safe and process-local.** There is no `nif` table tier, so
`table_tier` cannot violate Safe-forbids-nif (G6, keystone §B.1) — Safe permits all three. A
bounds/null/type bug's worst case in any tier is a wrong/missing trap or a node-safe process
crash, never a host escape.

---

## B. The frozen uniform interface each tier module implements (keystone §B.2 / §A.2)

Every `rt_table` tier exposes the **same public heads** so the seam calls any of them
identically (the tier is the *module*, chosen by the linker; the family — cell vs threaded — is
chosen by `state_strategy` in `emit_core`, unit 02). The handle is **opaque `Dynamic`**: it is
carried in the `table` slot of `rt_state.InstanceState` — in the pdict cell under `Cell`, threaded
as a value under `Threaded` (§C). All WASM values are raw-bit `Int`s (D5), so a closure's ABI is
`fn(List(Int)) -> List(Int)` (cell) or `fn(InstanceState, List(Int)) -> #(List(Int),
InstanceState)` (threaded).

```gleam
//// construction (both strategies) — build a fresh, all-null table handle.
pub fn new(min: Int, max: Option(Int)) -> Dynamic

//// cell-backed family (state_strategy: Cell) — reach the handle via the pdict cell
//// (rt_state.table_get / table_put), exactly the Phase-2 rt_table heads.
pub fn init_elem(
  offset: Int,
  entries: List(#(FuncType, fn(List(Int)) -> List(Int))),
) -> Result(Nil, TrapReason)
pub fn call_indirect(
  index: Int,
  expected_type: FuncType,
  args: List(Int),
) -> Result(List(Int), TrapReason)

//// threaded family (state_strategy: Threaded) — the handle travels in `st`; a mutating op
//// RETURNS the (possibly rebound) record (the §10 uniform-threading rule).
pub fn t_init_elem(
  st: InstanceState,
  offset: Int,
  entries: List(#(FuncType, fn(InstanceState, List(Int)) -> #(List(Int), InstanceState))),
) -> Result(InstanceState, TrapReason)
pub fn t_call_indirect(
  st: InstanceState,
  index: Int,
  expected_type: FuncType,
  args: List(Int),
) -> Result(#(List(Int), InstanceState), TrapReason)

//// differential canon hook (tests only, §F) — the tier's whole slot image as a
//// `size`-length list: `None` = null slot, `Some(ty)` = filled slot's structural type tag.
//// Closures are not comparable; behaviour is compared via call_indirect. This gives unit 09
//// a structural cross-tier equality it can assert without invoking (the table analog of
//// `rt_mem.to_flat`).
pub fn to_canon(handle: Dynamic) -> List(Option(FuncType))
```

**Behaviour is frozen, not just shape.** Every tier applies the identical **three guards in
spec order** and returns the identical `TrapReason` (§F); `init_elem` whole-range bounds-checks
up front and writes **nothing** on overflow (`TableOutOfBounds`); dispatch is fail-closed on an
un-seeded cell (Cell) / an absent handle field (an internal-invariant crash, never a fabricated
empty table); and dispatch is **never** a data-driven `apply` (§Effect). Ownership split for the
threaded family (reconciled): **this unit** owns it end to end — the owner-additive paged wrappers
in the existing `rt_table` (`TablePaged`, over the immutable `Dict` core) **and** the
implementations for `rt_table_ets`/`rt_table_atomics`. (Unit 03 owns only `rt_state.gleam` — the
record + globals + `table`/`with_table` field seam — and imports neither runtime table module.)

---

## C. Tier × state-strategy composition (the reconciliation)

The two axes are **orthogonal**: `state_strategy` chooses *where the handle lives and how it is
reached*; `table_tier` chooses *the handle's substrate*. Because the handle is always opaque
`Dynamic` in `InstanceState.table`, **every tier composes with every strategy** — there is no
forbidden `(table_tier, state_strategy)` pair (contrast `mem_tier`, where `Safe + Nif` is
forbidden; tables have no `nif` variant).

| axis choice | how the handle is reached |
|---|---|
| `state_strategy: Cell` | the handle sits in the **pdict cell** (`rt_state.table_get` / `table_put`, `«CELL-STATE-ABI-FROZEN»`). `call_indirect`/`init_elem` read/write it there. |
| `state_strategy: Threaded` | the handle is **threaded through `InstanceState`** as a value; `t_call_indirect`/`t_init_elem` project `st.table`, act, and return the (possibly rebound) `st` (no pdict). |

The **§10 uniform-threading rule** makes one threaded signature serve both immutable and mutable
substrates:

| `table_tier` | handle shape (in the `table` slot) | `t_init_elem` returns | `t_call_indirect` returns |
|---|---|---|---|
| `TablePaged` (immutable) | the `Dict`-based `Table` value | a **new** `st` (rebuilt `Table`) | the callee's `st'` (table field unchanged) |
| `TableEts` (mutable-in-place) | the private ETS `tid` (a stable ref) | the **same** `st` (ETS mutated in place; `tid` unchanged) | the callee's `st'` (`tid` unchanged) |
| `TableAtomics` (hybrid) | `#(occ_ref, entries_companion, size)` | an `st` with the **grown companion** (`occ_ref` written in place) | the callee's `st'` |

So a *mutable* backend returns the *same* handle (the mutation happened in place) and an
*immutable* one returns the *rebuilt* handle — **the same head** either way (keystone §A.2, §10).
The dispatch itself never mutates the table slot in the MVP (no runtime `table.set`), so
`t_call_indirect` simply returns the `st'` the invoked build-controlled closure produced (which
carries any memory/global updates the callee threaded).

**Process-local in every tier (the threads non-goal, G8 / §12).** The ETS table is created
**`private`** and owned by the instance process; the `atomics` ref is reachable only through the
handle. Under the one-instance-one-process contract (E1) the handle never crosses a process
boundary — `Cell` confines it to that process's pdict, `Threaded` threads it *within* that
process's call chain — so `ets`/`atomics` are process-local mutable storage, never shared memory.
(Lifecycle corollary, §D: a `private` ETS table is auto-deleted on owner-process death but **not**
GC'd while the process lives — a reused process must delete the prior table before `new`.)

---

## D. `rt_table_ets` — the closure-native tier-O backend

```gleam
/// The ETS-backed funcref table handle. `tid` is a PRIVATE `set` ETS table owned by the
/// instance process, keyed `slot_index -> #(FuncType, closure)` (ETS stores the closure term
/// natively). `size` is the declared `min` (fixed; no runtime `table.grow` in the MVP).
type EtsTable {
  EtsTable(tid: Dynamic, size: Int)
}
```

- **`new(min, _max)`** — `ets:new(twocore_rt_table, [set, private, {keypos, 1}])` (private →
  process-local; `set` → one entry per key), returning the `tid` boxed as opaque `Dynamic`
  alongside `size = min`. Because ETS is not auto-GC'd, `new` first **deletes any prior
  `twocore_rt_table` this process owns** (idempotent re-instantiation, §C lifecycle) — the
  proven `rt_state.clear`-then-`seed` discipline, adapted for a non-GC'd resource.
- **`init_elem(offset, entries)`** — whole-range bounds-check FIRST (`offset >= 0 &&
  offset + len <= size`, else `Error(TableOutOfBounds)` with **no** write); then
  `ets:insert(tid, {offset + k, entry})` for each `entries[k]`. In-place mutation, so no
  `table_put` is needed (the `tid` is unchanged); the read is `rt_state.table_get` (fail-closed
  on an un-seeded cell).
- **`call_indirect(index, expected_type, args)`** — the 3 guards over the ETS table
  (§F algorithm): bounds against `size`; `ets:lookup(tid, index)` → `[]` ⇒
  `UninitializedElement`; structural `ty == expected_type` ⇒ else `IndirectCallTypeMismatch`;
  invoke `target(args)` **directly** (a fun application of the ETS-stored, build-controlled
  closure — never `apply(Mod, Fun, Args)`, D3a).
- **`t_init_elem`/`t_call_indirect`** — thread `st`: `t_init_elem` inserts into `st.table`'s
  `tid`, returns the **same** `st` (in-place mutation, `tid` stable); `t_call_indirect` guards,
  invokes `target(st, args) -> #(results, st')`, returns `Ok(#(results, st'))`. `to_canon` =
  `ets:tab2list` projected to the `size`-length `Option(FuncType)` image.

> **ETS is the right substrate *here* (unlike the whole cell).** The keystone (rt_state docs)
> notes ETS is the *wrong* holder for the whole `{mem, globals, table}` cell — it deep-copies
> the entire term on every read. For a *table* the read is **one slot's** `#(FuncType, closure)`
> per `call_indirect`, so the copy is bounded to a single small entry and stays O(1); the win is
> native closure storage + O(1) in-place `insert` (the Phase-5 `table.set` target). Still tier-O
> (OTP-native, memory-safe, no NIF), which Safe permits.

---

## E. `rt_table_atomics` — the O(1)-integer-slot backend (the honest sharp edge)

```gleam
/// The atomics-backed funcref table handle. `occ` is an `atomics` array of `size` slots
/// (1-based, 0 = null, k>0 = the 1-based dense key into `entries`); `entries` is an IMMUTABLE
/// `Dict(dense_key -> #(FuncType, closure))` — BEAM `atomics` can hold only 64-bit integers,
/// so the FUNS live in the companion (D3a: still build-controlled, never in the atomics array),
/// and the atomics layer is the O(1) sparse-slot → dense-entry index. `size` is the declared
/// `min` (fixed at creation — the `grow` sharp edge, below).
type AtomicsTable {
  AtomicsTable(occ: Dynamic, entries: Dict(Int, #(FuncType, closure)), size: Int)
}
```

- **`new(min, _max)`** — `atomics:new(max(min, 1), [{signed, False}])` (all slots default 0 =
  null), empty companion, `size = min`. Like `rt_mem`'s `atomics` backend, the array is
  **fixed-size at creation** — which is exactly right for the MVP (funcref tables do not grow at
  runtime). When Phase-5 `table.grow` lands it hits the same pre-allocation sharp edge `rt_mem`'s
  `atomics` `grow` documents (pre-allocate to the effective max, or **fail-closed reject** an
  over-cap max — never a silent fallback) — noted for forward-compat, not built here.
- **`init_elem(offset, entries)`** — whole-range bounds-check first (else `TableOutOfBounds`, no
  write); then for each `entries[k]`: assign the next dense key `d`, `dict.insert(companion, d,
  entry)`, and `atomics:put(occ, offset + k + 1, d)` (1-based). O(1) per slot; the companion is
  the immutable source of truth for the closure + type tag.
- **`call_indirect`** — 3 guards: bounds against `size`; `atomics:get(occ, index + 1)` → `0` ⇒
  `UninitializedElement`, else dense key `d`; `dict.get(companion, d)` → `#(ty, target)`;
  structural `ty == expected_type` else `IndirectCallTypeMismatch`; invoke `target(args)`
  directly. The only runtime-data inputs are the integer `index` and the integer `d` — **neither
  is ever turned into a module/function atom** (D3a); dispatch is the build-controlled companion
  closure.
- **`t_init_elem`/`t_call_indirect`** — thread `st`: `t_init_elem` writes `occ` in place and
  returns an `st` with the **grown companion** (the `occ` ref is stable, the `Dict` changed);
  `t_call_indirect` guards, invokes `target(st, args)`, returns `Ok(#(results, st'))`. `to_canon`
  walks `0..size-1`: `atomics:get == 0` ⇒ `None`, else the companion entry's `FuncType` ⇒
  `Some(ty)`.

> **Honest framing (G8).** For an immutable MVP funcref table `TableAtomics` is *functionally
> equivalent* to `TablePaged` at call time (both O(1)); its distinguishing value is the O(1)
> in-place `occ` write that a future `table.set` needs. It ships because the keystone froze the
> `TableAtomics` variant and the interface must be complete — not because it beats `TablePaged`
> on the MVP corpus. Unit 10's benchmark reports it as such.

---

## F. The 3-fault dispatch is byte-identical across tiers (the differential, §11)

**The shared guard algorithm — every tier, every strategy, unchanged from P2-05**
(<https://webassembly.github.io/spec/core/exec/instructions.html>, `call_indirect`;
<https://webassembly.org/docs/security/> — the runtime type check *is* the table's type-safety
guarantee):

```
dispatch(handle, index, expected_type, args):
  if index < 0 || index >= handle.size      -> Error(UndefinedElement)        // guard 1 (bounds)
  case slot(handle, index):
    null / absent                            -> Error(UninitializedElement)   // guard 2 (null)
    #(ty, target):
      if ty != expected_type                 -> Error(IndirectCallTypeMismatch)// guard 3 (type)
      else                                   -> invoke target with args        // build-controlled
```

The guard **order is observable** and identical in every tier: an OOB index traps
`UndefinedElement` *before* any null/type inspection; a null in-range slot traps
`UninitializedElement` *before* any type comparison. Guard 3 is **exact structural `FuncType`
equality** (Gleam `==` on `FuncType(params, results)`) — never keyed on typeidx, so two
structurally-equal types from different type entries match and differing params **or** results
mismatch (WASM 1.0 semantics; valid/instructions.html makes the static check, exec makes the
per-call dynamic one). `init_elem`'s whole-range OOB is `TableOutOfBounds`.

**`TablePaged` is the differential oracle for the table tiers** (the table analog of `rt_mem`'s
flat-binary `rebuild` oracle, E4/§11): the immutable-`Dict` implementation is trivially correct.
Unit 09 drives **one shared op-trace** — `new(size, max)`; a sequence of in-range/OOB `init_elem`
segments; `call_indirect` at OOB, null, wrong-type, and right-type indices — through **each
shipped `(table_tier × state_strategy)` combination and the `TablePaged` oracle**, asserting
after each op: identical returned value/results, identical `Ok`/`Error(reason)`, and identical
`to_canon` type-tag image. Identical `call_indirect` behaviour across tiers is the G7 correctness
bar and this unit's headline invariant.

---

## Effect / soundness / security note

- **No ambient authority (D3a) in every tier.** The dispatched target is always a
  **build-controlled closure** supplied by the generated `instantiate` via `init_elem`/
  `t_init_elem` (emit_core captures a compile-time-literal `'twocore@wasm@<mod>':'f<idx>'/arity`
  inside it). `rt_table_ets` stores it natively; `rt_table_atomics` stores an **integer** dense
  key in the atomics array with the closure in an immutable companion — both invoked directly.
  **Neither module ever `apply/3`s data-derived names or builds a module/function atom from
  inputs;** the only runtime-data inputs reaching a control transfer are the integer `index` and
  the integer dense key. The *generated-code* security invariant is **unchanged** (G5) — the seam
  emits `call '<table_module>':'call_indirect'(…)` regardless of tier — so the unit-02 structural
  test needs no per-tier extension; the D3a burden is on *this unit's bodies* (module-level test).
- **Fail-closed (D4/E3).** Cell-backed ops read the handle via `rt_state.table_get` (crashes
  node-safe on an un-seeded cell, never fabricates an empty "succeeding" table); threaded ops
  require the handle present in `st.table`. An absent handle is an internal-invariant violation,
  not a WASM trap.
- **Process-local; tier-O never NIF (G6, §12).** `private` ETS + a non-shared `atomics` ref,
  confined to the instance process (§C) — never cross-process, never shared memory. Both backends
  are OTP-native/memory-safe; there is no `nif` table tier, so `table_tier` cannot violate
  Safe-forbids-nif and Safe permits all three.
- **Raw bits (D5) / conformance-neutral (G7).** Args/results are raw-bit `Int`s (no BEAM-double
  round-trip); no IR node, `TrapReason`, or grammar change — a tier is a runtime module swap and
  `call_indirect.wast` stays green under each.

---

## Verification — Definition of Done (D8: assert the spec, not the impl)

Write the spec-cited suites (cite exec/instructions.html, valid/instructions.html,
exec/modules.html, webassembly.org/docs/security), **not** whatever the code emits. For each new
tier module (`rt_table_ets`, `rt_table_atomics`), and mirroring the Phase-2 `rt_table` suite:

1. **Happy path.** A slot `#(FuncType([TI32,TI32],[TI32]), add-closure)`;
   `call_indirect(slot, FuncType([TI32,TI32],[TI32]), [3,4])` → `Ok([7])`; a 0-arg/0-result and a
   multi-result target also round-trip (the list ABI).
2. **Three faults, right reason & ORDER.** `index = size` / `index = -1` → `UndefinedElement`
   (even when the hypothetical slot would be null/wrong-type — bounds fires first); an in-range
   never-filled slot → `UninitializedElement` (before any type check); a filled slot whose `ty`
   differs (params **or** results) → `IndirectCallTypeMismatch`.
3. **Structural type equality.** Distinct-but-structurally-equal `FuncType`s match;
   `FuncType([TI32],[TI32])` vs `[TI64]→[TI32]` and vs `[TI32]→[]` each mismatch — `==` is
   structural, not typeidx.
4. **`init_elem` whole-range bounds.** `offset + len > size` (and `offset = size`) →
   `Error(TableOutOfBounds)` **and** a later `call_indirect` to any slot it would have filled still
   traps `UninitializedElement` (no partial write); an in-range segment fills exactly its slots.
5. **Both families (Cell **and** Threaded).** Every case above runs through the cell-backed heads
   (seed a pdict cell) **and** the threaded heads (over an `InstanceState`), asserting the threaded
   ops return the record per the §10 rule (mutable → same handle, immutable → rebuilt).
6. **Process-local + lifecycle + fail-closed.** The ETS table is `private` (a second process
   cannot read it) and a re-`new` in a reused process deletes the prior table (no leak); the
   atomics ref is unreachable except via the handle; cell-backed ops in a process with **no**
   seeded cell crash (never a wrong `Ok`/garbage).
7. **D3a (per module).** Assert by construction/review + a grep-backed test that neither module
   `apply/3`s data-derived names, builds a module/function atom from inputs, or stores anything but
   build-supplied closures/integers.
8. **Tier differential + trap messages (§F).** One op-trace through every `(table_tier ×
   state_strategy)` and the `TablePaged` oracle → identical values/traps/`to_canon` after each op;
   and `spec_trap_message` reads `"undefined element"` / `"uninitialized element"` / `"indirect
   call type mismatch"` / `"out of bounds table access"`.
9. **Conformance (wired by unit 11).** `call_indirect.wast` (P2-05 scope: 114 `assert_return` +
   18 `assert_trap`, same within-file skips) stays **fail=0** with `table_tier` set to each of
   `TableEts`/`TableAtomics`.

**Gate:** `gleam format --check src test` clean; `gleam build` **zero warnings** (no lingering
`todo`); **`gleam test` stays green** (674 + your new tests); every public function/type carries a
`///` contract doc (D8). **Done = the suites + the tier differential pass**, not "it compiles."

---

## What this unit leaves

- **Unit 07 (linker + profiles):** maps `table_tier → table_module` (§A); no `nif` clause needed
  for `table_tier`. `portable` keeps `TablePaged` (the tier-P table); a perf profile may choose
  `TableEts`/`TableAtomics`. **Unit 08 (pipeline + CLI):** selects `table_tier` per profile.
- **Unit 09 (tier differential):** runs the §F op-trace across every `(table_tier ×
  state_strategy)` at corpus scale. **Unit 11 (capstone):** proves `call_indirect.wast` fail=0
  under each table tier.
- **Phase 5 (reference types):** `table.get`/`set`/`grow`/`fill`/`copy` make funcref/externref
  tables runtime-mutable — where the tier-O `ets`/`atomics` substrates deliver their real
  O(1)-mutation payoff (and where `atomics` `grow` inherits `rt_mem`'s pre-allocation sharp edge).
  This unit ships the substrates ready for it.
