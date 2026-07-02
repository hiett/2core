# Phase 5 — Overview & Shared Contracts

> **Read this after the Phase-1, Phase-2, Phase-3, and Phase-4 overviews.** Every decision on
> those pages **still holds** — one owner per file, runtime layers as Gleam modules reached
> through the binding chokepoint with **no ambient authority** (D3a), per-stage error types,
> floats-as-bit-patterns (D5), named-label structured IR, the tier-O `cell` / tier-P `threaded`
> state strategies, the memory trust-tier ladder (`paged`/`atomics`/`nif`), the shared optimizer,
> the two named modes (Safe/Unsafe), spec-first tests, the strict Definition of Done. This page
> adds the Phase-5 decisions **H1–H8**. Phases 1–4 are complete and green: **906 tests, 0 warnings,
> conformance 15747 / 411 / 0 under every shipped `(mode × state_strategy × mem_tier)` binding**,
> the optimizer proven sound, the trust-tier ladder real, and the runs-anywhere headline concrete.
>
> **⚠ After the scoping fan-out + adversarial critique, the canonical decisions were reconciled in
> [`RECONCILIATION.md`](RECONCILIATION.md) (decisions R1–R18). That file is AUTHORITATIVE — where a
> unit doc conflicts with it, RECONCILIATION.md wins. Implementer read order:
> this overview → `RECONCILIATION.md` → the unit doc.** Notable reconciled change: **memory64's
> runtime is deferred to Phase 6** (the IR axis stays; decode/validate only — R12).

---

## 0. Where Phase 5 sits (the platform, one paragraph)

Phases 1–4 built a **correct, sandboxed, fast, runs-anywhere execution platform** — but for a
**partial WebAssembly surface**. The engine runs WASM 1.0 + multi-value + sign-extension +
non-trapping float-to-int, single-memory-32, funcref-only active tables, active-only data/element
segments, function-only imports. The official spec suite still **skips** thousands of assertions
that exercise the rest of standardized WebAssembly: **reference types** (`funcref`/`externref` as
first-class values, `ref.null/ref.func/ref.is_null`, `table.get/set/grow/size/fill`, typed
`select`), **bulk memory** (`memory.fill/copy/init`, `data.drop`, `table.init/copy`, `elem.drop`,
passive segments), **multi-memory**, **memory64**, and — the reason so many `.wast` files skip at
all — **non-function imports + the `spectest` host module** and the fact that many suite files are
**un-`wast2json`-able** at the pin and need a **WAT text parser** we do not have. Phase 5 is the
**surface-completion phase**: it grows the engine to the complete WebAssembly surface (minus SIMD)
and builds the tooling that lets the spec suite actually run it. It is the **first phase since
Phase 2 to grow the IR** — and it does so keeping the IR **language-neutral** (H7) and
**conformance-neutral by default** (a Phase-1/2/3/4 module still compiles byte-identically).

---

## 1. The Phase-5 goal (concrete and measurable)

> **Complete the WebAssembly engine.** Generated code correctly executes the full standardized
> WebAssembly surface *except SIMD*: **reference types** (references are first-class term-layer
> values; tables are typed reference stores), **bulk memory & table operations** (with spec-exact
> overlap and eager-bounds-trap semantics, and passive/droppable segments), **multiple memories**
> and **64-bit memories** (a memory-index + address-width axis), and **non-function imports** wired
> through a real instantiation contract including the official **`spectest`** host module. A
> first-class **WAT text parser** produces the same WASM AST the binary decoder does, removing the
> external `wat2wasm` dependency for fixtures and unblocking the un-convertible spec files. Every
> new feature is **spec-differentially correct** (held to a conformant engine / the `rebuild`
> oracle), holds under **both modes and every state-strategy × memory-tier**, preserves
> **constant-space loops + preemption**, and is **conformance-neutral by default** (the existing
> corpus + suite stay byte-identical).

### Acceptance (owned by the capstone)

