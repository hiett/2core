# Phase 5 — Canonical reconciliation decisions (AUTHORITATIVE)

> This document is the **canonical decisions block** for Phase 5. It is the output of the
> adversarial critique (4 lenses) folded back by the engineering manager. **Where any unit doc
> (`01`–`12`) conflicts with a decision here, THIS DOCUMENT WINS** — the unit doc is stale on that
> point and the implementing agent follows the decision below. Read order for every implementation
> agent: [`00-overview.md`](00-overview.md) → **this file** → your unit doc.
>
> Nothing is built yet, so every conflict below is a *doc-level* contradiction resolved before code.
> Decisions are numbered **R1–R18**; each names the units it patches.

---

## R1 — The reference value representation is forge-proof and lives in `runtime/rt_ref.gleam` (NEW)

The critique found the null-sentinel/externref shape frozen two incompatible ways (01 §A.2 bare atom
`'$null'` + unwrapped externref; 07 §A tagged `#(ref_null)` + wrapped `#(ref_extern,_)`). **Pin the
forge-proof tagged form** (collision-proof by construction; one box per externref; funcref unchanged
so Phase-4 modules stay byte-identical):

| Reference value | Core Erlang term | Notes |
|---|---|---|
| `null` (any reftype) | `{ref_null}` (1-tuple, reserved atom) | `ref.is_null(x)` ⟹ `x =:= {ref_null}` |
| `externref` | `{ref_extern, Term}` (wrapped) | `Term` opaque; wrapping makes a host term uncollidable with null/funcref |
| `funcref` | `{FuncType, Closure}` | **UNCHANGED from Phase-2 table entries** — a funcref value *is* a table-entry shape (preserves `call_indirect` byte-identity) |

- **New single-owned module `src/twocore/runtime/rt_ref.gleam`** (owner: **keystone 01**) exposes the
  sentinel + constructors + predicates + host-constructibility helpers: `null_ref() -> Dynamic`,
  `wrap_extern(Term) -> Dynamic`, `extern_of(Int) -> Dynamic` (for the harness's `ref.extern N`),
  `is_null(Dynamic) -> Bool`, `classify_ref(Dynamic) -> RefKind`. **`emit_core` (06), `rt_table`
  (07), `rt_host`/link (09), and the conformance harness (11) all import `rt_ref`** — this removes
  the "two units must agree by coincidence" hazard (L2#3).
- **IR node cleanup (R1c):** keep **`ConstNull(ty: RefType)` as a `Value`** (a null literal, like
  `ConstI32`; used for null operands and const-init). Keep **`RefFunc(fn_name)`** and
  **`RefIsNull(arg)`** as `Expr`s. **Drop `RefNull` as an `Expr`** — a `ref.null t` instruction
  lowers to a `ConstNull(t)` value operand, so a separate `Expr` is redundant. Element/global
  const-init supports `ref.func` / `ref.null` / `global.get` (+ existing numeric consts); the
  keystone picks the concrete init encoding (a small dedicated `ElemItem` type *or* `List(Expr)`) —
  either is fine provided it round-trips (02) and funcref-active defaults stay byte-identical (H7).
- **Patches:** 01 (§A.2 → this table + create `rt_ref.gleam`; drop `RefNull` Expr), 06 (§B → import
  `rt_ref`, no bare atom), 07 (§A → import `rt_ref`, no local sentinel). MINOR (L3): `RefIsNull`
  lowers through `rt_ref:is_null`, not a `ref_module` seam field.

## R2 — Passive segments: rt_state holds ONLY the drop flag; the payload is an emit-supplied argument

The critique found two incompatible passive-segment architectures (07 reads the element vector from
`rt_state` via `elem_seg(seg)`; 01/08 pass the payload as an argument and keep only a drop flag).
**Pin the payload-as-argument + drop-flag model** (O(1) drop, no double-storage, symmetric for data
and elem):

- **`rt_state` owns only the drop state:** `dropped_data: Set(Int)` + `dropped_elem: Set(Int)`, with
  `data_dropped(seg)->Bool` / `elem_dropped(seg)->Bool` + `drop_data(seg)` / `drop_elem(seg)` (+
  threaded twins). Drop is O(1).
- **The passive payload is compile-time-known.** `emit_core` embeds it and passes it as an argument,
  gated by a runtime drop-check that substitutes ε when dropped, e.g. for `memory.init(seg,d,s,n)`:
  emit `case rt_state:data_dropped(St,Seg) of 'true' -> <<>>; 'false' -> <literal-bytes> end` → then
  `rt_mem:init(Handle, Bytes, D, S, N)`. A dropped segment thus behaves as a length-0 segment, so a
  subsequent `init` with `n>0` traps on the source-bounds check — exactly the spec (§4.4.9).
- **Frozen runtime heads (symmetric):** `rt_mem:init(mem_handle, seg_bytes: BitArray, dst, src,
  count)` and `rt_table:table_init(table_handle, items: List(Dynamic), dst, src, count)`. `rt_mem`/
  `rt_table` are pure byte/slot movers — they do NOT import `rt_state` (opacity preserved).
- **Patches:** **07** is the one that diverged — rewrite its `table_init` to take the item list as an
  argument + read `elem_dropped` (delete the `elem_seg`/`elem_seg_of` payload-store seam). 01/08 are
  already this shape; 06 emits the drop-check wrapper. `data.drop`→`rt_state:drop_data(seg)`;
  `elem.drop`→`rt_state:drop_elem(seg)`.

## R3 — `table.init` / `memory.init` immediate order is pinned (anti-swap; security-relevant)

The critique found `TableInit` field order self-contradictory across 03/04/05 (a swap silently
validates the wrong bound → OOB / wrong-trap). The binary wire order (spec §5.4.6) is **elemidx
first, then tableidx** for `table.init`, and **dataidx first, then memidx** for `memory.init`.

- **AST3 (03):** `TableInit(elem: Int, table: Int)`, `MemoryInit(data: Int, mem: Int)` — field order
  = wire order, explicitly named.
- **IR3:** `TableInit(table: String, seg: Int, dst, src, count)` (`table` = target table by name,
  `seg` = element-segment index), `MemInit(mem: Int, seg: Int, dst, src, count)` (`mem` = target
  memory index, `seg` = data-segment index). Lower maps `ast.elem→IR.seg`, `ast.table→IR.table`.
- **DoD (03):** a decode fixture with **distinct** elemidx ≠ tableidx that FAILS if the two are
  swapped. Align 04/05 to this order.

## R4 — The instantiate/import contract adopts unit 09's shapes (positional, typed, fail-closed)

The critique found the `Provided`/instantiate contract frozen incompatibly (01: `ImportMap` dict in
`instance.gleam`, no type fields, keyed by attacker-controlled names — a D3a smell and cannot do
fail-closed matching; 09: typed positional `List(Provided)`). **Adopt 09's shapes** (09 owns the
linker/instantiate contract):

- The generated entry is **`instantiate/0`** (import-free module — byte-identical H7) or
  **`instantiate/1(List(Provided))`** (module with imports). The list is **positional and name-free**;
  slot order is statically baked by `emit_core` from the module's import order (D3a-clean — no runtime
  name lookup in generated code).
