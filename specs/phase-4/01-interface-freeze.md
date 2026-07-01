# Unit 01 — Interface Freeze (Phase-4 keystone)

> **One owner. Design + the Binding-axis change, compiling & green. On the critical path of
> everything.** Read [`00-overview.md`](00-overview.md) (G1–G8) first, then the Phase-1/2/3
> overviews (D1–D10, E1–E8, F1–F8). This unit freezes the **two** contracts the Phase-4 swarm
> binds to — the **state-strategy axis** (`«STATE-STRATEGY-FROZEN»`, the tier-P `threaded`
> instance-state record + tier-P `rt_state` signatures + the `emit_core` seam-expansion
> contract) and the **memory/table trust-tier axis** (`«MEM-TIER-FROZEN»`, the `mem_tier`/
> `table_tier` `Binding` axes + the uniform `rt_mem`/`rt_table` backend interface + the
> **Safe-forbids-nif** linker rule) — and lands the `Binding` extension **GREEN** (build
> compiles, `gleam test` passes, zero warnings) before the parallel units begin.

The build is currently zero-warning with **674 passing tests** (conformance 15747 / 411 / 0
under both profiles). **It must stay that way after this unit.** Phase 4 adds **no** `Expr`/
`NumOp`/`ConvOp`/`TrapReason` variants and **no** `.ir` grammar change (G7) — so unlike the
Phase-2/3 keystones there are **zero** exhaustive-match reaches (printer/parser/emit_core/
rt_trap are untouched). The only compiling change is three new enums + three `Binding` fields,
which break exactly **one** constructor (`safe_default()`, the sole full `Binding(...)`); every
other `Binding` in the tree is a record-spread that absorbs the new fields automatically. The
threaded runtime + the tier backends are **frozen as signatures in this document** (units
02–07 implement them), exactly as Phase 2 froze the state-access seam convention in prose.

---

## Deliverables & freeze milestones

1. `«STATE-STRATEGY-FROZEN»` — `StateStrategy { Cell Threaded }` + `Binding.state_strategy`
   (`instance.gleam`, landed green, `safe_default` = `Cell`); the tier-P **threaded
   instance-state record** (reuses `rt_state.InstanceState`) + the tier-P `rt_state`/`rt_mem`/
   `rt_table` **threaded signatures** (`fresh`/`t_*`, NO pdict); the **`emit_core`
   seam-expansion contract** (§A.3 — the uniform-threading rule §10, the G4 constant-space
   back-edge, the record-returning `instantiate`). Unblocks 02, 03, 04, 06, 08, 09, 11 (04/06
   own the paged `rt_mem`/`rt_table` threaded wrappers frozen in §A.2).
2. `«MEM-TIER-FROZEN»` — `MemTier { Paged Atomics Nif }` + `TableTier { TablePaged TableEts
   TableAtomics }` + `Binding.mem_tier`/`table_tier` (`instance.gleam`, landed green,
   `safe_default` = `Paged`/`TablePaged`); the **uniform `rt_mem`/`rt_table` backend
   interface** every tier implements (§B.2); the **differential-oracle** contract holding every
   tier to the spec (§B.3, §11); the **Safe-forbids-nif** linker rule (§B.4, G6); the
   **full-build-identity `coexist_name` keying** (§B.5, so distinct `.beam`s of one source get
   distinct atoms). Unblocks 04, 05, 06, 07, 08, 09.

**Out of scope for this unit:** the threaded-seam codegen (02), the tier-P `rt_state` bodies
(03), the `atomics`/`nif`/`ets` backend bodies (04/05/06), the `portable`/`ceiling` profiles +
the Safe-forbids-nif check body (07), the pipeline/CLI selection (08). This unit ships the
`Binding` axes (real, total, zero `todo`) + the frozen signatures + the land-green reach + a
scratch freeze test.

---

## Land-green cross-file reaches (enumerate EVERY one)

Gleam has no default field values, so extending `Binding` breaks its **one** full constructor.
Because Phase 4 adds no IR node and no `TrapReason` (G7), that is the **only** structural reach.

