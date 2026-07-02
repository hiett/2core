# Unit 01 — Interface Freeze (Phase-5 keystone)

> **One owner. The spine of the phase. On the critical path of everything.** Read
> [`00-overview.md`](00-overview.md) (H1–H8) first, then the Phase-1/2/3/4 overviews
> (D1–D10, E1–E8, F1–F8, G1–G8). Phase 5 is the **surface-completion** phase and the first
> since Phase 2 to **grow the IR** (H7). This unit freezes the **three** contracts the Phase-5
> swarm binds to — the **IR3 extension** (`«IR3-FROZEN»`: reference value types + the H2/H3
> `Expr` nodes + the `Module`/import/export/segment reshape + the memory-index & memory64 axes),
> the **extended runtime signatures** (`«RT3-SIG-FROZEN»`: the multi-region/reference/bulk
> `rt_state`/`rt_mem`/`rt_table`/`rt_host` heads, doc-frozen, conservative-sound, never `todo`),
> and the **non-function-import + `spectest` instantiation/link contract** (`«INSTANTIATE3»`) —
> and lands the IR extension **GREEN** (build compiles, `gleam test` passes, **zero warnings**)
> with defaults chosen so every Phase-1..4 module compiles **byte-identically** (H7).

The build is currently zero-warning with **906 passing tests** (conformance **15747 / 411 / 0**
under every shipped `(mode × state_strategy × mem_tier)` binding). **It must stay that way after
this unit.** Unlike the Phase-3/4 keystones (which added *no* IR node and *no* `TrapReason`, so
they had at most one structural reach), Phase 5 grows `ValType`, `Expr`, `Module`, `ImportDecl`,
`ExportDecl`, `TableDecl`, `ElementSegment`, `DataSegment`, and `MemoryDecl`. Because Gleam has
no default field values and every exhaustive `case` over these types must stay total, this is the
**broadest land-green reach the project has ever taken** — every constructor and every exhaustive
match across `ir`/`printer`/`parser`/`effect`/`emit_core`/`lower`/`ir_lower`/`ir_opt` and the
test corpus is touched. This unit enumerates **every one** (the table below is load-bearing —
treat it as the acceptance checklist, not a sketch), lands them all green with byte-identical
defaults, and **doc-freezes** the runtime signatures + the instantiation contract that units
02–10 implement — exactly the posture the Phase-4 keystone took (frozen in prose, no `todo`
stubs, so no new warnings).

---

## Context

Phases 1–4 built a correct, sandboxed, fast, runs-anywhere engine for a **partial** WASM surface:
WASM 1.0 + multi-value + sign-extension + non-trapping float→int, **one** 32-bit memory,
funcref-only **active** tables, active-only data/element segments, **function-only** imports. The
`ir.gleam` types encode exactly that partial surface — `Module.memory: Option(MemoryDecl)` (one
memory), `TableDecl(name, min, max)` (no reftype tag), `ElementSegment(table, offset, funcs)`
(funcref names, active only), `DataSegment(offset, bytes)` (active only), `ImportFn`/`ExportFn`
only, and memory nodes with no memory index. Phase 5 completes the standardized surface (minus
SIMD): first-class **references**, **bulk memory & table ops**, **multiple** and **64-bit**
memories, **non-function imports + `spectest`**, and a WAT parser. All of that begins here, in the
IR shapes and runtime signatures the rest of the phase is written against.