- **`Provided`** (single type) carries the fields fail-closed matching needs (spec §3.2 / §4.5.4):
  `ProvidedGlobal(value, ty, mutable)`, `ProvidedTable(value, ref_ty, min, max)`,
  `ProvidedMemory(value, min_pages, max_pages, idx_type)` (+ host functions where relevant).
- **`link_imports(module, providers) -> Result(List(Provided), ImportError)`** resolves import names
  → the positional list, **failing closed** on any unsatisfied or type-mismatched import (drives
  `assert_unlinkable`). Home it in a single owner — recommend a **new single-owned
  `src/twocore/runtime/link.gleam`** so the conformance harness can call it without a `pipeline`
  dependency (09 finalizes the home).
- **Patches:** 01 (remove the `instance.gleam` `ImportMap`/`ProvidedImport`; freeze only the
  arity-0/1 rule + reference 09's `Provided`), 06 (emit against 09's `Provided`), 09 (owns it).

## R5 — `rt_state.gleam` single-owner resolution + the Wave-0 seam

`rt_state.gleam` was double-owned (overview §4 listed it under 08 and 09) and 07/08's "green under
both strategies" DoD needs the new accessors to EXIST as compilable Gleam from Wave 0 — but 09 (which
would own them) is a large Wave-A unit. **Resolution:**

- **Keystone (01), Wave 0:** lands the `rt_state` record GROWTH (memories vector, tables vector,
  passive drop-state sets, `ref_globals`) + **todo-free conservative stub accessors** (empty vectors,
  no-op seeds — sound but incomplete), so 06/07/08 compile against real signatures immediately.
- **Unit 09, Wave A:** fills the real bodies — seeding the memories/tables/segments/`ref_globals`
  from `StateDecl` at instantiate, the drop semantics, imported-state wiring.
- **07/08 CONSUME `rt_state` accessors and never edit `rt_state.gleam`.** They own only their
  `rt_mem*` / `rt_table*` files.
- **Patches:** overview §4 (rt_state under **01 + 09**, not 08); the DAG gains the note that the
  keystone provides the rt_state seam (stubs) and 09 completes it. Single-owner-per-wave: 01 then 09,
  never concurrent.

## R6 — `rt_state` seam naming (adopt 09's convention)