| Area | Must demonstrate |
|---|---|
| **reference types** | `funcref`/`externref` are first-class values; `ref.null`/`ref.func`/`ref.is_null`, `table.get/set/grow/size/fill`, typed `select` all execute spec-correctly; a `call_indirect`/reference through a null slot **traps** (`UninitializedElement`); multiple tables and reference-typed (active + passive + declarative) element segments work; **`reftype.wast`/`ref_null.wast`/`ref_func.wast`/`ref_is_null.wast`/`table_*.wast`/`elem.wast`/`select.wast` run green** |
| **bulk memory & table** | `memory.fill/copy/init`, `data.drop`, `table.init/copy`, `elem.drop` execute with **spec-exact semantics** — overlap-correct copy (memmove), **eager bounds check → trap with no partial writes**, dropped-segment = zero-length; passive data & element segments carry **droppable instance state**; **`bulk.wast`/`memory_fill.wast`/`memory_copy.wast`/`memory_init.wast`/`table_init.wast`/`table_copy.wast` run green** across `paged` and `atomics` and both state strategies |
| **multi-memory** | a module with **>1 memory** decodes/validates/lowers/runs; every memory instruction carries a **memory index**; single-memory modules are **byte-identical** to Phase-4 output (the index defaults away) |
| **memory64** *(runtime → Phase 6, R12)* | a **64-bit memory** **decodes and validates** correctly (`i64` address typing; a genuinely-invalid memory64 module still fails `assert_invalid`); its **runtime is deferred to Phase 6** — lower/link reject a 64-bit memory with a categorized `memory64 runtime → Phase 6` skip. The `IdxType` axis stays frozen in the IR; 32-bit memories are byte-identical to Phase-4 |
| **non-function imports + `spectest`** | imported **globals/tables/memories** are wired through the instantiation contract as **provided state** (not deny-all capabilities); the official **`spectest`** module (`global_i32/i64/f32/f64`, `table`, `memory`, `print*`) and the suite's `(register …)` mechanism work, so the many suite files that import them **stop skipping**; an **unsatisfied import fails closed at link time** (never ambient authority — D3a holds) |
| **WAT text parser** | a new `frontend/wasm/wat.gleam` parses the full text format (folded + flat instructions, S-expressions, the standard abbreviations, inline import/export) **and** the `.wast` script commands (`module`, `assert_return`, `assert_trap`, `assert_invalid`, `register`, `invoke`, `get`, …) into the same WASM AST the binary decoder produces; **differentially proven** `wat_parse(text) ≡ decode(wat2wasm(text))` over a corpus; the previously un-`wast2json`-able suite files now run **from our own parser** |
| **conformance expansion (the headline)** | the pinned spec suite's **skip count drops materially** as whole categories light up (reftypes, bulk, multi-memory, memory64, spectest-importing files, WAT-only files); **`fail == 0` and `pass` rises**, reported honestly with categorized residual skips; the new surface is **differentially checked** against `wasmtime` |
| **conformance-neutral + all-tier** | the entire Phase-1..4 acceptance corpus + previously-passing suite stay **byte-identical** under both profiles and every `(state_strategy × mem_tier)`; the new surface is green under the same matrix |

### Honest scope (H8 — do not overstate)

- **SIMD is deferred to Phase 6.** Fixed-width SIMD (the `v128` value type + ~236 lane
  instructions) is the single largest WebAssembly proposal, and high-level §12 explicitly brackets
  it *"(large; defer)."* Folding it into Phase 5 would double the phase and dilute quality. Phase 5
  completes **everything else** in the standardized surface; SIMD gets its own focused **Phase 6**.
- **memory64's runtime is deferred to Phase 6 (decision exercised — R12).** Multi-memory is
  mechanical and lands. memory64's runtime (`i64` addressing everywhere, an unverified i64 page cap)
  was flagged by every scoping agent as the least-impactful-per-correctness-surface feature; per the
  critique we **exercise H8's deferral**: keep the `IdxType` axis frozen in the IR and **decode +
  validate** memory64 fully (so we never mis-parse and `assert_invalid` still works), but **defer the
  runtime to Phase 6** — a 64-bit memory is a categorized skip (`memory64 runtime → Phase 6`), not a
  guessed-constant implementation. Do not claim memory64 execution in Phase 5.
- **Reference types = `funcref`/`externref` only** — *not* the GC proposal's typed function
  references or `struct`/`array`/`i31` reference types (those are the GC proposal → later). Phase 5
  ships the two MVP-completion reference types and their table/select/ref instruction surface.
- **This is a surface phase, not a speed phase.** Phase 4's benchmark numbers stand; Phase 5 adds
  no optimizer passes and makes no new performance claim. The one performance-shaped obligation is
  **negative**: the new ops must preserve constant-space loops + preemption and must not regress the
  existing corpus.