The provisional surface (the EM's draft in `scratchpad/provisional-surface.md`) proposed the exact
names and shapes; **this unit adopts them nearly verbatim** — the one deliberate addition is the
`ConstNull` `Value` constructor (§A.4), which the provisional explicitly left for the keystone to
decide. Everything else keeps the provisional names so the 11 sibling units compose.

## Goal

Freeze `«IR3-FROZEN»` / `«RT3-SIG-FROZEN»` / `«INSTANTIATE3»`, land the IR extension green and
byte-identical, and prove the default-neutrality claim: a module with one 32-bit memory,
funcref-only **active** elements, function-only imports, and no bulk/ref ops emits **byte-identical
`.core`** to Phase-4, under both state strategies and every shipped memory tier. Nothing in the
Phase-1..4 acceptance corpus or the previously-passing spec suite may move by one atom.

## Files owned (single-owner / additive per D1)

| File | Ownership | This unit's change |
|---|---|---|
| `src/twocore/ir.gleam` | **owner-additive** | The whole IR3 surface: `RefType`; `ValType` reftypes; `ConstNull`; the H2/H3 `Expr` nodes; the `mem: Int` field on `MemSize`/`MemGrow`/`MemLoad`/`MemStore`; `IdxType`; `Module.memories`; `MemoryDecl.idx_type`; `TableDecl.ref_ty`; the reshaped `ElementSegment`/`DataSegment`; the `ImportDecl`/`ExportDecl` state variants; `TrapReason` (reuse — no new variant, §D). |
| `src/twocore/ir/effect.gleam` | **owner-additive** | Classify **every** new `Expr` node as a **barrier** (`Effectful`); update the memory-node arms for their new field shape. Real classification, not stub (§E). |
| `src/twocore/runtime/instance.gleam` | **owner-additive** | The `ImportMap`/`ProvidedImport` **types** for `«INSTANTIATE3»` (doc-frozen vocabulary, no bodies); doc updates. No `Binding` field is required (§H). |
| `src/twocore/ir/printer.gleam` | **land-green reach** (full impl → P5-02) | Minimal compile-satisfying arms for the new nodes/shapes so `.ir` printing stays total. |
| `src/twocore/ir/parser.gleam` | **land-green reach** (full impl → P5-02) | Minimal compile-satisfying arms; the `ModuleAcc`/`Module` construction updated to `memories`. |
| `src/twocore/backend/emit_core.gleam` | **land-green reach** (full impl → P5-06) | Compile-satisfying arms: `module.memory` → `module.memories`; the memory nodes' new field; a fail-`Result` arm for each new node (byte-identical single-memory output preserved). §I. |

**Seam-doc only (frozen in this doc, implemented by the named unit):** `rt_state.gleam` /
`rt_mem.gleam` / `rt_table.gleam` / `rt_host.gleam` extended signatures (§G — units 07/08/09);
`profiles.gleam`/`pipeline.gleam` link contract (§H — unit 09); the `.ir` grammar delta (§F —
unit 02); the `frontend/wasm/ast.gleam` `«WASM-AST3»` (unit 03). This unit does **not** claim
those files.

## Deliverables & freeze milestones

1. **`«IR3-FROZEN»`** — `ir.gleam` (all of §A–§D) + `ir/effect.gleam` (§E) landed green +
   byte-identical defaults; the `.ir` grammar delta **sketched** here (§F, owned + reconciled by
   P5-02). Unblocks **02, 03, 04, 05, 06, 07, 08, 09, 10**.
2. **`«RT3-SIG-FROZEN»`** — the extended `rt_state`/`rt_mem`/`rt_table`/`rt_host` public heads
   (§G), doc-frozen and conservative-sound (never `todo`), so 07/08/09 implement bodies without
   racing signatures. Unblocks **07, 08, 09**.
3. **`«INSTANTIATE3»`** — the non-function-import + `spectest` instantiation/link contract (§H):
   the `ImportMap` shape, the fail-closed unsatisfied-import rule (H6), the build-fixed `spectest`
   registry, and the `(register …)` substrate. Unblocks **09** (and **10**'s script layer).

**Out of scope for this unit:** any decode/validate/lower logic (03/04/05); the real
ref/table/bulk codegen (06); the runtime bodies (07/08/09); the WAT parser (10). This unit ships
the IR3 types (real, total, zero `todo`) + the frozen runtime signatures + the land-green reach +
a scratch freeze test.

## Depends on (freeze milestones)

None upstream — this is Wave-0, the keystone. It consumes the Phase-4 `Binding`/`InstanceState`
shapes (already green) and freezes on top of them.

---

## Land-green cross-file reaches (enumerate EVERY one)

Growing `ValType`/`Expr`/`Module` (and the five declaration/segment types) breaks every exhaustive
`case` and every full constructor that mentions them. Each row **must** be landed for the tree to
stay green; the "full impl" column names the unit that later replaces a minimal arm with the real
one. `..spread` constructors absorb *added* fields automatically; **positional** constructors and
**exhaustive matches** do not.

| # | File | What breaks | Land-green edit (this unit) | Full impl |
|---|---|---|---|---|
| 1 | `ir.gleam` | owner-additive | Add everything in §A–§D. `TrapReason` unchanged (§D). | — |
| 2 | `ir/effect.gleam` | `is_effectful_node` exhaustive `case`; the memory-node arms | Add a `True` arm for **every** new node (§E); update `MemSize`/`MemGrow(..)`/`MemLoad(..)`/`MemStore(..)` to the new field shape. Real classification. | — (this unit) |
| 3 | `ir/printer.gleam` | `print_expr` exhaustive `case`; `memory_str` (reads `module.memory`); `print_table`/`print_elem`/`print_data`/`print_import`/`print_export`; `print_valtype` | Minimal arms for the new nodes; `module.memory` → `module.memories`; reshape the decl printers; reftype arms in `print_valtype`. Byte-identical for existing surface. | **P5-02** |
| 4 | `ir/parser.gleam` | `parse_expr` dispatch; `ModuleAcc.memory` + the `Module(...)` construction; `parse_memory`/`parse_table`/`parse_element`/`parse_data`/`parse_import`/`parse_export`; `parse_valtype` | `ModuleAcc.memories` + list-append; minimal arms for the new mnemonics; reshape the decl parsers to construct the new shapes with defaults. | **P5-02** |
| 5 | `backend/emit_core.gleam` | `emit_expr` dispatch (`MemSize`/`MemGrow`/`MemLoad`/`MemStore` arms); `state_reaching_body`/`is_stateful_node`; `collect_value` over the mem nodes; `state_decl_term` (`module.memory`, `module.tables`); `element_segment_effects` (`seg.funcs`, `seg.offset`); `data_segment_effects` (`seg.offset`); `print_valtype`/`valtype_width` | `module.memory` → head of `module.memories`; thread the (ignored, =0) `mem` field; **one `Error(Unsupported(node))` arm per new node** (§I); reshape the element/data effect builders to the new `ElemMode`/`DataMode` (active-index-0 path byte-identical). Add `EmitError.Unsupported` (single-file). | **P5-06** |
| 6 | `frontend/wasm/lower.gleam` | constructs `ir.Module(...)`, `ir.MemLoad/MemStore/MemSize/MemGrow`, `ir.TableDecl`, `ir.ElementSegment`, `ir.DataSegment`, `ir.MemoryDecl`, `ir.ExportFn`; `default_value` `case` over `ValType` | Construct the new shapes with defaults (`Idx32`, `FuncRef`, `ElemActive`, `DataActive(0, _)`, `mem: 0`); add reftype arms to `default_value`. This unit makes it **compile & byte-identical**; P5-05 fills the real new-op lowering. | **P5-05** |
| 7 | `middle/ir_lower.gleam` | the barrier `case` enumerating `MemSize`/`MemGrow(_)`/`MemLoad(_,_,_,_)`/`MemStore(_,_,_,_)` | Update those arms to the new field shape; new nodes fall to the existing recursion/catch-all (they are barriers, treated conservatively). | — (this unit) |
| 8 | `middle/ir_opt/pass.gleam` | the `rebuild` `case` enumerating the barrier memory nodes | Update the memory-node arms to the new shape; add pass-through arms for the new nodes (they carry `Value` operands the pass may rewrite — this unit gives a **structurally-recursive** arm so copy/const-prop reaches their operands; §E note). | — (this unit) |
| 9 | `middle/ir_opt/baseline.gleam` | `_ -> e` catch-alls | Compiles unchanged for new nodes; verify no arm names a reshaped memory node positionally. | — |
| 10 | Test corpus | every **positional** `ir.Module(...)`, `ir.MemLoad(...)`, `ir.MemSize`, `ir.MemGrow(...)`, `ir.TableDecl(...)`, `ir.ElementSegment(...)`, `ir.DataSegment(...)`, `ir.MemoryDecl(...)` | Mechanically update to the new field lists/defaults so the suite stays green (19 files build `ir.Module` positionally). This unit owns the land-green edit; the owning unit re-asserts behaviour. | mixed |

**The three shape changes that break positional constructors everywhere** (call them out — they
are the bulk of the diff):
- **`Module.memory: Option(MemoryDecl)` → `memories: List(MemoryDecl)`** (single-memory ⇒ a
  0-or-1-element list) breaks every full `ir.Module(...)`, `printer.memory_str`,
  `parser.ModuleAcc`, `emit_core.state_decl_term`, and `lower.lower_memory`.
- **`MemSize` → `MemSize(mem: Int)`**, **`MemGrow(delta)` → `MemGrow(mem, delta)`**,
  **`MemLoad(op, addr, offset, result)` → `MemLoad(mem, op, addr, offset, result)`**,
  **`MemStore(op, addr, value, offset)` → `MemStore(mem, op, addr, value, offset)`** (`mem`
  **first**, default `0`) breaks every constructor and match of the four memory nodes.
- **`TableDecl`/`ElementSegment`/`DataSegment`/`MemoryDecl`/`ImportDecl`/`ExportDecl`** reshape
  (§B) breaks their positional constructors in `lower`, `printer`, `parser`, `emit_core`, tests.

Announce all three milestones in `state.md` with this reach list, exactly as the Phase-2/3/4
keystones did.

---

## A. `«IR3-FROZEN»` — the reference value model (H1)

### A.1 `ValType` gains two reference constructors; a `RefType` sub-type names them

```gleam
pub type ValType {
  TI32
  TI64
  TF32
  TF64
  TTerm
  /// A function reference (`funcref`). A runtime value is the null sentinel OR the Phase-2
  /// type-tagged table entry `#(FuncType, target)` — a `funcref` value *is* what a table slot
  /// already holds, promoted to a first-class value (H1). Produced by `RefFunc`, consumed by
  /// `CallIndirect` / a future `call_ref`, stored in `funcref` tables.
  TFuncRef
  /// An opaque host reference (`externref`). A runtime value is the null sentinel OR any BEAM
  /// term the host supplies. Safe code may hold/pass/store/null-test it but **cannot forge or
  /// inspect** it (opacity is the security property, H6). Never callable.
  TExternRef
}

/// The subset of `ValType` that is a reference type. Used wherever the spec's `reftype`
/// grammar appears: `TableDecl.ref_ty`, `ElementSegment.ref_ty`, `RefNull(ty)`, the reftype of
/// an imported table, and typed `select` (validate/decode only). `FuncRef`/`ExternRef` map 1:1
/// onto `TFuncRef`/`TExternRef`; `to_valtype`/`of_valtype` (below) bridge them.
pub type RefType {
  FuncRef
  ExternRef
}
```

Two total helpers keep the two spellings from drifting (analogue of `signature/1`):

```gleam
/// Widen a `RefType` to its `ValType` (`FuncRef → TFuncRef`, `ExternRef → TExternRef`). Total.
pub fn reftype_to_valtype(r: RefType) -> ValType
/// Narrow a `ValType` to a `RefType` iff it is a reference type; `Ok`/`Error(Nil)` otherwise.
pub fn valtype_to_reftype(t: ValType) -> Result(RefType, Nil)
```

Spec anchor: reference types add `funcref`/`externref` to `reftype ⊆ valtype`
([spec §2.3.3, the reference-types living standard / WASM 2.0](https://webassembly.github.io/spec/core/syntax/types.html#reference-types)).
`funcref` = binary `0x70`, `externref` = `0x6F` (the exact bytes are P5-03's decode freeze; cited
here only as the surface these constructors model).

### A.2 The null-reference runtime representation (the load-bearing decision)

**Decision — the null sentinel is the Core Erlang atom `'$null'`.** A reference value at runtime is:

| Reference | Non-null runtime value | Null runtime value |
|---|---|---|
| `funcref` | the Phase-2 type-tagged entry `#(FuncType, closure)` (a **2-tuple**) | the atom `'$null'` |
| `externref` | an opaque BEAM term the host supplied | the atom `'$null'` |

- **One sentinel, shared by both reftypes.** WASM's `ref.null t` is typed, but at runtime a null is
  a single distinguished value — `ref.is_null` is the same test for either type. The static type
  keeps `funcref`-null and `externref`-null apart where it matters (validation); the runtime needs
  only one sentinel. `ref.is_null(x)` lowers to the equality test `x =:= '$null'`.
- **Distinguishability (the soundness obligation).** A real `funcref` is a 2-tuple, never the atom.
  A real `externref` is an arbitrary host term — so in principle a host could hand back the atom
  `'$null'`. Two facts close this: (1) the only producers of `externref` values are **build-fixed**
  — the `spectest` registry and the (build-controlled) host boundary (§H) — and neither yields the
  sentinel; (2) Safe code **cannot** construct the atom (no IR op produces `'$null'` except the
  typed `RefNull`/`ConstNull`, §A.4). This is documented as an instance-state invariant on the
  host provider. **Open question (§Open):** if the reconcile pass wants a *bulletproof* externref
  that cannot collide even with an adversarial host, wrap it as `#(externref, Term)` (a 2-tuple
  tag, never `'$null'`) at a one-box-per-externref cost. Recommendation: ship the atom sentinel +
  the documented host invariant (cheapest, and the host is build-fixed), reconsider wrapping only
  if a real host provider ever needs to forward an untrusted `externref`.
- **Term-layer, not numeric.** References flow as `Dynamic` (BEAM terms), on the **term** path of
  the dual-value model — never as raw-bit `Int`s (D5). This is why a future JS/Gleam frontend can
  map its first-class functions / host objects onto `funcref`/`externref` (H7): the representation
  is a generic tagged term, not a WASM-ism.

### A.3 `ConstNull` — a null-reference `Value` literal (keystone confirms: **yes**)

The provisional left open "whether a `ConstNull` `Value` is warranted." **It is.** A reference-typed
**operand** (a `Value` position) needs a null literal in three places where a mandatory
`Let`-binding would be clumsy or where a *constant* is required:

```gleam
pub type Value {
  Var(name: String)
  ConstI32(bits: Int)
  ConstI64(bits: Int)
  ConstF32(bits: Int)
  ConstF64(bits: Int)
  /// The null-reference literal — the single runtime null sentinel (§A.2) as an atomic operand.
  /// UNTYPED at runtime (one sentinel for both reftypes); the surrounding node/validation carries
  /// the static reftype. It is the operand `RefNull(ty)` reduces to, the default `init` of
  /// `table.grow`/`table.fill` when the source is `ref.null`, and the value a reference-typed
  /// global/element **constant initialiser** const-folds to. Pure (it is a `Value`).
  ConstNull
}
```

`RefNull(ty)` (§C) stays an `Expr` (it carries the reftype for the `.ir` text and for validation)
and is the *typed producer*; it is semantically `Values([ConstNull])`. Keeping both lets `lower`
emit whichever is convenient and lets `emit_core`'s **constant folder** reduce a ref-typed global
init to a literal `ConstNull` **without** widening `const_fold`'s `Int` return (a funcref constant,
`ref.func $f`, is *not* a literal — it stays a `RefFunc` `Expr` resolved to a closure at
instantiation; only *null* is a literal). This is the one deliberate divergence from the
provisional (which said "likely no new `Value` constructor"); the rationale is the ref-typed
const-init path.