| # | File | Reach | Why it breaks / what to add |
|---|---|---|---|
| 1 | `runtime/instance.gleam` | **owner-additive** (unit 01 owns it) | Add `StateStrategy`, `MemTier`, `TableTier` enums; add `state_strategy: StateStrategy`, `mem_tier: MemTier`, `table_tier: TableTier` to `Binding`; populate them in `safe_default()` = `Cell`/`Paged`/`TablePaged` (the Phase-2/3 posture, byte-identical). |
| 2 | `runtime/profiles.gleam` | **owner-additive (constructors verify-only; `coexist_name` extended)** | `safe()`/`safe_capped(_)`/`safe_metered(_)`/`unsafe()` are all record-spreads over `safe_default()`/`safe()` (`Binding(..safe_default(), …)`) — the spread absorbs the three new fields, so they **compile unchanged** and stay `Cell`/`Paged`/`TablePaged`. The `portable`/`ceiling` profiles are unit 07's, not the keystone's. The one deliberate edit here is extending `coexist_name` to key the coexist atom on the full build identity (§B.5). |
| 3 | `test/twocore/runtime/profiles_test.gleam`, `test/twocore/optimize/differential_test.gleam` | **reach — spreads verify-only; `coexist_name` callers updated** | The only test `Binding(...)` sites are spreads (`Binding(..profiles.safe(), …)`, `Binding(..base, opt_level: …)`); the spread absorbs the new fields. Extend `profiles_test` with the §B.4 fail-closed assertions (recommended, not required to compile). The `coexist_name` callers in `profiles_test` (and `coexistence_test`/`linker_coexist_test`) are updated to the extended §B.5 signature. |

Beyond the field-addition break, the keystone makes **one deliberate owner-additive edit** to
`profiles.gleam`: it extends `coexist_name` to key the coexist atom on the full build identity
(§B.5), so two distinct `.beam`s of one source (e.g. `safe()`-cell vs `portable()`-threaded,
both Safe) can no longer collide under one atom. This reaches the three Phase-3 coexistence
callers (`test/twocore/optimize/coexistence_test.gleam`,
`test/twocore/runtime/linker_coexist_test.gleam`, `test/twocore/runtime/profiles_test.gleam`) —
updated in place to the new signature; the default Safe/`Cell`/`Paged` atom is unchanged, so
every existing coexistence assertion still holds.

`emit_core.gleam` reads `binding.mem_module`/`state_module`/`table_module`/`safe_max_pages`;
adding fields does not break any read, and the seam stays keyed on the **module** names, never
on `mem_tier`/`state_strategy` (G5 — the codegen-shape change is unit 02's, gated on
`state_strategy`; the tier is a module swap the linker resolves). Announce both milestones in
`state.md` with this reach list.

---

## A. `«STATE-STRATEGY-FROZEN»` — the state-strategy axis (`cell` | `threaded`)

### A.1 The `StateStrategy` enum + the `Binding` field (landed green)

`state_strategy` selects **how** the one `emit_core` state-access seam lowers (G1/G5) — a
**codegen-shape** sub-axis, NOT a module swap through the binding. It is orthogonal to
`mem_tier` (§B): the strategy picks the *function family* the seam calls (`store` vs `t_store`)
and whether generated functions thread a state record; the tier picks the *module*.

```gleam
/// How generated code reaches mutable instance state (the memory handle, mutable globals, the
/// table) — the tier-P/O state sub-axis (G1). A codegen-shape choice realised in `emit_core`'s
/// state-access seam (G5), NOT a module swap through the binding.
///
/// - `Cell`: tier-O, the Phase-2/3 default. The seam emits `call '<state/mem/table_module>':
///   '<op>'(...)` against the per-process **process-dictionary cell** (`rt_state`); generated
///   function arities are unchanged; `instantiate/0` seeds the cell and returns `'ok'`.
/// - `Threaded`: tier-P, new. The seam threads a purely-functional **instance-state record**
///   (`rt_state.InstanceState`) through generated code — every state-reaching function takes
///   the record as a parameter and RETURNS the (possibly updated) record (the uniform-threading
///   rule §10, §A.3). No process dictionary; no OTP-native state; the "runs-anywhere" build.
pub type StateStrategy {
  Cell
  Threaded
}
```

`Binding` gains `state_strategy: StateStrategy`; `safe_default()` sets `Cell` (unchanged
posture). `profiles.safe()`/`unsafe()` inherit `Cell` via their spreads; unit 07's `portable`
overrides it to `Threaded`, `ceiling` keeps `Cell` (the perf build — see G3).

### A.2 The threaded instance-state record + the tier-P `rt_state`/`rt_mem`/`rt_table` signatures

**The box (frozen — reuse the existing record).** The threaded record IS
`rt_state.InstanceState`, already defined and exactly the box G1/G4 describe — a **fixed-size
handle** to the immutable mem/table/globals structures:

```gleam
pub type InstanceState {
  InstanceState(mem: Dynamic, globals: Dict(String, Int), table: Dynamic)
}
```

`Cell` stores this record in the pdict (`rt_state.seed`); `Threaded` threads the **same
record** as a value. `mem`/`table` stay `Dynamic` (opaque — `rt_mem`/`rt_table` own their
shapes and coerce), so the record is **tier-orthogonal**: under `paged` the `mem` slot holds a
`Mem`, under `atomics` it holds the `atomics` ref handle, under `nif` the resource handle —
threading is uniform regardless (§10). Globals stay raw-bit-pattern `Int`s (D5).

**Tier-P `rt_state` (owner unit 03 — the record + globals only; NO pdict; does NOT import
`rt_mem`/`rt_table`, preserving the `Dynamic` mem/table opacity).** The threaded analogue of
`seed`/`global_get`/`global_set` — pure, value-threaded:

```gleam
/// Build the initial threaded record from the same `StateDecl` the cell strategy passes to
/// `seed` — but RETURN it (no pdict write). Called once by the threaded `instantiate/0`.
pub fn fresh(decl: StateDecl) -> InstanceState