`mem_at`/`with_mem_at` named the *threaded* family in 01 §G.1 but the *cell* family in 09 §D.2.
**Adopt 09's convention** (09 owns the file): **cell** `mem_at(i)` / `with_mem_at(i,h)`,
`table_at(i)` / `with_table_at(i,h)`; **threaded** `t_mem_at(st,i)` / `t_with_mem_at(st,i,h)`,
`t_table_at(st,i)` / `t_with_table_at(st,i,h)`. The Phase-4 un-indexed names (`mem`/`with_mem`,
`mem_get`/`mem_put`, and the single-table accessors) remain as **index-0 aliases** for byte-identity.
Patch: keystone §G.1 table + 08's references.

## R7 — Tables are stored as a dense index-keyed vector; emit resolves name→index

Tables were frozen with three shapes and two keys (IR by name; 07 by index; 01 `List(#(String,_))`;
09 `Dict(String,_)`). **Pin a dense index-keyed vector** in `rt_state` (symmetric with memories),
with `emit_core` resolving table **name→index** at compile time (it has the module's table decls;
**index 0 = the Phase-2 single table → byte-identical `call_indirect`**). `rt_table` ops take an
index. The IR keeps table-by-name (byte-identity). Patch: 01/07/09 → the index-keyed vector; drop the
Dict / assoc-list variants.

## R8 — Reference-typed globals route through a parallel `ref_globals` map

The Int-only `StateDecl.globals` / `ProvidedGlobal(bits)` can't hold a funcref/externref global.
**Pin a parallel `ref_globals: Dict(String, Dynamic)`** in `rt_state` alongside the Int `globals`
(so D5 raw-bit numeric globals stay byte-identical). `StateDecl` carries ref-global decls; `Provided`
supports a reference-valued global (`ProvidedGlobal.value: Dynamic` with a `ty`, or a
`ProvidedRefGlobal` variant). `emit_core` routes reftype `global.get`/`global.set`/init to the
`ref_globals` accessor. In scope: `global.wast` funcref/externref asserts. Patch: 01/06/09.

## R9 — ALL O(N) bulk ops charge proportional fuel (resource-bound completeness)

07 metered only `table.grow`; `table.fill`/`table.init`/`table.copy` charged nothing — an O(N)
unmetered loop defeats Phase-3's Safe CPU bound. **Pin:** every O(N) bulk op charges `rt_meter.charge`
proportional to the element/byte count **on success**, identical across cell/threaded and all tiers:
`memory.fill/init` and `table.fill/init` charge `count`; `memory.copy`/`table.copy` charge `count`
(once); `memory.grow`/`table.grow` charge proportional to the delta (existing). Patch: 07 (add the
charges; 08 already has them).

## R10 — The exact eager-bounds rule: `offset + n > size ⇒ trap` (no `n==0` short-circuit)

01 §C.1's "a zero-length bulk op at an out-of-range index does not trap" is **wrong**. The spec
(§4.4.9) checks `d + n > size` (and `s + n > src_size` for copy/init) **unconditionally**, so
`d = size, n = 0` does **not** trap but `d > size, n = 0` **does** (tested by
`memory_fill`/`memory_copy`/`table_copy` .wast). No partial writes on trap. Patch: 01 §C.1 → the exact
rule; 07/08 implement it precisely.

## R11 — `memory.copy` / `table.copy` are memmove (overlap-correct)