- **The IR grows — deliberately and neutrally (H7).** Unlike Phases 3–4 ("no new IR node types"),
  Phase 5 adds IR value types + `Expr` nodes + a `.ir` grammar delta. This is expected: Phase 5 is
  the surface phase. Every addition is chosen **language-neutrally** (H7) and is
  **conformance-neutral by default** (H1/H7).
- **Deferred (state it):** SIMD, memory64-if-cut (**Phase 6**); exception-handling / GC (incl.
  GC-proposal reference types) / stack-switching / the component model (later); the Erlang/Gleam
  frontend (later); the single-`.beam` runtime-dispatch **B1** binding; tier-N numerics; a production
  C NIF for tier-N memory. **WASI** remains just an `rt_host` impl, out of core.
- **A goal the completed surface enables — "JS on the BEAM" via Porffor** (a stated direction, *not*
  a deferred phase): *any Porffor application runs via 2core on the BEAM*. Porffor's JS→WASM output is
  largely runnable through `fe_wasm` already; the remaining work toward the goal is a **Porffor-ABI
  `rt_host` shim** (Porffor's own runtime ABI, not WASI) — not yet built or tested.

---

## 2. The Phase-5 decisions (H1–H8)

Frozen for Phase 5. If you believe one is wrong, raise it with the planner **before** building.

### H1 — The keystone is the reference value layer + the surface freeze

Phase 5's load-bearing new thing — the analogue of Phase-2's `cell` and Phase-4's `state_strategy`
— is the **reference value model**. References are **term-layer values** (decision #4's high-level
term model, not the low-level numeric path), reached with the dual-value model already in the IR:
- **`funcref`** is a reference to a WASM function. It reuses the Phase-2 **type-tagged table entry**
  `#(FuncType, target)` — a `funcref` value *is* what a table slot already holds, promoted to a
  first-class value. `ref.func $f` produces one; `call_indirect`/a future `call_ref` consume one.
- **`externref`** is an **opaque BEAM term** — any host value, which Safe code can hold, pass, and
  compare-to-null but **cannot forge or inspect** (opacity is the security property).
- **`ref.null t`** is a single distinguished **null sentinel** (per reference type); `ref.is_null`
  tests it; a null reference used where a value is required (a null `call_indirect` slot) **traps**
  (`UninitializedElement`, already in `TrapReason`).
- **Tables become typed reference stores** (`funcref` | `externref`), reusing and generalizing the
  Phase-2 `rt_table`. `table.get/set/grow/size/fill` read/write reference values; `TableDecl` gains
  a reference-type tag; element segments gain passive/declarative forms + the expression encoding.

The keystone (**P5-01**) freezes: the new **`ValType`** reference constructors + the reference
value representation; the new `Expr` nodes (H2/H3 below); the extended `Module`/`ImportDecl`/
`ExportDecl`/`TableDecl`/`ElementSegment`/`DataSegment`/`MemoryDecl` shapes; any new `TrapReason`;
the extended `rt_table`/`rt_mem`/`rt_state` signatures (doc-frozen, `todo`-free); the `.ir` grammar
delta (H7); and the instantiation/import contract (H4). It **lands green** with defaults chosen so
every prior module is byte-identical.

### H2 — Bulk & reference/table ops are new effectful IR nodes with spec-exact semantics

New `Expr` nodes (final names frozen by P5-01), all **effectful** (the effect analysis §P3-02 must
classify them as barriers — none are pure, none CSE/reorder):
- **Reference:** `RefNull(ty)`, `RefFunc(fn_name)`, `RefIsNull(value)`.
- **Table:** `TableGet(table, index)`, `TableSet(table, index, value)`, `TableSize(table)`,
  `TableGrow(table, delta, init)`, `TableFill(table, offset, value, count)`.
- **Bulk memory:** `MemFill(mem, dest, value, count)`, `MemCopy(dst_mem, src_mem, dst, src, count)`,
  `MemInit(mem, seg, dst, src, count)`, `DataDrop(seg)`.
- **Bulk table:** `TableInit(table, seg, dst, src, count)`, `TableCopy(dst_tbl, src_tbl, dst, src,
  count)`, `ElemDrop(seg)`.

Semantics are held to the spec, not the implementation:
- **Overlap-correct copy** — `memory.copy`/`table.copy` behave like `memmove` (correct for
  overlapping ranges in either direction).
- **Eager bounds check** — the finalized bulk-memory semantics **trap before any write** if the
  range is out of bounds (no partial effects), matching the existing `rt_mem` trap-before-write
  invariant. `MemFill`/`MemInit`/`MemCopy`/`TableInit`/`TableCopy`/`TableFill` all check first.
- **Passive/droppable segments** carry **instance state**: a passive data/element segment is a
  runtime value that `data.drop`/`elem.drop` mark empty (a subsequent `*.init` from a dropped
  segment with non-zero length traps / is a no-op per spec). This drop state **threads through the
  existing state seam** (it is instance state, so `cell` holds it in the pdict and `threaded`
  threads it in the record — no new seam).
- Typed `select` (`select_t`) lowers to the existing `If`/value-merge — **no new node** (it is a
  decode/validate concern only).

### H3 — Multi-memory & memory64 are a memory-index + address-width axis, confined to the seam + runtime

- **Multi-memory:** IR `Module.memory: Option(MemoryDecl)` becomes **`memories: List(MemoryDecl)`**;
  every memory-touching node (`MemLoad/MemStore/MemSize/MemGrow` + the bulk-memory nodes) carries a
  **memory index** (defaulting to `0`). `rt_state` holds a **vector of memories**; the seam routes
  by index. A single-memory-index-0 module is **byte-identical** to Phase-4 (H7).
- **memory64:** `MemoryDecl` gains an **address type** (`i32` | `i64`, from the limits' index-type
  flag). For a 64-bit memory the address operand is `i64`, bounds arithmetic is 64-bit, and offsets
  may exceed 2³². 32-bit memories are unchanged. *(Deferrable half — see §H8.)*

Per H7 this is confined to the frontend (decode/validate/lower), the `emit_core` seam, and the
runtime; **no value flows a raw handle through the IR** (the tier-agnostic rule from Phase-4 G5
holds — the memory *index* is a static immediate, not a runtime handle).

### H4 — Non-function imports + `spectest` make the spec suite runnable (the biggest unlock)

- **`ImportDecl`** gains `ImportGlobal`/`ImportTable`/`ImportMemory` (today it is `ImportFn` only);
  **`ExportDecl`** gains `ExportGlobal`/`ExportTable`/`ExportMemory` (today `ExportFn` only — the
  suite's `assert_return (get $m "g")` and `spectest`'s exported memory/table need these).
- **Imports of state are provided state, not capabilities.** An imported global/table/memory is a
  value the instantiation contract **supplies** to the instance; it is *not* the deny-all
  `call_host` capability boundary (that stays for host *functions*). The instantiation contract
  (P5-09) takes an **import map** and wires provided values into the instance state; an
  **unsatisfied import is a link-time failure** (fail-closed — H6), never an ambient default.
- **The `spectest` module** — the official suite's standard host module — ships as a **build-fixed
  registry** (like Phase-3's `rt_host` handlers: a literal `case`, no `apply/3`, D3a-clean):
  `global_i32/i64/f32/f64`, a `table` (funcref, 10..20), a `memory` (1..2 pages), and `print`/
  `print_i32`/`print_f32`/`print_i32_f32`/`print_f64`/`print_f64_f64` (side-effecting host fns that
  consume args and return nothing). The suite's `(register "name" $mod)` command (P5-10) makes a
  prior module's exports importable by a later module — the multi-module registry (unit-07 Phase-1)
  is the substrate.

### H5 — The WAT text parser is a first-class frontend, not a fixture crutch

`frontend/wasm/wat.gleam` is a real frontend stage producing the **same `frontend/wasm/ast.gleam`
Module** the binary decoder produces — so `validate`/`lower` serve both, unchanged. It parses:
- **The module text format** — the S-expression form *and* the flat instruction form, folded
  expressions, the full set of standard **abbreviations** (inline `(func)`/`(table)`/`(memory)`/
  `(global)`/`(elem)`/`(data)` type/export/import shorthands, `$id` identifiers → indices, inline
  export/import), the `(type …)` section, and all instruction mnemonics in Phase-5 scope.
- **The `.wast` script format** — `(module …)`, `(assert_return …)`, `(assert_trap …)`,
  `(assert_invalid …)`, `(assert_malformed …)`, `(assert_exhaustion …)`, `(register …)`,
  `(invoke …)`, `(get …)` — enough for the conformance harness to drive our own pipeline directly.

Its **DoD is differential**: for a corpus of `.wat`, `wat_parse(text)` produces an AST that
**validates+lowers+runs identically** to `decode(wat2wasm(text))` (and, where feasible, structural
AST equality). This removes the external `wat2wasm`/`wast2json` dependency for fixtures and — the
real payoff — lets the suite files that are **un-`wast2json`-able at the pin** run **from our own
parser**. Scope honesty: the parser targets the Phase-5 instruction surface; anything out of scope
(SIMD text, GC text) is an explicit, categorized parse-skip, never a silent mis-parse.

### H6 — Security & fail-closed for the new surface

- **Every reference/table/bulk op is bounds-/type-checked → trap.** A table access out of range
  traps (`TableOutOfBounds`); a null reference where a value is required traps
  (`UninitializedElement`); a `call_indirect` type mismatch traps (`IndirectCallTypeMismatch`); a
  bulk op out of range traps (`MemoryOutOfBounds`/`TableOutOfBounds`) **before any write**. The
  worst case of a bounds bug is a wrong/missing trap or a node-safe crash — **never a host escape**.
- **`externref` is opaque.** Safe code may hold, pass, store, and null-test an `externref` but
  cannot forge one or read the underlying host term — the capability model is unchanged.
- **Imports fail closed.** An unsatisfied import is a link-time error; the `spectest`/host-function
  registry is **build-fixed** (literal `case`, no ambient `apply`), so the D3a no-ambient-authority
  invariant holds for the new import machinery exactly as it does for `call_host`.
- **The `rebuild` oracle + differential engine hold every new op to the spec** (§11).

### H7 — The IR grows, but stays language-neutral & conformance-neutral by default

Phase 5 **does** add `ValType` reference constructors, the H2/H3 `Expr` nodes, the `Module`/import/
export/segment shape changes, and a **`.ir` grammar delta** (owned + reconciled by P5-02, like
IR2). The discipline (the anti-WASM-ism rule, high-level decision #1) holds:
- References are **term-layer values** (usable by a future JS/Gleam frontend — JS first-class
  functions and host objects map onto `funcref`/`externref`), not a WASM-only construct.
- Bulk ops are **generic sequence operations** over the memory/table abstractions, not WASM opcodes.
- The memory-index axis is a **generic multi-region model**, not a WASM immediate leaked into the IR.
- **Defaults are conformance-neutral:** a module with one 32-bit memory, funcref-only active
  elements, function-only imports, and no bulk/ref ops compiles **byte-identically** to Phase-4.
  Both state strategies and all shipped memory tiers keep the corpus + prior suite green.

### H8 — Honest scope

See §1. Included: reference types, bulk memory & table ops, multi-memory, memory64 (deferrable
half), non-function imports + `spectest`, the WAT text parser. **SIMD → Phase 6** (the single
largest proposal; "large; defer" per §12). **JS on the BEAM via Porffor is a goal the completed
surface enables — gated on a Porffor-ABI `rt_host` shim, not a future phase.** Reference types
are `funcref`/`externref` only (GC-proposal reftypes are later). This is a surface phase — no new
optimizer passes, no new perf claim; the obligation is **conformance-neutral by default** + the
new surface **differentially spec-correct** under the full tier/mode matrix. The performance story
is Phase 4's, unchanged. Do not claim memory64 or a shipped C NIF unless actually built and tested.

---

## 3. Dependency DAG — freeze milestones

```
WAVE 0   01 KEYSTONE (one owner; lands green):
            «IR3-FROZEN»    (ValType reftypes + reference value model + H2/H3 Expr nodes +
                             Module.memories/mem-index + memory64 addr-type + ImportDecl/
                             ExportDecl state variants + TableDecl reftype tag + passive/
                             droppable segment model + new TrapReasons + .ir grammar delta)
            «RT3-SIG-FROZEN» (extended rt_table/rt_mem/rt_state signatures, todo-free doc-frozen)
            «INSTANTIATE3»   (the non-function-import + spectest instantiation/link contract)
                 │
   ┌──────┬──────┬──────┬──────┬──────┬──────┬──────┬──────────┐
   ▼IR3   ▼AST3  ▼AST3  ▼IR3   ▼IR3   ▼RT3   ▼RT3   ▼RT3+INST   ▼AST3
 ┌─────┐┌─────┐┌─────┐┌─────┐┌─────┐┌─────┐┌─────┐┌──────────┐┌───────┐
 │02   ││03   ││04   ││05   ││06   ││07   ││08   ││09 imports││10 WAT │
 │.ir  ││decode││valid ││lower ││emit ││rt_   ││rt_  ││+spectest ││text   │
 │text ││(+AST3)││ate  ││     ││core ││table││mem  ││+linker   ││parser │
 └─────┘└─────┘└─────┘└─────┘└─────┘└─────┘└─────┘└──────────┘└───────┘
  WAVE A  WAVE A WAVE A WAVE A WAVE A WAVE A WAVE A  WAVE A      WAVE A
                       ┌────────────────┐   ┌──────────────────────────────────┐
                       │11 conformance   │   │12 CAPSTONE: full surface green;  │
                       │  expansion +    │   │   skip-count drops; fail=0 under │
                       │  differential   │   │   the full matrix; honest close  │
                       └────────────────┘   └──────────────────────────────────┘
                            WAVE B                        WAVE C
```

- **Two critical paths.** (1) The **frontend pipeline** 03 decode → 04 validate → 05 lower is the
  broadest surface change and must move first behind `«AST3»`. (2) The **`emit_core` extension
  (06)** is the deepest single-owner codegen change; it needs `«IR3»` + `«RT3-SIG»` (not the
  runtime bodies), so it parallels 07/08. Start 03 and 06 first.
- **The runtime tracks (07 rt_table, 08 rt_mem) parallelize** behind `«RT3-SIG»`, differentially
  tested against the oracle, and must work under **every state strategy × mem tier** (H8).
- **Imports/spectest (09) + the WAT parser (10)** are large, mostly-independent tracks; 10 needs
  only `«AST3»`; 09 needs `«RT3-SIG»` + `«INSTANTIATE3»`.
- **Conformance (11)** needs the whole pipeline + runtime; **the capstone (12)** proves the phase.

*(Proposed unit split — the scoping agents may refine, as in every prior phase. In particular the
scoping fan-out should sanity-check whether `emit_core` (06) and `lower` (05) are each single-agent
sized given the surface, and whether memory64 belongs in 08 or is cut per §H8.)*

---

## 4. File-ownership map (D1)

> Single owner per file. Several units **extend** existing files (single-owner, additive). The
> keystone makes deliberate, documented cross-file reaches (growing `ValType`/`Expr`/`Module`
> breaks every exhaustive match and every constructor — it must land green).

| Unit | File(s) | Notes |
|---|---|---|
| **01** keystone | `ir.gleam` (reftypes, `ConstNull` Value, `RefFunc`/`RefIsNull` + table/bulk `Expr` nodes, `Module.memories`, mem-index, import/export state variants, `TableDecl` reftype, segment/`MemoryDecl` shape, `TrapReason`) · **`runtime/rt_ref.gleam` (NEW — the forge-proof reference value model, R1)** · `runtime/rt_state.gleam` *(record growth + todo-free stub accessors — R5)* · `ir/effect.gleam` *(classify new nodes as barriers)* · `ir/printer.gleam`/`ir/parser.gleam`/`backend/emit_core.gleam` *(minimal compile-satisfying arms; full impls are 02/06)* · doc-freeze `rt_*` sigs + reference the 09 instantiate contract | `«IR3-FROZEN»` / `«RT3-SIG-FROZEN»` / `«INSTANTIATE3»`. Land green, byte-identical defaults. |
| **02** `.ir` textual | `ir/printer.gleam`, `ir/parser.gleam` (extend) + `specs/phase-5/ir-grammar-delta.md` (or reconcile `ir-grammar.md`) | Full round-trip of the new surface; grammar reconciled to the implementation. |
| **03** decode ext | `frontend/wasm/decode.gleam`, `frontend/wasm/ast.gleam` (extend) | Publishes **`«WASM-AST3»`** day 1: ref value types, `0xFC`-prefix bulk/table opcodes, ref instructions, memory-index immediates, memory64 limits flags, passive/declarative segment encodings, non-function imports/exports, typed `select`, the expression-form element encoding. |
| **04** validate ext | `frontend/wasm/validate.gleam` (extend) | Typing for reftypes (`funcref`/`externref` + null), tables (reftype), bulk/table ops, multi-memory memidx bounds, memory64 `i64` address typing, typed `select`, segment + import/export typing. Security boundary; rejects ill-typed fail-closed. |
| **05** lower ext | `frontend/wasm/lower.gleam` (extend) | WASM AST3 → IR3 for every new op; passive-segment lowering; multi-memory index threading; memory64 address width. |
| **06** emit_core ext | `backend/emit_core.gleam` (extend) | Lower all new IR nodes through the runtime seam (ref/table/bulk/multi-mem); the state-seam routing by memory index; extend the D3a security-invariant test. Single-owner, deepest codegen change. |
| **07** rt_table ext | `runtime/rt_table.gleam` + tier modules (extend) / new tier helpers | Typed reference tables; `get/set/grow/size/fill`; `table.init/copy` + `elem.drop`; passive element state; multiple tables; funcref/externref storage; across `map`/`ets`/`atomics` tiers + both state strategies; differential vs oracle. |
| **08** rt_mem ext (+multi-mem) | `runtime/rt_mem.gleam` + `rt_mem_atomics`/`rt_mem_nif` (extend) — **does NOT edit `rt_state.gleam` (R5); consumes its accessors** | `memory.fill/copy/init` (overlap + exact eager-bounds-trap R10; O(N) fuel R9) + `data.drop` payload-as-arg (R2); the memory-index vector routing; **memory64 runtime deferred (R12)**; across `paged`/`atomics` (+`nif` iface) + both strategies; differential vs oracle. |
| **09** imports + spectest + linker | `runtime/rt_host.gleam` (extend: full `spectest` registry R14), **`runtime/rt_state.gleam` (real bodies — seeding, drop semantics, imported-state, `ref_globals`; R5/R8)**, `runtime/link.gleam` *(NEW — `Provided`/`link_imports`, R4)*, `runtime/profiles.gleam`/`pipeline.gleam`, the `instantiate/0`/`instantiate/1(List(Provided))` seam (R4) | Non-function imports wired as positional provided state (fail-closed matching); the build-fixed `spectest`; export-of-state. |
| **10** WAT text parser | `frontend/wasm/wat.gleam` *(new)* + the `.wast` script command layer (conformance-facing) | Text → `«WASM-AST3»` (module + script commands); differential `wat_parse ≡ decode∘wat2wasm`. |
| **11** conformance expansion | `test/twocore/conformance/**` (extend) | Light up reftypes/bulk/multi-mem/mem64/spectest/WAT categories; report new pass/skip/fail honestly; differential vs `wasmtime`; the WAT-only files run from our parser. |
| **12** capstone | `test/twocore/conformance/**`, `test/**`, `docs/` | Full surface green under the full matrix; skip-count drop headline; conformance-neutral proof; SVG refresh; honest close. |

*(The `rt_state` memories-vector + imported-state ownership between 08/09/keystone is a known
seam to pin in reconciliation — flagged here so it is not double-owned.)*

---

## 5. How to claim & complete (same as Phases 1–4)

Read this page → your unit doc → [`specs/state.md`](../state.md). Set status `in-progress`; confirm
your freeze milestones; build to the Definition of Done (D8: **spec-cited** tests written against
the [WebAssembly spec](https://webassembly.github.io/spec/), doc comments on every public function,
`gleam format --check src test` clean, **zero warnings**, and your unit's conformance/interface
suite passing — "done" is *the suite passes*, never "it compiles"). Update `state.md` with what you
leave. When in doubt about a foundational decision, **ask the planner**. The manager QA-gates
(`format`/`build`/`test` + conformance `fail=0` + a spec-DoD read) and commits+pushes each unit to
`main`.

---

## 6. Deferred to Phase 6+ (explicit — stated, not dropped)

- **Phase 6 (SIMD):** the `v128` value type + fixed-width SIMD (~236 lane instructions) — the
  single largest WebAssembly proposal, given its own focused phase; **memory64** joins it if cut
  from Phase 5 per §H8.
- **A goal, not a deferred phase — "JS on the BEAM" via Porffor:** *any Porffor application runs via
  2core on the BEAM* (Porffor JS→WASM → `fe_wasm` → Core Erlang → BEAM). The completed WASM
  2.0-minus-SIMD surface makes Porffor's output largely runnable through `fe_wasm` today; the work
  remaining to reach the goal is a **Porffor-ABI `rt_host` shim** (Porffor's own runtime ABI, not
  WASI) — not yet built or tested.
- **Later:** the Erlang/Gleam frontend; exception-handling, GC (including the GC proposal's typed
  function references + `struct`/`array`/`i31` reference types), stack-switching, the component model;
  the single-`.beam` runtime-dispatch **B1** binding; tier-N numerics; a production C NIF for tier-N
  memory. **WASI** stays an `rt_host` implementation, out of core.