/// Read mutable global `name`'s raw bit pattern from the threaded record (read-only; `st`
/// unchanged). Fail-closed on an undeclared name (internal invariant, unreachable post-validation).
pub fn t_global_get(st: InstanceState, name: String) -> Int

/// Rebind mutable global `name` to `value`, RETURNING the updated record (other fields shared
/// by reference — a new 3-tuple, not a copy). The §10 uniform-threading rule for a mutating op.
pub fn t_global_set(st: InstanceState, name: String, value: Int) -> InstanceState
```

**Tier-P `rt_mem` threaded wrappers (owner unit 04, owner-additive to the existing
`rt_mem.gleam` — one owner per file) — reuse the EXISTING pure core.**
`rt_mem` already ships a pure, value-threaded paged core — `mem_load`/`mem_store`/`mem_grow`/
`mem_size`/`mem_init_data`, taking + returning a `Mem` (`mem_store -> Result(Mem, _)`,
`mem_grow -> #(Int, Mem)`). The threaded wrappers are **thin adapters** that project `st.mem`
(coerce `Dynamic → Mem`), call that pure core, and inject the result back into the record:

```gleam
pub fn t_load(st: InstanceState, bytes: Int, signed: Bool, result_width: Int,
              addr: Int, offset: Int) -> Result(Int, TrapReason)          // read-only: st unchanged
pub fn t_store(st: InstanceState, bytes: Int, addr: Int, value: Int,
               offset: Int) -> Result(InstanceState, TrapReason)          // returns the rebound record
pub fn t_size(st: InstanceState) -> Int                                   // read-only
pub fn t_grow(st: InstanceState, delta: Int) -> #(Int, InstanceState)     // prev pages + rebound record
pub fn t_init_data(st: InstanceState, offset: Int,
                   bytes: BitArray) -> Result(InstanceState, TrapReason)   // at instantiate
```

Reads (`t_load`/`t_size`) return only the value and leave `st` untouched — the seam keeps
threading the *same* record it passed in. Mutators return the record (§10). Under `atomics`/
`nif` the underlying handle is mutable, so the returned `mem` is the **same handle** (mutated
in place) — one signature serves the immutable and mutable backends alike (§10, G2). Unit 04
also owns — owner-additive to `rt_mem.gleam` — the paged `to_flat(mem: Dynamic) -> BitArray`
differential hook (§B.2) and a **public `Dynamic → Mem` coercion**, so the threaded wrappers
(and the §B.3 oracle) can project `st.mem` uniformly.

**Tier-P `rt_table` threaded wrappers (owner unit 06, owner-additive to the existing
`rt_table.gleam` — one owner per file).** Under `Threaded` the dispatched
target itself threads the record, so the stored closure type changes and dispatch returns the
record:

```gleam
/// Threaded closure type: a table entry under `Threaded` is
/// `#(FuncType, fn(InstanceState, List(Int)) -> #(List(Int), InstanceState))`
/// (vs the cell strategy's `#(FuncType, fn(List(Int)) -> List(Int))`).
pub fn t_init_elem(st: InstanceState, offset: Int,
      entries: List(#(FuncType, fn(InstanceState, List(Int)) -> #(List(Int), InstanceState))))
  -> Result(InstanceState, TrapReason)                                    // OOB → TableOutOfBounds
pub fn t_call_indirect(st: InstanceState, index: Int, expected_type: FuncType,
      args: List(Int)) -> Result(#(List(Int), InstanceState), TrapReason) // 3-fault, then thread St
```

The three fail-closed guards (bounds → null → exact type) and the no-ambient-authority
invariant (D3a) are **unchanged** — the only new thing is that the build-controlled closure
consumes and produces the state record.

### A.3 The `emit_core` seam-expansion contract (units 02 & 08 implement)

Every stateful op already routes through **one** helper, `seam_call(module, fn_name, args)`
(`emit_core.gleam`), which emits `call '<module>':'<fn_name>'(args)` with `module` a fixed
`binding.*_module` atom and `fn_name` a literal (D3a). The threaded build is a **seam
expansion** of this helper's callers, not a scattered rewrite (E1/G1):

**The uniform-threading rule (§10, frozen).** Under `state_strategy: Threaded`, a generated
function is **state-reaching** iff its body contains a stateful op OR (transitively) calls a
state-reaching function; unit 02 computes this as a call-graph closure. A state-reaching
function `f(A, B) -> Results` is emitted as `f(St, A, B) -> {ResultPackage, St'}` — the
instance-state record threaded as the **leading parameter**, and the normal return package
(the Phase-1 `function_return` shape: 0→`'ok'`, 1→bare, N→N-tuple) wrapped with the outgoing
`St'` into a 2-tuple. A **pure** function keeps its Phase-1 signature (no `St`), so pure
numeric leaves pay nothing. `CallDirect` to a state-reaching callee becomes
`{Rs, St2} = call 'f'(St, Args…)`; to a pure callee it is unchanged.

**The per-op lowering (threaded; the module comes from the binding, the function from the
strategy):**

| IR node | Threaded Core (schematic) | Notes |
|---|---|---|
| `MemLoad` | `V = case '<mem_module>':'t_load'(St,…) of {ok,X}->X; {error,R}->'<trap>':raise(R) end` | read-only; `St` threaded on unchanged |
| `MemStore` | `St2 = case '<mem_module>':'t_store'(St,…) of {ok,S}->S; {error,R}->raise(R) end` | ordered effect; addr→value→store; non-DCE (E6) |
| `MemSize` | `V = '<mem_module>':'t_size'(St)` | read-only |
| `MemGrow` | `{V, St2} = '<mem_module>':'t_grow'(St, Delta)` | new record bound |
| `GlobalGet` | `V = '<state_module>':'t_global_get'(St, Name)` | read-only |
| `GlobalSet` | `St2 = '<state_module>':'t_global_set'(St, Name, Val)` | ordered effect |
| `CallIndirect` | `{Rs, St2} = case '<table_module>':'t_call_indirect'(St,…) of {ok,P}->P; {error,R}->raise(R) end` | 3-fault, then thread |

Under `state_strategy: Cell` the seam emits **exactly today's** `store`/`load`/`size`/`grow`/
`global_get`/`global_set`/`call_indirect` calls with today's arities — **byte-identical** to
Phase 2/3. The strategy is the ONLY switch; the cell path must not change by one atom.

**Constant space under threaded (G4, frozen; tested in unit 09).** A `Loop` that threads state
carries `St` as a **leading `LoopParam`**; the back-edge stays the tail
`apply 'L'(St', vs…)` the Phase-1 template already emits (`emit_loop`). Because `InstanceState`
is a **fixed-size box** (a 3-tuple pointing at immutable structures), threading it does not grow
the stack, and each store **rebinds the box** (a new 3-tuple sharing two of three fields), never
the loop frame. So `sum_to(100000)` and a store-loop run in constant space and stay preemptible
(ordinary BEAM code) — the tested acceptance property, not an assertion.

**The record-returning `instantiate` (frozen).** Under `Threaded`, the generated `instantiate/0`
BUILDS the record via `'<state_module>':'fresh'(Decl)` (instead of `seed`), threads it through
element → data → start (each `t_init_elem`/`t_init_data`/start returns the updated `St`), and
**returns the `InstanceState`** (instead of `'ok'`). The run-ABI (unit 08) passes that returned
record as the leading arg to each `invoke`, threading the returned `St'` forward across calls;
one instance = one process still holds, but the state travels as a value, not in the pdict. The
`seed_fuel`/`seed_policy` seed lines (F5/F4) are unchanged (metering/host are pdict-seeded,
orthogonal to state threading). Under `Cell`, `instantiate/0` is byte-identical to today
(`seed` + return `'ok'`).

---

## B. `«MEM-TIER-FROZEN»` — the memory/table trust-tier axes + Safe-forbids-nif

### B.1 The `MemTier`/`TableTier` enums, the `Binding` fields, and the tier→module mapping

```gleam
/// The linear-memory trust tier (G2). Selects which `rt_mem` backend the linker links, all
/// behind one uniform interface (§B.2). Orthogonal to `state_strategy` (§A) and to policy (G3).
///
/// - `Paged`: tier-P (Phase-2). Immutable-binary rebuild-on-write; universal, sparse-friendly.
/// - `Atomics`: tier-O (new, unit 04). O(1) process-local mutation via Erlang `atomics` — no
///   custom native code, cannot crash the node. The shipped performance lever. `grow` is the
///   sharp edge (fixed size at creation → pre-allocate to the effective max; requires a bounded
///   max/cap — an uncapped no-max module is a fail-closed link-time rejection, never a silent
///   4 GiB pre-allocation or paged fallback, §B.2).
/// - `Nif`: tier-N (new, unit 05, **Unsafe-only**). Raw O(1) native memory; the ceiling;
///   **forbidden in Safe** (G6, §B.4). Interface + reference; the C impl may be documented-deferred.
pub type MemTier {
  Paged
  Atomics
  Nif
}

/// The funcref-table trust tier (G2). Every variant is node-safe (tier P or O) — there is no
/// `nif` table tier, so `table_tier` cannot violate Safe-forbids-nif.
///
/// - `TablePaged`: tier-P (Phase-2) — immutable sparse `Dict` table (the existing `rt_table`).
/// - `TableEts`: tier-O (new, unit 06) — an `ets`-backed table.
/// - `TableAtomics`: tier-O (new, unit 06) — an `atomics`-indexed table.
pub type TableTier {
  TablePaged
  TableEts
  TableAtomics
}
```

`Binding` gains `mem_tier: MemTier` and `table_tier: TableTier`; `safe_default()` sets `Paged`/
`TablePaged` (byte-identical to Phase 2/3). **`mem_module` continues to name the linked impl;
`mem_tier` is the declared tier the LINKER (unit 07) maps to a module name** — keeping
`emit_core` tier-agnostic (G5, it reads only `mem_module`, never `mem_tier`). Because
`mem_module` — not `mem_tier` — is the **load-bearing field** `emit_core` links (G5), unit 07's
**`resolve_tiers(binding)`** is the SINGLE source that couples the two: it sets
`mem_module := mem_module_for(mem_tier)` and `table_module := table_module_for(table_tier)`, so
the linked impl can never drift from the declared tier (a drift `validate_binding` also rejects,
§B.4):

| `mem_tier` | `mem_module` | Owner |
|---|---|---|
| `Paged` | `"twocore@runtime@rt_mem"` | Phase-2 (exists) |
| `Atomics` | `"twocore@runtime@rt_mem_atomics"` | unit 04 |
| `Nif` | `"twocore@runtime@rt_mem_nif"` | unit 05 |

| `table_tier` | `table_module` |
|---|---|
| `TablePaged` | `"twocore@runtime@rt_table"` |
| `TableEts` | `"twocore@runtime@rt_table_ets"` |
| `TableAtomics` | `"twocore@runtime@rt_table_atomics"` |

So a tier is a **module swap** (B2 link-time binding, unchanged), composed with the
`state_strategy` function-family switch (§A.3): the seam emits `call '<mem_module>':
'<store|t_store>'(...)`. This is why the mandate's "differ only in the linked `rt_mem` module"
(G8) and G5's "confined behind `rt_mem`/`rt_table`" both hold.

> **Freeze decision — separate modules, not `extend`.** Each tier is its **own file**
> (single-owner D1: `rt_mem_atomics`, `rt_mem_nif`, `rt_table_ets`, `rt_table_atomics`),
> implementing the frozen interface (§B.2); the linker selects one. This supersedes the
> overview §4 file map's "`rt_mem.gleam (extend)`" shorthand (two owners on one file would
> violate D1, and a module swap needs distinct atoms) — flagged to the EM.

### B.2 The uniform `rt_mem`/`rt_table` backend interface (units 04/05/06 bind to it)

Every `rt_mem` tier module exposes the **same public heads** so the seam calls any of them
identically (the existing paged `rt_mem` already satisfies the cell-backed + pure families; a
new tier re-implements all three):

- **construction:** `fresh(min_pages: Int, max_pages: Option(Int), safe_cap: Int) -> Dynamic`.
- **cell-backed family** (for `state_strategy: Cell`) — the frozen Phase-2 heads:
  `load(bytes, signed, result_width, addr, offset) -> Result(Int, TrapReason)`,
  `store(bytes, addr, value, offset) -> Result(Nil, TrapReason)`, `size() -> Int`,
  `grow(delta) -> Int`, `init_data(offset, bytes) -> Result(Nil, TrapReason)`.
- **threaded family** (for `state_strategy: Threaded`) — the §A.2 heads
  (`t_load`/`t_store`/`t_size`/`t_grow`/`t_init_data`).
- **differential hook** (for §B.3): `to_flat(mem: Dynamic) -> BitArray` — the tier's whole
  in-bounds byte image, so the oracle can compare byte-for-byte. The **paged** `to_flat` is
  owner-additive to `rt_mem.gleam` (unit 04); each new tier module ships its own.

`rt_table` tiers expose `new(min, max) -> Dynamic`, the cell-backed `init_elem`/`call_indirect`,
and the threaded `t_init_elem`/`t_call_indirect` (§A.2). **Behaviour is frozen, not just
shape:** every tier is little-endian, no-wrap effective address, trap-before-write, bounds-check
in every tier (the §11 security invariant, G6). **The `atomics` `grow` sharp edge — one place,
no silent fallback:** `atomics` memory is fixed-size at creation, so `fresh` pre-allocates to the
effective max (`min(declared_max ?? safe_cap, safe_cap, hard_max_pages)` — the same
`effective_max` the paged core bakes), and `grow` moves a logical page-count watermark within
that ceiling (`-1` past it, never a re-allocation), keeping `memory.size`/`memory.grow`
spec-observable. On an **uncapped no-max module** (no declared max AND no `safe_cap`, so the
effective max is the 65536-page / 4 GiB hard ceiling), `fresh` is a **fail-closed link-time
rejection** (`Error`, "atomics requires a bounded max/cap <= the reserve cap") — NOT a silent
4 GiB pre-allocation and NOT a silent paged fallback. Any degrade, if ever permitted, must be
EXPLICIT and REPORTED, never silently substituted.

### B.3 The differential oracle holds every tier to the spec (§11)

**Correction of a common mischaracterisation (grounded in the real code):** `rt_mem`'s `o_*`
family (`o_fresh`/`o_load`/`o_store`/`o_grow`/`o_init_data`/`o_size`/`o_flat`, over `OMem`) is
the **flat-binary rebuild ORACLE** (E4), *not* a tier-O backend — the actual tier-O `atomics`
backend does not exist yet (unit 04 builds it). The oracle is the trivially-correct reference:
one contiguous binary, store rebuilds the whole thing.

§11 **reuses this oracle as the differential reference for every tier.** Unit 09 drives one
shared operation trace (`fresh`; a sequence of in-bounds/out-of-bounds `load`/`store`/`grow`/
`init_data`) through each shipped `(state_strategy, mem_tier)` combination **and** through the
oracle, asserting after each op: identical returned value, identical trap (`Ok`/`Error(reason)`),
and identical byte image (`<tier>.to_flat(mem) == o_flat(oracle)`). The oracle itself is held to
explicit spec-corner tests (E4 — sub-word sign/zero-extension, no-wrap `0xFFFFFFFF`+offset,
trap-before-write, grow caps). A bounds bug's worst case in tiers P/O is a wrong/missing trap or
a node-safe crash — never a host escape; tier-N is the one place native code runs, gated to
Unsafe (§B.4). This is the G7 correctness bar: **every tier is byte-identical to the spec**.

### B.4 The Safe-forbids-nif linker rule (G6; enforced in unit 07)

**Safe permits tier P or O, never N.** Two layers, both fail-closed (D4):

1. **Structural — no constructor yields Safe+Nif.** Gleam has no default field values, so every
   profile constructor NAMES its tier. `safe()`/`safe_capped(_)`/`safe_metered(_)`/
   `safe_default()` all set `mem_tier: Paged` (a Safe `atomics` profile would set `Atomics`),
   **never** `Nif`; only the Unsafe `ceiling()` profile (unit 07) sets `Nif`. So a `Safe + Nif`
   binding is **unconstructible through the profile API** — the fail-closed guarantee is a
   property of the type, not a runtime check.
2. **Defensive — the linker rejects a hand-built Safe+Nif binding.** Unit 07 adds a fail-closed
   validation gate to `profiles.gleam`:

   ```gleam
   /// Reject a policy-incoherent binding (G6), fail-closed. Two rejections:
   /// `Error(SafeForbidsNif)` iff a Safe binding names a tier-N memory (`mode == Safe &&
   /// mem_tier == Nif`) — tier-N can crash the node, so it is Unsafe-only; and
   /// `Error(TierModuleIncoherent)` iff the load-bearing `mem_module` has drifted from its tier
   /// (`mem_module != mem_module_for(mem_tier)`) — so the gate guards the field `emit_core`
   /// actually links, not the advisory `mem_tier` alone. Every other composition of
   /// `state_strategy × mem_tier × policy` is admitted.
   pub fn validate_binding(b: Binding) -> Result(Binding, LinkError)
   ```

   `table_tier` needs no clause (no `Nif` variant). The keystone freezes the **rule and the
   gate's shape**; unit 07 implements the body + spec-cited tests and makes **`link/1` (validate
   + `resolve_tiers` + `instantiate`) the SOLE `Binding → Instance` seam** — the one path that
   runs the fail-closed gate — so `instantiate/1` is made **private to `profiles`** (or itself
   validates, fail-closed on Safe+Nif); no caller may reach an ungated `instantiate/1` (the
   ungated path is the path of least resistance = fail-open). Unit 08 proves `link/1` is the sole
   seam the run-ABI/CLI use. The composed named profiles unit 07 also owns: **`portable`**
   (`Threaded` + `Paged` + `bif` + Safe — the runs-anywhere headline, no OTP-native state, no NIF)
   and **`ceiling`** (Unsafe + `Atomics`/`Nif` + `Cell` + aggressive optimizer — the perf build).

### B.5 Coexistence keying — the output atom keys on the full build identity (B3/G8)

Two builds of ONE source that differ in `state_strategy` or `mem_tier` are **different `.beam`s**
(the calling convention and the linked `rt_*` module differ, G1/B3), yet the Phase-3
`coexist_name/2` keys the distinct output atom on **`mode` alone**. So `safe()` (cell) and
`portable()` (threaded) — **both `Safe`** — would derive the SAME atom and collide (the BEAM
loads one module per atom → the second load hot-replaces / clobbers the first). The keystone —
which already breaks `Binding` — **extends `coexist_name` to key the output atom on the full
build identity `(mode, state_strategy, mem_tier)`**, appending, in a fixed order, `_unsafe`
(Unsafe), `_threaded` (Threaded), and the tier suffix `_atomics`/`_nif` — so any two distinct
`.beam`s of one source get distinct atoms. The default posture (Safe / `Cell` / `Paged`) appends
**nothing**: the canonical `base` name is byte-identical to Phase-2/3 (conformance-neutral, G7).
Keying on `state_strategy`/`mem_tier` means `coexist_name` now takes the `Binding`; the Phase-3
coexistence callers (`coexistence_test`, `linker_coexist_test`, `profiles_test`) are updated in
place to the new signature and stay green (the default atom, and so every existing assertion, is
unchanged).

---

## Effect / soundness / security note

- **No ambient authority (D3a) survives both new axes.** The threaded seam still emits fixed
  `twocore@runtime@*` module atoms with literal function names; the tier is a build-controlled
  module swap; the threaded table closure is still a build-controlled capture of a
  compile-time-literal reference, and the only runtime-data input reaching a control transfer
  remains the integer `call_indirect` index. Unit 02 extends the structural security-invariant
  test to the threaded lowering.
- **Fail-closed defaults (D4).** `safe_default()` = `Cell`/`Paged`/`TablePaged` — the maximally
  node-safe posture. Leaving the tier-P `portable` or the tier-N `ceiling` posture requires
  NAMING it (unit 07); tier-N (`nif`) additionally requires Unsafe (§B.4).
- **Tier-N is the one native seam, gated (G6).** Bounds-checks hold in every tier (the §11
  security invariant); tiers P/O are memory-safe by construction; tier-N runs custom C, can
  crash the node, and is Safe-forbidden — its worst case is a node-safe process crash, never a
  host escape.
- **Threads / shared memory stay a hard non-goal (§12).** The threaded record is process-local
  (threaded through one process's call chain); `atomics`/`ets` are used **process-locally, never
  shared**. No memory tier is ever cross-process.
- **Floats-as-bits (D5) unchanged.** Globals stay raw-bit-pattern `Int`s in the record; memory
  is raw bytes over the IEEE bit pattern in every tier — never a BEAM-double round-trip.
- **Conformance-neutral (G7).** No IR node, no `TrapReason`, no grammar change — so this freeze
  changes no observable behaviour; the cell/paged default path is byte-identical.

---

## Verification (Definition of Done for unit 01)

- `gleam build` compiles with **zero warnings** — the only compiling change is three enums +
  three `Binding` fields + `safe_default()`, all real and total (no `todo`). The threaded/tier
  runtime signatures are frozen in this document (units implement them), so they add no code and
  no warnings here.
- `gleam format --check src test` clean; **`gleam test` stays green (674, conformance
  15747/411/0 under both profiles)** — `profiles.gleam` and every test `Binding(..)` spread
  compile unchanged (they absorb the new fields), and the cell/paged codegen is untouched.
- **The scratch freeze test** (`test/twocore/runtime/tier_freeze_test.gleam`, mirroring
  Phase-2's `ir2_freeze_test` / Phase-3's `opt_iface_freeze_test`) proves the frozen surface
  typechecks and upholds the contracts — spec assertions, not change-detectors (D8):
  - constructs a `Threaded` binding (`Binding(..profiles.safe(), state_strategy: Threaded)`)
    and an `Atomics` binding (`Binding(..profiles.safe(), mem_tier: Atomics)`) and asserts each
    typechecks — proving the axes express the Phase-4 surface before anyone builds on them.
  - asserts the **fail-closed defaults**: `profiles.safe().state_strategy == Cell`,
    `.mem_tier == Paged`, `.table_tier == TablePaged`; and that `unsafe()` inherits the same
    (the `ceiling`/`portable` overrides are unit 07's).
  - asserts **Safe+Nif is unconstructible through the profile API**: no `profiles.safe*`
    constructor yields `mem_tier == Nif` (enumerated over `safe()`/`safe_capped(_)`/
    `safe_metered(_)`/`safe_default()`), pinning the G6 fail-closed guarantee.
  - asserts the threaded box shape: an `InstanceState` value round-trips its three fields
    (mem/globals/table), pinning that the threaded record is the existing box.
  - asserts **coexistence keys on the full build identity** (§B.5, B3): `coexist_name` of the
    default `safe()` build is the canonical `base` (unchanged, conformance-neutral), while the
    `safe()` (cell) and `portable()` (threaded) builds of one source derive **distinct** atoms
    (both Safe, separated by the `_threaded` suffix), as do `safe()` vs an `Atomics` build —
    pinning that no two distinct `.beam`s of one source collide (BEAM one-module-per-atom).
- **Done = the freeze test + the full suite pass** (D8) — not "it compiles."
- Announce `«STATE-STRATEGY-FROZEN»` / `«MEM-TIER-FROZEN»` in `state.md` with the reach list.

---

## What this unit leaves

- **02** expands the `emit_core` seam to the threaded shape (§A.3): the uniform-threading rule,
  the record-returning `instantiate`, the G4 constant-space loop back-edge; extends the
  security-invariant test. Reads the frozen `state_strategy` + the tier-P signatures (03), not
  their bodies — the critical path, start it first.
- **03** fills the tier-P `rt_state` bodies **only** (`fresh`/`t_global_get`/`t_global_set` — the
  record + globals seam; NO pdict; does NOT import `rt_mem`/`rt_table`).
- **04** owns the paged `rt_mem.gleam` threaded wrappers (`t_load`/`t_store`/`t_size`/`t_grow`/
  `t_init_data` + `to_flat(mem: Dynamic)` + the public `Dynamic → Mem` coercion, owner-additive
  to the existing file) AND builds `rt_mem_atomics` (tier-O, O(1), `grow` pre-allocation) against
  §B.2; **05** builds `rt_mem_nif` (tier-N interface + FFI + Safe-forbidden + reference/skeleton,
  C impl may be deferred); **06** owns the paged `rt_table.gleam` threaded wrappers
  (`t_init_elem`/`t_call_indirect`, owner-additive) AND builds the `rt_table_ets`/
  `rt_table_atomics` tiers — all differentially tested vs the oracle (§B.3).
- **07** composes the profiles (`portable`/`ceiling`), maps tier → module, and implements +
  tests the `validate_binding` Safe-forbids-nif gate (§B.4).
- **08** selects `state_strategy`/`mem_tier` per profile in the pipeline + CLI, and threads the
  record through the run-ABI; **09** runs the tier differential + the constant-space-under-
  threaded proof (G4); **10** re-measures the honest benchmark with `atomics` (+ threaded); **11**
  proves every `(strategy × tier)` conformance-green + the runs-anywhere grep proof.