Snapshot-then-write (or the spec's ascending/descending direction rule — behaviorally identical) so
overlapping ranges copy correctly in both directions. Already sound in 07/08; ratified.

## R12 — memory64: keep the IR axis, DEFER the runtime to Phase 6

The scoping agents unanimously flagged memory64 as risky (unverified i64 page cap — "do not ship a
guessed constant"; i64 arithmetic through every stage; narrowest payoff since atomics/nif fail-closed
reject it). **Exercise H8's "deferrable half":**

- **KEEP** `IdxType`/`Idx64` frozen in the IR/AST (the axis stays expressible). **DECODE (03)** parses
  the 64-bit limits flag (`0x04`/`0x05`); **VALIDATE (04)** types i64 addresses correctly (so a
  genuinely-invalid memory64 module still fails `assert_invalid`, and we never mis-parse a valid one).
- **LOWER (05) / link REJECT** a 64-bit memory with a categorized `Memory64Unsupported` error → the
  conformance harness reports `memory64.wast` as a categorized **skip** (`memory64 runtime → Phase 6`).
  No `Idx64` runtime, no guessed page constant.
- **Patches:** overview §1 (acceptance: memory64 = decode/validate-only, runtime deferred) + §H8;
  05/08 (reject Idx64, don't mis-lower); 11/12 (categorized skip). This is the honest, finishable call.

## R13 — The datacount-section wellformedness check is owned by DECODE

`assert_malformed "data count section required"` (a `memory.init`/`data.drop` present with no
datacount section, spec §5.5.14) was orphaned. **Owner: decode (03)** — add a `DataCountMissing`
malformed error + a fixture. Patch: 03 (own it), 04 (note it's decode's, not validate's).

## R14 — The `spectest` module ships the full standard set

01/09 listed only six `print*` arms. **Ship the complete official `spectest`:** functions `print`,
`print_i32`, `print_i64`, `print_f32`, `print_f64`, `print_i32_f32`, `print_f64_f64` (side-effecting,
return nothing); `global_i32 = 666`, `global_i64`, `global_f32`, `global_f64` (immutable);
`(table 10 20 funcref)`; `(memory 1 2)`. All as a build-fixed registry (literal `case`, no `apply/3`
— D3a). Patch: 01/09 (add `print_i64` + the full set).

## R15 — The WAT parser is one doc, two implementation passes; float honesty

Unit 10 is over-scoped for a single agent. Keep **one spec doc (10)** but implement in two sequential
passes: **10a** (lexer + `parse_module` → «WASM-AST3») and **10b** (`parse_script` for the `.wast`
commands + the `decode∘wat2wasm` differential). The `.wast` layer produces a **src-side `Script`**
type (module + commands + raw-bit-tagged values); **unit 11 owns the test-side adapter**
(`wat_fixture.gleam`) converting `Script` → the harness `fixture.Command`/`Action`/`SpecValue` (src
cannot emit test-side types). Float literals: **hex-float + `nan:0x` payloads bit-exact (required)**;
decimal-float best-effort (Erlang parsing) with a flagged limitation — the differential DoD is the
safety net. Out-of-scope text (SIMD/GC) = a categorized parse-skip, never a silent mis-parse.

## R16 — Conformance greenness is MEASURED, never promised

Unit 11 **empirically re-verifies `wast2json` at the pinned SHA** for every target file before
claiming it. Files un-`wast2json`-able at the pin route through the **WAT parser (10)**; if even our
parser can't (genuinely out-of-scope text) → a categorized skip. `table_init.wast` and any
GC-arrayref-tainted file: verify at the pin; if out of scope, **honest categorized skip** — do NOT
assert greenness. The skip-drop headline is whatever is **measured**. Patch: 11 (DoD adds the
convertibility audit), 12 (report measured numbers).

## R17 — The invoke run-ABI returns a value list (multi-value); residual skips stay closed

The single-result invoke ABI would turn any multi-result `assert_return` in a newly-lit file into an
**uncategorized** skip (breaking the closed-residual accounting). **Pin:** unit 11 extends the invoke
run-ABI to return a **value list** (this also clears many *existing* multi-value skips — a real win).
If that proves too invasive, fall back to an explicit `multi-value result → deferred` skip category.
Either way, **no uncategorized skips, no silent truncation**. Patch: 11.

## R18 — Reference values are host-constructible + inspectable for the harness

So the conformance harness can pass `ref.extern N` / `ref.func` / `ref.null` arguments and JUDGE
returned references: `rt_ref` (R1) exposes `extern_of(Int)` + `classify_ref` (part of «RT3-SIG»), and
`fixture.SpecValue` (+ the WAT `Script` value type) gain `RefNullVal(ty)` / `RefFuncVal` /
`RefExternVal(Int)` variants. Patch: 01 (rt_ref helpers), 10/11 (value variants).

---

## Scope & DAG deltas (summary)

- **Unit count stays 12.** Unit **10** is implemented in two agent passes (10a module parser, 10b
  `.wast` script + differential). Units **07/08** may be split at implementation time (EM discretion)
  if a single agent struggles — the op semantics are uniform across tiers, so a tier-axis split is clean.
- **New single-owned modules:** `runtime/rt_ref.gleam` (01), `runtime/link.gleam` (09, if chosen).
- **`rt_state.gleam`:** 01 (shape + stub accessors, Wave 0) → 09 (real bodies, Wave A). Never 07/08.
- **memory64 runtime deferred to Phase 6** (R12); `IdxType` stays in the frozen IR.
- **In-scope-but-note:** extended-const init expressions (arithmetic in const exprs) are the separate
  *extended-const* proposal → **deferred / categorized-skip**; Phase-5 const-init is
  `ref.func`/`ref.null`/`global.get` + numeric consts only.

## What did NOT change (critique confirmed sound)

All opcode bytes + `0xFC` sub-opcodes (8–17) + element flags 0..7 + data flags 0/1/2 + the datacount
section ordering + memarg bit-6/u64 + the memory64 limits flags + `C.refs` membership (03/04);
eager-bounds + no-partial-write + memmove snapshot + `grow` returns `-1`/never-traps +
`UndefinedElement`-vs-`TableOutOfBounds` split (07/08); index-0 `_at` byte-identity for
load/store/size/grow (06/08); references as term-layer values (H7 neutrality). These were checked
against the WebAssembly spec and are correct — implement them as the docs specify.