Spec anchor: `ref.null` is a **constant instruction** admissible in the constant-expression grammar
for globals and element segments
([spec §3.3.10 / §4.4.9 constant expressions](https://webassembly.github.io/spec/core/valid/instructions.html#constant-expressions)).

---

## B. `«IR3-FROZEN»` — the `Module`, declaration, segment, import & export reshape (H3/H4)

### B.1 Multi-memory & memory64: `Module.memories`, the memory index, `IdxType`

```gleam
pub type Module {
  Module(
    name: String,
    uses_numerics: Bool,
    memories: List(MemoryDecl),   // CHANGED: was `memory: Option(MemoryDecl)` (multi-memory, H3)
    globals: List(GlobalDecl),
    imports: List(ImportDecl),
    functions: List(Function),
    exports: List(ExportDecl),
    data_segments: List(DataSegment),
    tables: List(TableDecl),
    elements: List(ElementSegment),
    start: Option(String),
  )
}

/// A memory's address width (H3, memory64). `Idx32` is the classic 32-bit-indexed memory
/// (address operand `i32`, bounds arithmetic 32-bit); `Idx64` is a 64-bit-indexed memory
/// (address operand `i64`, offsets may exceed 2³²). Neutral name (a generic multi-region address
/// width, not a WASM immediate leaked into the IR, H7).
pub type IdxType {
  Idx32
  Idx64
}

pub type MemoryDecl {
  MemoryDecl(min_pages: Int, max_pages: Option(Int), idx_type: IdxType)   // idx_type NEW; default Idx32
}
```

- **`memories: List`** — a single-memory module is `[MemoryDecl(min, max, Idx32)]`; a
  numerics-only module is `[]`. Index `0` is the default memory that every Phase-1..4 memory node
  targets. The list order **is** the memory-index space.
- Every memory-touching node carries a `mem: Int` **static immediate** (§C) — the region index,
  **not** a runtime handle (the tier-agnostic rule from Phase-4 G5 holds: a memory index is a
  compile-time integer the seam routes on, never a value that flows through the IR).
- **memory64 is the deferrable half (H8).** The `IdxType` axis is frozen *now* (so the shape is
  stable and 32-bit is byte-identical), but P5-08 may honestly defer the `Idx64` *runtime* to
  Phase 6. Freezing the type costs nothing and keeps every 32-bit path unchanged.

Spec anchor: multi-memory ([multi-memory proposal, folded into the living standard] — memory
instructions gain a memory-index immediate; the reserved `0x00` byte becomes a real memidx). The
memory64 index-type flag rides the limits' flags byte
([spec §5.3.7 limits / the memory64 proposal](https://webassembly.github.io/spec/core/binary/types.html#limits)).

### B.2 Tables gain a reference-type tag

```gleam
pub type TableDecl {
  TableDecl(name: String, ref_ty: RefType, min: Int, max: Option(Int))   // ref_ty NEW; default FuncRef
}
```

A `funcref` table (`ref_ty: FuncRef`) is the Phase-2 table, byte-identical. An `externref` table
(`ref_ty: ExternRef`) stores opaque host references. Multiple tables are already supported by name
(`CallIndirect(table, …)` / `ElementSegment` reference tables by name); Phase 5 only adds the
reftype tag and the reference table/bulk ops (§C).

### B.3 Element segments — active | passive | declarative, ref-expression items

```gleam
/// An element segment. GENERALIZES the Phase-2 `ElementSegment(table, offset, funcs)`:
/// - `mode`: active (writes a table at instantiation) | passive (a droppable runtime segment
///   consumed by `table.init`) | declarative (forward-declares funcrefs; carries no runtime data).
/// - `ref_ty`: the element reference type (`FuncRef`/`ExternRef`).
/// - `init`: the element items, each a **ref-producing constant expression** — `RefFunc(name)`
///   (a funcref) or `RefNull(ty)` (a null). This replaces `funcs: List(String)` and is what lets
///   an element carry `externref`s and null slots (H1/H2). An active `FuncRef` segment whose
///   items are all `RefFunc` is the Phase-2 case, lowered identically.
pub type ElementSegment {
  ElementSegment(mode: ElemMode, ref_ty: RefType, init: List(Expr))
}

pub type ElemMode {
  ElemActive(table: String, offset: Expr)   // Phase-2 case (byte-identical when FuncRef + RefFunc items)
  ElemPassive                                // droppable; consumed by `table.init`; `elem.drop` empties it
  ElemDeclarative                            // no runtime state; makes `ref.func` targets valid
}
```

**Element items are `init: List(Expr)` of ref exprs — not `funcs: List(String)`.** This is the
deliberate generalization (the provisional's recommendation, adopted): the funcref-name list cannot
express `externref` elements, null slots, or the expression encoding the spec's element section
uses. The active-funcref-all-`RefFunc` case lowers exactly as Phase-2 did (each `RefFunc(name)` →
the build-controlled type-tagged closure), so conformance is neutral.

Spec anchor: element segments have **active / passive / declarative** modes and an **element kind /
expression** encoding ([spec §2.5.6 / §5.5.12 element section](https://webassembly.github.io/spec/core/binary/modules.html#element-section)).
`elem.drop` empties a passive segment; `table.init` from a dropped segment with non-zero length
traps ([spec §4.4.9 table.init/elem.drop](https://webassembly.github.io/spec/core/exec/instructions.html#xref-syntax-instructions-syntax-instr-table-mathsf-table-init-x-y)).

### B.4 Data segments — active(mem, offset) | passive

```gleam
pub type DataSegment {
  DataSegment(mode: DataMode, bytes: BitArray)   // was: DataSegment(offset, bytes)
}
pub type DataMode {
  DataActive(mem: Int, offset: Expr)   // `mem` index NEW (default 0); Phase-2 case is DataActive(0, off)
  DataPassive                          // droppable; consumed by `memory.init`; `data.drop` empties it
}
```

A Phase-2 active data segment is `DataSegment(DataActive(0, off), bytes)` — byte-identical. Passive
data is a droppable runtime value (§G) consumed by `memory.init`.

Spec anchor: data segments have **active(memidx, offset) / passive** forms
([spec §2.5.7 / §5.5.14 data section](https://webassembly.github.io/spec/core/binary/modules.html#data-section)).

### B.5 Non-function imports & exports (H4)

```gleam
pub type ImportDecl {
  ImportFn(capability: String, name: String, ty: FuncType)                                  // existing
  ImportGlobal(module: String, name: String, ty: ValType, mutable: Bool)                    // NEW
  ImportTable(module: String, name: String, ref_ty: RefType, min: Int, max: Option(Int))    // NEW
  ImportMemory(module: String, name: String, min_pages: Int, max_pages: Option(Int), idx_type: IdxType)  // NEW
}

pub type ExportDecl {
  ExportFn(export_name: String, fn_name: String)          // existing
  ExportGlobal(export_name: String, global_name: String)  // NEW
  ExportTable(export_name: String, table_name: String)    // NEW
  ExportMemory(export_name: String, mem_index: Int)        // NEW
}
```

- **`ImportFn` is unchanged** — it is *the capability boundary* (`CallHost`, deny-all). Its
  `capability`/`name` shape is intentionally different from the state imports' `module`/`name`
  (which are a WASM `(module, name)` **link** key, not a capability tag) — see §H for why they must
  not be conflated.
- **State imports are provided state, not capabilities** (H4). `ImportGlobal`/`ImportTable`/
  `ImportMemory` name a value the instantiation contract **supplies**; an unsatisfied one is a
  **link-time failure** (fail-closed), never an ambient default (§H).
- **`ExportGlobal`/`ExportTable`/`ExportMemory`** exist because the suite's `(get $m "g")` and
  `spectest`'s exported `table`/`memory` need them. `ExportMemory` names the memory by **index**
  (its position in `memories`); `ExportGlobal`/`ExportTable` name by the IR name (consistent with
  `ExportFn`).

Spec anchor: import/export `externtype` covers `func | table | mem | global`
([spec §2.5.10 / §2.5.11 imports & exports](https://webassembly.github.io/spec/core/syntax/modules.html#imports)).

---

## C. `«IR3-FROZEN»` — the new `Expr` nodes (H2/H3)

All new nodes are **effectful** (barriers — §E). Existing memory nodes gain `mem: Int` (first
field, default `0`). Added to the `Expr` type:

```gleam
// ── references (H1/H2) ─────────────────────────────────────────────────────────
/// `ref.null t` → the null reference of reftype `ty`. Yields the null sentinel (§A.2).
/// Semantically `Values([ConstNull])`; kept as a typed producer for the `.ir` text + validation.
RefNull(ty: RefType)
/// `ref.func $f` → a `funcref` to same-module function `fn_name` (the build-controlled
/// type-tagged closure `#(FuncType, closure)`). Effectful in the barrier sense only (it
/// materialises instance-linked state); never traps. `fn_name` must be a defined function.
RefFunc(fn_name: String)
/// `ref.is_null x` → i32 `1` if `x` is the null sentinel, else `0`. Lowers to `x =:= '$null'`.
RefIsNull(arg: Value)

// ── tables (H2) ────────────────────────────────────────────────────────────────
/// `table.get` → the reference at `index` in `table`; **traps `TableOutOfBounds`** if `index ≥ size`.
TableGet(table: String, index: Value)
/// `table.set` — write `value` (a reference) at `index`; **traps `TableOutOfBounds`** if OOB.
TableSet(table: String, index: Value, value: Value)
/// `table.size` → the table's current size in entries (i32).
TableSize(table: String)
/// `table.grow(delta, init)` → the PREVIOUS size, or `-1` if growth fails (exceeds `max`/cap).
/// New slots are filled with `init` (a reference). Never traps.
TableGrow(table: String, delta: Value, init: Value)
/// `table.fill(offset, value, count)` — write `value` into `count` slots from `offset`.
/// **Eager bounds check → traps `TableOutOfBounds` before any write** if `offset+count > size`.
TableFill(table: String, offset: Value, value: Value, count: Value)
/// `table.init(seg, dst, src, count)` — copy `count` elements from passive element `seg`
/// (index into `Module.elements`) at `src` into `table` at `dst`. **Eager bounds; trap before
/// any write** on OOB (either range) or a dropped/short segment.
TableInit(table: String, seg: Int, dst: Value, src: Value, count: Value)
/// `table.copy(dst, src, count)` between two tables — **memmove semantics** (overlap-correct in
/// either direction). **Eager bounds; trap before any write.**
TableCopy(dst_table: String, src_table: String, dst: Value, src: Value, count: Value)
/// `elem.drop(seg)` — mark passive element segment `seg` empty (length 0). Idempotent; a later
/// `table.init` from it with non-zero `count` traps.
ElemDrop(seg: Int)

// ── bulk memory (H2/H3) — a memory index on all ────────────────────────────────
/// `memory.fill(dest, value, count)` on memory `mem` — set `count` bytes from `dest` to the low
/// byte of `value`. **Eager bounds; trap `MemoryOutOfBounds` before any write.**
MemFill(mem: Int, dest: Value, value: Value, count: Value)
/// `memory.copy` from `src_mem` to `dst_mem` — **memmove semantics**. **Eager bounds; trap before
/// any write.** (Multi-memory: source and destination memories may differ.)
MemCopy(dst_mem: Int, src_mem: Int, dst: Value, src: Value, count: Value)
/// `memory.init(seg, dst, src, count)` on memory `mem` — copy `count` bytes from passive data
/// `seg` (index into `Module.data_segments`) at `src` into memory at `dst`. **Eager bounds; trap
/// before any write** on OOB or a dropped/short segment.
MemInit(mem: Int, seg: Int, dst: Value, src: Value, count: Value)
/// `data.drop(seg)` — mark passive data segment `seg` empty. Idempotent.
DataDrop(seg: Int)

// ── existing memory nodes — ADD `mem: Int` (first field, default 0) ────────────
MemSize(mem: Int)                                              // was: MemSize
MemGrow(mem: Int, delta: Value)                                // was: MemGrow(delta)
MemLoad(mem: Int, op: MemAccess, addr: Value, offset: Int, result: ValType)   // was: no mem
MemStore(mem: Int, op: MemAccess, addr: Value, value: Value, offset: Int)     // was: no mem
```

**Typed `select` (`select_t`) → no new node.** Per H2, a typed `select` lowers to the existing
`If`/value-merge — it is a decode/validate concern only (it can carry a reference type, which is
why the spec adds it, but the *lowering* is the untyped `select` shape the IR already expresses).
No IR change; flagged so P5-04/05 do not add a node.

### C.1 Per-op semantics table (held to the spec, not the implementation)

| Node | Result | Trap (spec) | Overlap | Eager? |
|---|---|---|---|---|
| `RefNull(ty)` | null sentinel | — | — | — |
| `RefFunc(f)` | `#(FuncType, closure)` | — | — | — |
| `RefIsNull(x)` | i32 `0/1` | — | — | — |
| `TableGet(t,i)` | reference | `TableOutOfBounds` if `i ≥ size` | — | — |
| `TableSet(t,i,v)` | — | `TableOutOfBounds` if `i ≥ size` | — | — |
| `TableSize(t)` | i32 size | — | — | — |
| `TableGrow(t,δ,init)` | prev size or `-1` | — (never traps) | — | — |
| `TableFill(t,o,v,n)` | — | `TableOutOfBounds` if `o+n > size` | — | **yes** (no partial write) |
| `TableInit(t,s,d,sr,n)` | — | `TableOutOfBounds` if `d+n > tsize` **or** `sr+n > seglen` | — | **yes** |
| `TableCopy(dt,st,d,sr,n)` | — | `TableOutOfBounds` if either range OOB | **memmove** | **yes** |
| `ElemDrop(s)` | — | — (idempotent) | — | — |
| `MemFill(m,d,v,n)` | — | `MemoryOutOfBounds` if `d+n > bytelen` | — | **yes** |
| `MemCopy(dm,sm,d,sr,n)` | — | `MemoryOutOfBounds` if either range OOB | **memmove** | **yes** |
| `MemInit(m,s,d,sr,n)` | — | `MemoryOutOfBounds` if `d+n > bytelen` **or** `sr+n > seglen` | — | **yes** |
| `DataDrop(s)` | — | — (idempotent) | — | — |
| `CallIndirect` through a **null** slot | — | `UninitializedElement` (§D) | — | — |

Two semantics rules the runtime signatures (§G) must honour, matching the finalized bulk-memory
proposal:
- **Overlap-correct copy (memmove).** `memory.copy`/`table.copy` are correct for overlapping ranges
  in **either** direction (copy forward if `dst ≤ src`, backward otherwise) — the runtime must not
  naively copy low-to-high.
- **Eager bounds → trap before any write.** Every bulk op checks the *whole* range first and
  traps with **no partial effect**, matching the existing `rt_mem` trap-before-write invariant. A
  **zero-length** bulk op at an out-of-range (even `== size`) index is a **no-op that does not
  trap**, *except* `memory.init`/`table.init` also validate the segment offset; a **dropped**
  segment behaves as a **length-0** segment (init of `count == 0` is fine, `count > 0` traps).

Spec anchors: bulk memory/table execution and the eager-bounds-then-trap rule
([spec §4.4.8 memory instructions](https://webassembly.github.io/spec/core/exec/instructions.html#memory-instructions),
[§4.4.9 table instructions](https://webassembly.github.io/spec/core/exec/instructions.html#table-instructions)); overlap correctness is the
`memory.copy`/`table.copy` reduction rules. `table.grow` returns previous size or `-1`
([spec §4.4.9 table.grow](https://webassembly.github.io/spec/core/exec/instructions.html#xref-syntax-instructions-syntax-instr-table-mathsf-table-grow-x)).

Binary opcodes this surface models (P5-03 owns the exact-byte freeze; listed for the reviewer):
`ref.null 0xD0`, `ref.is_null 0xD1`, `ref.func 0xD2`; `table.get 0x25`, `table.set 0x26`; the
`0xFC`-prefixed ops `memory.init 0xFC 8`, `data.drop 0xFC 9`, `memory.copy 0xFC 10`,
`memory.fill 0xFC 11`, `table.init 0xFC 12`, `elem.drop 0xFC 13`, `table.copy 0xFC 14`,
`table.grow 0xFC 15`, `table.size 0xFC 16`, `table.fill 0xFC 17`; typed `select 0x1C`. **If any of
these bytes is wrong it is P5-03's to correct** — they are not part of `«IR3-FROZEN»` (the IR is
opcode-neutral, D6); flagged as an open question rather than asserted authoritatively.

---

## D. `«IR3-FROZEN»` — `TrapReason` (reuse — **no new variant**, H6)

Every new failure maps onto an existing `TrapReason` — the keystone adds **zero** variants,
justified per H1/H6 (prefer reuse; a wrong/missing trap is the worst case, never a host escape):

| Failure | `TrapReason` (existing) | `spec_trap_message` (existing) |
|---|---|---|
| null `funcref` used as a value / null `call_indirect` slot | `UninitializedElement` | "uninitialized element" |
| `table.get`/`table.set`/`table.fill`/`table.init`/`table.copy` range OOB | `TableOutOfBounds` | "out of bounds table access" |
| `memory.fill`/`memory.copy`/`memory.init` range OOB | `MemoryOutOfBounds` | "out of bounds memory access" |
| `call_indirect` type mismatch | `IndirectCallTypeMismatch` | "indirect call type mismatch" |
| `table.init`/`memory.init` from a dropped/short passive segment (`count > 0`) | `TableOutOfBounds` / `MemoryOutOfBounds` | (as above) |

A **dropped** segment is a length-0 segment, so `*.init` past its end is exactly the OOB case —
no distinct "segment dropped" reason is needed (the spec itself unifies them: a dropped segment's
length is `0`). memory64 out-of-bounds is still `MemoryOutOfBounds` (the reason is address-width
agnostic). Because `TrapReason` is **unchanged**, the exhaustive `spec_trap_message` /
printer / parser `TrapReason` matches are **untouched** — one fewer reach than every prior
IR-growing keystone. (If the reconcile pass finds a `.wast` assertion that distinguishes a message
this table cannot produce, add **exactly one** variant with its `spec_trap_message`; flagged in
§Open.)

Spec anchor: the trap set ([spec §4.4 / Appendix — traps](https://webassembly.github.io/spec/core/exec/runtime.html#results)); the exact `assert_trap`
message strings are the spec-suite text the harness matches.

---

## E. `«IR3-FROZEN»` — effect classification of the new nodes (owner: this unit, real not stub)

`ir/effect.gleam` is the optimizer's soundness floor (E6/F3): anything not *proven* pure defaults
to `Effectful`. **Every new node is a barrier.** The keystone adds them to `is_effectful_node`'s
exhaustive `case` with a `True` verdict — real classification, landed here (the classifier is
keystone-owned in Phase 5):

- **All bulk/table/memory ops** read and/or **write** mutable instance state → barriers (no CSE,
  no reorder, no DCE across them), exactly like the Phase-2 `MemStore`/`GlobalSet`.
- **`RefFunc`** materialises instance-linked state (the closure over a generated function) → barrier
  (conservative; it is idempotent but treating it as a barrier costs only a missed optimization,
  which is the safe direction).
- **`RefNull`** and **`RefIsNull`** are pure *in principle* (a null literal / a tag test), but
  `RefNull` is `Values([ConstNull])`-equivalent and `RefIsNull(v)` is a pure test over a `Value` —
  these **may** be classified `Pure`. **Decision (conservative default):** classify `RefNull` and
  `RefIsNull` as **barriers too** for the freeze (the maximally-conservative posture the keystone
  ships), and leave the *narrowing* of these two to `Pure` as an explicit, tested refinement P5-05/
  the optimizer may make later — mirroring how P3-02 refined the keystone's broad `Num`/`Convert`
  classification. This is *strictly* the safe direction (never narrows anything unsound) and keeps
  the freeze trivially correct. (`ConstNull` is a `Value`, so it never reaches `classify` — Values
  are pure by construction.)

The memory-node arms (`MemSize`/`MemGrow`/`MemLoad`/`MemStore`) are updated for their new field
shape but keep their `True` verdict. Because the classifier's `case` is exhaustive, **omitting any
new node fails to compile** (fail-closed, D4) — an unclassified node can never be silently
optimized.

**`ir_opt/pass.gleam` recursion note (reach #8).** `pass.gleam`'s generic `rebuild` must give the
new nodes a **structurally-recursive** arm (rewriting the `Value` operands / sub-`Expr`s) so
copy/const-propagation reaches into them; a bare pass-through would silently *not* substitute into
a `TableFill`'s operands. This is a land-green arm the keystone writes (it is mechanical — map the
rewrite over each `Value`/`Expr` field); the optimizer's *soundness* is still guarded by §E (the
nodes are barriers, so nothing is hoisted across them).

---

## F. `«IR3-FROZEN»` — the `.ir` grammar delta (sketch; owned + reconciled by P5-02)

Full spelling + round-trip is **P5-02**'s (as IR2 was). Sketched here so P5-02 and the printer/
parser land-green arms agree:

```
; value types
reftype     ::= "funcref" | "externref"
valtype     ::= "i32" | "i64" | "f32" | "f64" | "term" | reftype
; the null operand
value       ::= … | "null"                         ; ConstNull
; references
expr        ::= … | "ref.null" reftype             ; RefNull
              | "ref.func" name                    ; RefFunc
              | "ref.is_null" value                ; RefIsNull
; tables (table named)
              | "table.get" name value
              | "table.set" name value value
              | "table.size" name
              | "table.grow" name value value       ; delta init
              | "table.fill" name value value value  ; offset value count
              | "table.init" name int value value value   ; seg dst src count
              | "table.copy" name name value value value   ; dst-tbl src-tbl dst src count
              | "elem.drop" int
; bulk memory (mem index leads, matching the node field order)
              | "mem.fill" int value value value          ; mem dest value count
              | "mem.copy" int int value value value       ; dst-mem src-mem dst src count
              | "mem.init" int int value value value        ; mem seg dst src count
              | "data.drop" int
; existing memory nodes gain a leading mem index (mem 0 elided for byte-identical text? — see below)
              | "mem.size" [int]
              | "mem.grow" [int] value
              | "mem.load" [int] valtype memaccess value int
              | "mem.store" [int] memaccess value value int
; module declarations
memory      ::= "memory" idxtype "(min" int ["max" int] ")"   ; idxtype ::= "i32" | "i64"
table       ::= "table" name reftype int ["max" int]
elem        ::= "elem" elemmode reftype "[" expr* "]"
                elemmode ::= "active" name value | "passive" | "declarative"
data        ::= "data" datamode bytes
                datamode ::= "active" int value | "passive"
import      ::= "import" ( fn-form | "global" str str valtype mut
                         | "table" str str reftype int ["max" int]
                         | "memory" str str idxtype int ["max" int] )
export      ::= "export" ( fn-form | "global" str name | "table" str name | "memory" str int )
```

**Byte-identity of the `.ir` text (H7).** So a Phase-1..4 `.ir` fixture is unchanged, the printer
**elides `mem 0`** on the four memory nodes and prints the Phase-2 `memory (min …)` form when the
single memory is `Idx32` and the module has ≤ 1 memory — i.e. the new tokens appear only when a
module actually uses the new surface. P5-02 reconciles this into `ir-grammar-delta.md`; the
keystone only guarantees the shape is expressible and the defaults elide.

---

## G. `«RT3-SIG-FROZEN»` — the extended runtime signatures (doc-frozen; bodies 07/08/09)

Frozen in prose (no `todo` stubs, no new warnings — the Phase-4 posture). Every head is
conservative-sound: it either extends an existing head with a leading index/segment argument
(so single-region behaviour is byte-identical) or adds a reference/bulk operation. **The
multi-region ownership seam (flagged in the overview §4) is pinned here.**

### G.1 `rt_state` — owns the **memories vector**, the **tables vector**, and the **drop state**

`rt_state.InstanceState` grows from single-mem/single-table to multi-region + passive-segment drop
state. **`rt_state` (unit 09) owns this record and the drop state**; `rt_mem`/`rt_table` operate on
a **single** region/table handle that `rt_state` projects out by index. This keeps the seam clean
and avoids double-ownership (rt_mem does not hold the vector; it holds one region's bytes):

```gleam
pub type InstanceState {
  InstanceState(
    mems: List(Dynamic),                 // CHANGED from `mem: Dynamic` — the memory-index vector
    globals: Dict(String, Int),          // unchanged (raw bit patterns; refs handled separately — see note)
    tables: List(#(String, Dynamic)),    // CHANGED from `table: Dynamic` — named multiple tables
    dropped_data: Set(Int),              // NEW — passive data segments marked dropped
    dropped_elem: Set(Int),              // NEW — passive element segments marked dropped
  )
}
```

- **Index/name projection** (unit 09, cell + threaded families):
  `mem_get_at(i) -> Dynamic` / `mem_put_at(i, Dynamic) -> Nil` and their threaded twins
  `mem_at(st, i) -> Dynamic` / `with_mem_at(st, i, Dynamic) -> InstanceState`; similarly
  `table_get(name)`/`table_put(name, _)` + `table_at`/`with_table_at`. Index `0` / the first table
  is the default; a single-memory single-table module behaves byte-identically (the vector has one
  element). The existing `mem`/`with_mem`/`table`/`with_table` seam (Phase-4) is preserved as the
  index-0 / first-table specialization so P4 threaded wrappers keep compiling.
- **Drop state:** `data_drop(seg) -> Nil` / `elem_drop(seg) -> Nil` (mark dropped) +
  `data_dropped(seg) -> Bool` / `elem_dropped(seg) -> Bool`, threaded twins `t_data_drop`/… . Drop
  state is **instance state**, so it threads through the **existing** state seam (H2) — `cell`
  holds it in the pdict record, `threaded` threads it in the record. **No new seam.**
- **Reference globals** (a global of reftype): a ref value is a `Dynamic`, not an `Int`, so
  `globals: Dict(String, Int)` cannot hold it. **Decision:** store reference-typed globals in the
  memory/term path — either widen the globals map to `Dict(String, Dynamic)` (uniform, but touches
  the raw-bits `Int` invariant) or add a parallel `ref_globals: Dict(String, Dynamic)`. **Pin
  (flagged for reconcile):** add `ref_globals: Dict(String, Dynamic)` so the numeric-global
  `Int`/raw-bits path (D5) is **untouched** and byte-identical, and reference globals live on the
  term path — matching the dual-value model. Unit 09 implements; the keystone freezes the shape.

### G.2 `rt_mem` — a memory index on the cell family; bulk ops; passive-data init

The cell-family heads gain a **leading `mem: Int`** (index into the vector); the threaded family
already takes `st` and gains the index. Byte-identical for `mem == 0`. New bulk heads:

```gleam
// cell family (state_strategy: Cell) — leading mem index
pub fn load(mem: Int, bytes: Int, signed: Bool, result_width: Int, addr: Int, offset: Int) -> Result(Int, TrapReason)
pub fn store(mem: Int, bytes: Int, addr: Int, value: Int, offset: Int) -> Result(Nil, TrapReason)
pub fn size(mem: Int) -> Int
pub fn grow(mem: Int, delta: Int) -> Int
pub fn init_data(mem: Int, offset: Int, bytes: BitArray) -> Result(Nil, TrapReason)   // at instantiate (active)
// bulk (eager bounds, trap-before-write; memmove for copy)
pub fn fill(mem: Int, dest: Int, value: Int, count: Int) -> Result(Nil, TrapReason)
pub fn copy(dst_mem: Int, src_mem: Int, dst: Int, src: Int, count: Int) -> Result(Nil, TrapReason)
pub fn init(mem: Int, seg_bytes: BitArray, dst: Int, src: Int, count: Int) -> Result(Nil, TrapReason)
// threaded twins t_fill/t_copy/t_init take (st, …) and return Result(InstanceState, TrapReason)
```

`memory.init`'s passive-segment **bytes** are supplied by `emit_core` (the segment is
compile-time-known data); the **dropped** check is `rt_state`'s (`data_dropped(seg)` — a dropped
segment ⇒ `seg_bytes = <<>>`, so `count > 0` traps). memory64 (`Idx64`) means the `addr`/`count`
`Int`s carry 64-bit values and bounds arithmetic is 64-bit — the same heads serve both widths (BEAM
`Int`s are bignums); the `idx_type` is a decode/validate/lower concern, not a signature change.
Every tier module (`rt_mem`/`rt_mem_atomics`/`rt_mem_nif`) exposes the same heads (the Phase-4
uniform-interface rule).

### G.3 `rt_table` — reference tables, table ops, bulk table, passive-element state

```gleam
pub fn new(ref_ty: RefType, min: Int, max: Option(Int)) -> Dynamic   // ref_ty NEW (default FuncRef byte-identical)
// reference table ops (cell family; threaded twins t_*)
pub fn get(handle: Dynamic, index: Int) -> Result(Dynamic, TrapReason)          // ref or trap TableOutOfBounds
pub fn set(handle: Dynamic, index: Int, value: Dynamic) -> Result(Dynamic, TrapReason)   // returns rebound handle
pub fn size(handle: Dynamic) -> Int
pub fn grow(handle: Dynamic, delta: Int, init: Dynamic) -> #(Int, Dynamic)      // prev size or -1, rebound handle
pub fn fill(handle: Dynamic, offset: Int, value: Dynamic, count: Int) -> Result(Dynamic, TrapReason)   // eager
pub fn table_init(handle: Dynamic, seg: List(Dynamic), dst: Int, src: Int, count: Int) -> Result(Dynamic, TrapReason)
pub fn table_copy(dst: Dynamic, src: Dynamic, d: Int, s: Int, count: Int) -> Result(#(Dynamic, Dynamic), TrapReason)  // memmove
// existing dispatch (unchanged shape) + type-tagged entries; a null slot is the '$null' sentinel
pub fn init_elem(handle: Dynamic, offset: Int, entries: List(#(FuncType, closure))) -> Result(Dynamic, TrapReason)
pub fn call_indirect(handle: Dynamic, index: Int, expected: FuncType, args: List(Int)) -> Result(List(Int), TrapReason)
```

- A table entry is now a **reference** — a `funcref` (`#(FuncType, closure)`), an `externref`
  (opaque term), or `'$null'`. `call_indirect`'s three-fault guard is unchanged (bounds → the null
  sentinel is guard 2 (`UninitializedElement`) → exact type is guard 3), and **`table.set`/
  `table.fill`/`table.init`/`table.copy` never install a program-chosen module/atom** (D3a): a
  funcref value is always a build-controlled closure captured at `ref.func`, never data.
- Passive-element **state** (the element items to `table.init` from) is supplied as build-time-known
  `List(Dynamic)` by `emit_core`; the **dropped** check is `rt_state`'s (`elem_dropped(seg)`).
- The paged handle stays a `Dict`; the tier modules (`rt_table_ets`/`rt_table_atomics`) expose the
  same heads (Phase-4 uniform interface). `ref_ty` on `new` is stored so a mistyped `table.set`
  cannot occur (validate already enforces types, so this is defense-in-depth).

### G.4 `rt_host` — the build-fixed `spectest` registry (§H)

`rt_host` gains the **`spectest`** provider as a **literal `case`** (no `apply/3`, D3a-clean),
exactly like the Phase-3 host-handler registry:

```gleam
/// The build-fixed `spectest` module's provided state + side-effecting host fns. A LITERAL
/// registry (no ambient authority): given a `(module, name)` link key, returns the provided
/// global/table/memory value or the host-function handler, or `Error` (unsatisfied → fail-closed).
pub fn spectest_provide(module: String, name: String) -> Result(ProvidedImport, Nil)
/// The side-effecting `spectest` host fns (`print`/`print_i32`/`print_f32`/`print_i32_f32`/
/// `print_f64`/`print_f64_f64`) — consume args, return nothing. A literal `case`.
pub fn spectest_call(name: String, args: List(Int)) -> Result(Nil, Nil)
```

`spectest` provides: `global_i32 = 666`, `global_i64 = 666`, `global_f32`/`global_f64` (the spec
constants), a `table` (`funcref`, min 10 / max 20), a `memory` (min 1 / max 2 pages), and the six
`print*` functions (side-effecting, drop their args). The exact constant values are the official
`spectest` module's ([the spec suite's `spectest` host module](https://github.com/WebAssembly/spec/tree/main/interpreter#spectest-host-module)); P5-09 pins them against the suite.

---

## H. `«INSTANTIATE3»` — the non-function-import + `spectest` link contract (H4)

The Phase-1..4 run-ABI is `load → instantiate → invoke` for a **self-contained** module. Phase 5
adds **provided state**: a module may import globals/tables/memories that the instantiation
contract must **supply**. The vocabulary is frozen here (in `instance.gleam`); the wiring is **P5-09**
(it owns `rt_state`/`rt_host`/`profiles`/`pipeline`).

### H.1 The `ImportMap` + `ProvidedImport` types (frozen in `instance.gleam`)

```gleam
/// A value the host/another-instance supplies to satisfy a non-function import (H4). These are
/// PROVIDED STATE, not capabilities — an imported global/table/memory is a value wired into the
/// instance, distinct from the `CallHost` deny-all capability boundary (which stays for host
/// FUNCTIONS via `ImportFn`). Opaque `Dynamic` for table/memory (rt_table/rt_mem own the shapes).
pub type ProvidedImport {
  ProvidedGlobal(bits: Int, is_ref: Bool)   // raw-bits Int, or a ref term when is_ref (rare; §G.1)
  ProvidedTable(handle: Dynamic)
  ProvidedMemory(handle: Dynamic)
}

/// The instantiation import map: keyed by the WASM `(module, name)` LINK key (NOT the capability
/// tag `ImportFn` uses). `instantiate` looks up each `ImportGlobal`/`ImportTable`/`ImportMemory`
/// here; an ABSENT key is a LINK-TIME FAILURE (fail-closed, H6) — never an ambient default.
pub type ImportMap {
  ImportMap(entries: Dict(#(String, String), ProvidedImport))
}
```

### H.2 The contract (frozen; P5-09 implements)

1. **`instantiate` takes an `ImportMap`.** The generated `instantiate` (currently arity 0/`fresh`)
   is extended by P5-09 to accept the provided values and wire each `ImportGlobal`/`ImportTable`/
   `ImportMemory` into the instance's `rt_state` **before** running element/data/start. A module's
   own memories/tables/globals are appended after the imported ones (imports occupy the low indices,
   per the spec's index-space rule).
2. **Fail-closed on an unsatisfied import (H6/D4).** A missing `(module, name)` entry is
   `Error(UnsatisfiedImport(module, name))` at **link time** — the instance never runs with a
   defaulted-away import. This is the state analogue of the deny-all host: absence denies.
3. **`spectest` is a build-fixed provider.** The default `ImportMap` for a suite module includes
   `spectest`'s provided state via `rt_host.spectest_provide` (§G.4) — a **literal registry**, no
   `apply`, D3a intact. `print*` imports resolve to `spectest_call` host fns.
4. **`(register "name" $mod)`** (the `.wast` script command, P5-10) makes a prior instance's
   **exports** importable by a later module: the harness reads the prior instance's `ExportGlobal`/
   `ExportTable`/`ExportMemory`/`ExportFn` and inserts them into the next module's `ImportMap` under
   the registered name. The Phase-1 multi-module registry is the substrate (no new mechanism).
5. **No `Binding` field required.** The `ImportMap` is a **runtime** input threaded through the
   run-ABI (like the invoke arguments), **not** a build-time `Binding` field — so `link/1` /
   `resolve_tiers` / `validate_binding` are unchanged, and the fail-closed tier gate composes
   unchanged. `profiles.link` stays `Binding -> Result(Instance, LinkError)`; the `ImportMap` enters
   at the `instantiate`/run-ABI seam P5-09 owns. **This is why the keystone adds no `Binding`
   field** — a deliberate decision to keep the Phase-4 link contract byte-identical.

Spec anchor: instantiation resolves imports positionally against provided externvals, appends the
module's own definitions, then runs element → data → start; a missing/type-mismatched import fails
instantiation ([spec §4.5.4 instantiation](https://webassembly.github.io/spec/core/exec/modules.html#instantiation)). The `.wast`
`register`/`get`/`invoke` script commands are the reference-interpreter's harness protocol.

---

## I. The `emit_core` seam reach (doc; full impl → P5-06)

The keystone makes `emit_core` **compile** and stay **byte-identical** on the existing surface; it
does **not** implement the new codegen (that is P5-06). Concretely:

- **`state_decl_term`** reads `module.memory` today; change to `module.memories` and build the
  memory vector (`[rt_mem:fresh(min, max, cap) | …]`). For a single `Idx32` memory the emitted
  `StateDecl` term is **byte-identical** (a one-element vector that the seam indexes at `0`). The
  same for `module.tables` → the named-tables vector.
- **The four memory-node arms** thread the (ignored, `0`) `mem` field through the existing
  `seam_call(mem_module, "load"/"store"/…, …)`; for `mem == 0` the emitted call is byte-identical
  (P5-06 adds the leading index argument for `mem > 0`). Under `Cell` and under `Threaded` both
  stay the Phase-4 shape at index 0.
- **Each new node gets a temporary arm** returning `Error(Unsupported(node))` — a real `Result`
  path (the keystone adds one `EmitError.Unsupported(String)` variant, a single-file reach). Because
  no Phase-1..4 module contains these nodes, the corpus + suite are unaffected; P5-06 replaces each
  arm with the real ref/table/bulk/multi-mem lowering through the runtime seam (§G).
- **`element_segment_effects` / `data_segment_effects`** are reshaped to the new `ElemMode`/
  `DataMode`: the `ElemActive(table, offset)` + `RefFunc`-items path and the `DataActive(0, offset)`
  path emit **byte-identical** effects to Phase-4; passive segments become droppable instance state
  the keystone leaves for P5-06/07/08 (a temporary `Error(Unsupported)` for a passive segment keeps
  the tree green — no Phase-1..4 module has one).

The **state-seam routing by memory index** and the **D3a security-invariant test extension** are
P5-06's; the keystone only guarantees the seam *shape* composes (the memory index is a static
immediate, never a runtime handle — Phase-4 G5 holds).

---

## Effect / soundness / security note

- **No ambient authority (D3a) survives the new surface.** Every reference value is a
  build-controlled term — a funcref is a compile-time closure captured at `ref.func` (never a
  program-chosen module/atom), an externref is an opaque host term Safe code cannot forge or
  inspect. `call_indirect`/`table.*`/bulk ops still emit fixed `twocore@runtime@*` module atoms
  with literal function names; the only runtime-data input reaching a control transfer remains the
  integer `call_indirect` index. The `spectest`/host registry is a **literal `case`** (§G.4/§H),
  so the new import machinery adds no `apply`. P5-06 extends the structural security test.
- **Fail-closed everywhere (D4/H6).** Every reference/table/bulk op is bounds-/type-/null-checked →
  trap **before any write** (§C.1). A null reference where a value is required traps
  (`UninitializedElement`); an unsatisfied import fails at **link time** (§H) — never an ambient
  default. `externref` opacity is the capability model, unchanged.
- **Conformance-neutral by default (H7) — the proof.** The defaults are chosen so that a module
  with `memories = [MemoryDecl(_, _, Idx32)]` (or `[]`), all `TableDecl.ref_ty = FuncRef`, all
  elements `ElemActive` with `RefFunc` items, all data `DataActive(0, _)`, function-only imports/
  exports, and `mem = 0` on every memory node, produces: the same `.ir` text (the printer elides
  `mem 0` and prints the Phase-2 `memory` form, §F), the same `InstanceState`/`StateDecl` term (a
  one-element vector indexed at 0, §I), and the same `.core` bytes (§I). Since WebAssembly is
  deterministic and D5 pins NaN/`-0.0` as raw bits, byte-identity ⇒ result-identity across both
  state strategies and every shipped memory tier. **Nothing observable changes** for the existing
  corpus + suite.
- **memory64 honesty (H8).** The `Idx64` *type* is frozen but its *runtime* may be deferred to
  Phase 6; freezing the shape costs nothing and keeps every 32-bit path byte-identical.
- **Floats/refs stay on their layer (D5).** Numeric globals remain raw-bit `Int`s (untouched);
  references live on the term (`Dynamic`) path via `ref_globals` (§G.1) — never a BEAM-double
  round-trip, never an `Int` forced to hold a term.

---

## Verification — Definition of Done (D8)

- **`gleam build` compiles with zero warnings.** The only *behavioural* code the keystone lands is
  `ir.gleam` (types), `ir/effect.gleam` (real classification), the memory-index/reshape land-green
  arms, and `EmitError.Unsupported`. The runtime signatures + instantiation contract are frozen in
  **prose** (no `todo` stubs → no warnings), the Phase-4 posture.
- **`gleam format --check src test` clean; `gleam test` stays green (906, conformance
  15747/411/0 under every shipped `(state_strategy × mem_tier)`).** The land-green reaches keep the
  tree total; the default paths are byte-identical, so **no conformance number moves** — this is
  the H7 proof, asserted by the existing conformance suite passing unchanged.
- **A scratch freeze test** (`test/twocore/ir/ir3_freeze_test.gleam`, mirroring
  `ir2_freeze_test`/`tier_freeze_test`) — **spec assertions, not change-detectors**:
  - constructs an IR3 `Module` exercising the whole new surface (a 2-memory module with one `Idx64`
    memory; an `externref` table; a passive `ElementSegment` with `RefFunc` + `RefNull` items; a
    passive `DataSegment`; `ImportGlobal`/`ImportMemory`; `ExportMemory`; a body using `RefNull`/
    `RefFunc`/`RefIsNull`/`TableGet`/`TableFill`/`MemFill`/`MemCopy`/`MemInit`/`DataDrop`/
    `TableCopy`/`TableInit`/`ElemDrop`/`TableGrow`/`TableSize` and a `mem:1` `MemLoad`) and asserts
    it **typechecks** — proving the types express the Phase-5 surface before anyone builds on them.
  - asserts **`effect.classify` returns `Effectful` for every new node** (enumerated) — the
    optimizer-soundness floor (§E), asserted against the spec rule "bulk/table/memory ops are store
    operations" (WASM §4.4.8/§4.4.9), not against current output.
  - asserts **default-neutrality structurally**: a single-`Idx32`-memory, funcref-active-`RefFunc`,
    function-only module round-trips its `.ir` text **byte-identically** to the Phase-4 spelling
    (`mem 0` elided; `memory (min …)` form) and lowers to a **byte-identical** `.core` (compare
    against a committed Phase-4 golden) — the H7 claim as a test.
  - asserts **`ConstNull` / `RefNull` equivalence** (a `RefNull(FuncRef)` and `Values([ConstNull])`
    lower to the same null sentinel) and **`RefIsNull(ConstNull) == 1`, `RefIsNull(RefFunc …) == 0`**
    (WASM §4.4.3 `ref.is_null`).
  - asserts **`TrapReason` is unchanged** (the new failures reuse the existing variants; §D) — a
    guard against an accidental variant addition breaking `spec_trap_message`'s exhaustive match.
- **The `.ir` grammar delta** (§F) is sketched for P5-02; the `«RT3-SIG»` heads (§G) and the
  `«INSTANTIATE3»` contract (§H) are frozen for 07/08/09.
- **Done = the freeze test + the full suite pass** (D8) — **not** "it compiles."
- Announce `«IR3-FROZEN»` / `«RT3-SIG-FROZEN»` / `«INSTANTIATE3»` in `state.md` with the full
  reach list.

---

## What this unit leaves

- **02** implements the `.ir` printer/parser round-trip of the whole IR3 surface (§F) and
  reconciles `ir-grammar-delta.md` to the implementation.
- **03** publishes `«WASM-AST3»` (reftypes, `0xFC`/`0xD*`/`0x25`/`0x26`/`0x1C` opcodes, memory-index
  immediates, memory64 limits flags, passive/declarative segment encodings, non-function imports/
  exports, the element expression encoding).
- **04** types the new surface (reftypes + null, tables' reftype, bulk/table ops, multi-memory
  memidx bounds, memory64 `i64` address typing, typed `select`, segment + import/export typing) —
  the AST-only security boundary.
- **05** lowers WASM-AST3 → IR3 for every new op (§C), the passive-segment model, multi-memory index
  threading, memory64 address width; adds the real new-op lowering the keystone left as land-green
  `default_value`/constructor arms.
- **06** replaces the `emit_core` `Unsupported` arms (§I) with the real ref/table/bulk/multi-mem
  codegen through the §G seam, the state-seam routing by memory index, and the extended D3a test.
- **07/08** implement the `«RT3-SIG»` `rt_table`/`rt_mem` bodies (§G) across `map`/`ets`/`atomics`
  (table) and `paged`/`atomics`/`nif` (memory) tiers + both state strategies, differential vs the
  oracle; **08** owns the memories-vector plumbing into `rt_mem` (single-region projection).
- **09** implements `rt_state`'s multi-region record + drop state + `ref_globals` (§G.1), the
  `spectest` registry (§G.4), and the `«INSTANTIATE3»` contract (§H) — the import map, fail-closed
  unsatisfied-import, and the `(register …)` substrate.
- **10** builds the WAT parser (text → `«WASM-AST3»`) + the `.wast` script layer driving §H.
- **11/12** light up the new conformance categories and prove the phase.

---

## Open questions (for the planner / cross-unit sync)

1. **externref null-collision hardening (§A.2).** Ship the atom `'$null'` sentinel + the documented
   build-fixed-host invariant (recommended), or wrap every externref as `#(externref, Term)` to be
   bulletproof against an adversarial host? Recommendation: atom sentinel now; revisit only if a
   real (non-`spectest`) host provider ever forwards an untrusted externref. Reconcile to decide.
2. **`ConstNull` vs `RefNull` redundancy (§A.3/§A.4).** The keystone ships **both** (`ConstNull`
   the operand literal, `RefNull(ty)` the typed producer). If P5-05 finds it never needs the typed
   `Expr` form (always reduces to `Values([ConstNull])` at lower time), `RefNull` could be dropped —
   but the `.ir` text + validation want the typed form, so keeping both is the recommendation. Flag
   if the reconcile prefers one.
3. **Reference globals representation (§G.1).** Add `ref_globals: Dict(String, Dynamic)` (recommended
   — keeps the numeric raw-bits `Int` path untouched, D5), or widen `globals` to `Dict(String,
   Dynamic)` (uniform but touches the raw-bits invariant and every `t_global_get/set` head)? This is
   an `rt_state` (unit 09) seam; the keystone freezes the shape but flags the choice.
4. **`memory.init`/`table.init` passive-segment data ownership (§G.2/§G.3).** The keystone pins that
   `emit_core` supplies the compile-time-known segment bytes/items and `rt_state` owns the
   **dropped** flag. Confirm units 06/07/08/09 agree that the segment payload is *not* also stored in
   `rt_state` (only the drop flag is) — avoids double-storage and keeps `data.drop`/`elem.drop` O(1).
5. **memory64 cut (H8).** If P5-08 defers the `Idx64` runtime to Phase 6, the `IdxType` type stays
   frozen (byte-identical 32-bit) but the conformance capstone must report memory64 as an honest
   categorized skip, not a pass. Decide at the capstone; the IR shape does not change either way.
6. **Opcode-byte authority (§C).** The `0xFC`/`0xD*`/`0x25`/`0x26`/`0x1C` bytes are listed for the
   reviewer but are **P5-03's** freeze (the IR is opcode-neutral). If any byte here is wrong it is a
   doc-comment fix, not an `«IR3-FROZEN»` change — flagged so P5-03 is the single source.
7. **A distinct bulk/segment trap message?** §D reuses existing `TrapReason`s (zero new variants). If
   a pinned `.wast` `assert_trap` distinguishes a message this table cannot produce, add **exactly
   one** variant + `spec_trap_message` (the Phase-2/3 pattern); flagged so it is a conscious add, not
   a silent one.
