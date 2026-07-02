# Unit 09 — Non-function imports + the `spectest` module + instantiation/link (H4)

> **One-to-two owners · Wave A · depends on `«RT3-SIG-FROZEN»` + `«INSTANTIATE3»` (keystone
> P5-01) and consumes `«IR3-FROZEN»`'s `ImportDecl`/`ExportDecl` state variants.** Read
> [`00-overview.md`](00-overview.md) (H1–H8, esp. **H4/H6**) first, then the keystone
> [`01-interface-freeze.md`](01-interface-freeze.md) once it lands (§ the instantiation contract),
> then Phase-3 [`07-rt-host-whitelist-open.md`](../phase-3/07-rt-host-whitelist-open.md) (the
> build-fixed handler registry you extend — it is the quality bar for D3a-clean host dispatch),
> Phase-2 [`11-capstone.md`](../phase-2/11-capstone.md) (the `load → instantiate → invoke`
> run-ABI + the one-instance-one-process cell you thread imports through), and Phase-4
> [`07-linker-profiles-compose.md`](../phase-4/07-linker-profiles-compose.md) (the `profiles`
> link surface you add to). Phases 1–4 are complete and green: **906 tests, 0 warnings,
> conformance 15747 / 411 / 0** under every shipped `(mode × state_strategy × mem_tier)` binding.

---

## Context

Every WebAssembly module that Phases 1–4 could not run because it *imports a global, table, or
memory* — or because it imports the official **`spectest`** host module, or because it is one half
of a **`(register …)`** multi-module link — is this unit's charter. Phase 1 shipped only the
**deny-all host boundary** (function imports, all denied); Phase 3 made that boundary a real
per-instance policy (`HostDenyAll` / `HostWhitelist` / `HostOpen`) but **added no host surface and
no non-function imports** (F8 explicitly deferred `spectest` to Phase 5). Phase 2's capstone
listed the exact files that stay skipped for want of this unit: `linking.wast`, `imports.wast`,
every global-/table-/memory-import file, and the `spectest`-importing majority of the suite.

The load-bearing distinction this unit makes real is **provided state vs. a capability boundary**
(H4): an imported **function** is a *capability* — it leaves the module's own values and is gated
by the deny-all/whitelist/open `HostPolicy` at each call site (`rt_host.call_host/3`, unchanged).
An imported **global / table / memory** is **provided state** — a value the *instantiation
contract supplies* to the new instance, wired into that instance's cell/record exactly like a
module-defined global/table/memory. It is **not** routed through `call_host`; it never touches the
capability boundary. The two seams stay cleanly separated (H4/H6): `call_host` gates *behaviour*,
the instantiation contract *supplies data*.

The second thing this unit makes real is **linking**: the WebAssembly spec instantiates a module
against a vector of **external values** the embedder resolves for its imports (spec
[§4.5.4 *Instantiation*](https://webassembly.github.io/spec/core/exec/modules.html#instantiation),
[§7.5 *module_instantiate*](https://webassembly.github.io/spec/core/appendix/embedding.html#embed-module-instantiate)).
An import with **no provider** — or a provider whose type does not **match** the declared import
type ([§4.5.4](https://webassembly.github.io/spec/core/exec/modules.html#instantiation),
matching relation [§3.2 *Import matching*](https://webassembly.github.io/spec/core/valid/matching.html))
— is a **link error** (the `.wast` `assert_unlinkable` case), which must fail **closed** (H6): the
instance is never created, and there is never an ambient default that silently fabricates a missing
import. The `(register "name" $mod)` script command makes a prior instance's **exports** resolvable
by a later module's imports — the Phase-1 multi-module **registry** (`test/…/conformance/registry.gleam`)
is the substrate, coordinated with the WAT/script harness (unit 10/11).

## Goal

> **Non-function imports run as provided state through a real, fail-closed instantiation/link
> contract, and the official `spectest` host module + the `(register)`/`(get)` mechanism work — so
> the many suite files that import `spectest` (and the `linking`/`imports` files) stop skipping.**

Concretely: (1) the instantiate seam takes an **import map** and wires provided imported
globals/tables/memories into the new instance's state as provided state; (2) an **unsatisfied or
type-mismatched import is a link-time failure** (fail-closed, never an ambient default); (3) the
official **`spectest`** module ships as a **build-fixed registry** in `rt_host` (a literal `case`,
no `apply/3`, D3a-clean) — its four globals, funcref table, memory, and `print*` functions; (4)
**export-of-state** (`ExportGlobal`/`ExportTable`/`ExportMemory`) lets `assert_return (get $m "g")`
and a later module's import read a prior instance's exported entity; (5) all of it is
**conformance-neutral by default** (H7) — an import-free module compiles **byte-identically** to
Phase-4 (the `instantiate/0` arity is unchanged) — and preserves **D3a** and **fail-closed**
(H6) exactly as the `call_host` boundary does.

## Files owned (single-owner / additive — D1)

- **`src/twocore/runtime/rt_host.gleam`** *(extend, single-owner-additive)* — the build-fixed
  **`spectest`** registry: the `print*` handler arms in `resolve_handler/2` (one arm each, no
  dispatch change — the Phase-3 F8 promise realised) and the `spectest` **state provider**
  (`spectest_export/1` → the four globals' raw bits + the table/memory limits).
- **`src/twocore/runtime/rt_state.gleam`** *(extend, single-owner-additive)* — the **imported-state
  wiring**: the `StateDecl`/`InstanceState` extension that lets provided externvals be installed
  into the fresh cell/record in place of freshly-built ones, and the **memories vector** field
  (opaque `List(Dynamic)`, coordinated with unit 08 — see §D and Open questions), plus the
  export-of-state field accessors both strategies share.
- **`src/twocore/runtime/profiles.gleam`** *(extend, single-owner-additive)* — the link surface:
  the build-fixed **`spectest_allow()`** whitelist constructor and the `safe_linked()` /
  `import_capable` binding the conformance harness links `spectest`-importing modules under (the
  fail-closed policy that admits exactly the `spectest` `print*` pairs).
- **`src/twocore/pipeline.gleam`** *(extend, single-owner-additive)* — the **link resolver** and the
  extended **instantiate seam**: `link_imports/2` (resolve a module's imports against the providers,
  fail-closed), the `Provided` externval type, `ImportError`, and the `instantiate`/`run_source`
  signatures that thread the resolved import map into the owned process.

> No new *stub-day-1* freeze is produced here — this unit is a leaf under `«INSTANTIATE3»`. It
> **coordinates** the generated `instantiate/1` codegen with unit **06** (emit_core owns the
> emitter — see §A/§F), the `rt_state` memories-vector field ownership with unit **08** (§D), and
> the `(register)`/`(get)`/`assert_unlinkable` harness plumbing with unit **11** (§E/§F).

## Deliverables & freeze milestones

**Consumes (frozen upstream):**

- `«IR3-FROZEN»` (P5-01) — the `ImportDecl` state variants `ImportGlobal(module, name, ty, mutable)`
  / `ImportTable(module, name, ref_ty, min, max)` / `ImportMemory(module, name, min_pages, max_pages,
  idx_type)`, the `ExportDecl` state variants `ExportGlobal(export_name, global_name)` /
  `ExportTable(export_name, table_name)` / `ExportMemory(export_name, mem_index)`, `RefType {
  FuncRef ExternRef }`, `IdxType { Idx32 Idx64 }`, `Module.memories: List(MemoryDecl)`,
  `TableDecl(name, ref_ty, min, max)`.
- `«RT3-SIG-FROZEN»` (P5-01) — the extended `rt_state` `StateDecl`/`InstanceState` shape (memories
  vector + tables + imported-state + segment drop-state), and the `rt_mem`/`rt_table` `fresh`/`new`
  signatures the spectest provider builds against.
- `«INSTANTIATE3»` (P5-01) — the frozen instantiation/link contract *shape*: the generated
  `instantiate/1(Imports)` (arity-`0` when import-free, H7) taking an ordered provided-value list,
  the `Provided` externval encoding, and the fail-closed link-resolution seam. **This unit authors
  the contract's semantics**; the keystone freezes only the *shapes/names* so units 06/11 compose
  against them.
- The Phase-3/4 `profiles.gleam` surface (`safe()`/`unsafe()`/`portable()`/`ceiling()`/`link/1`/
  `HostWhitelist`) and the `rt_host` dispatch (`call_host/3`, `resolve_handler/2`, `seed_policy/1`).

**Produces (this unit):**

- `rt_host.spectest_export/1` + the six `spectest` `print*` handler arms (§C).
- `rt_state`'s imported-state install seam + memories-vector field + export-of-state accessors (§D/§E).
- `pipeline.link_imports/2` + `Provided`/`ImportError` + the extended `instantiate`/`run_source` (§B/§F).
- `profiles.spectest_allow/0` + the import-capable Safe binding (§G).
- The spec-cited tests (§Verification): fail-closed unsatisfied/mismatched import, `spectest`
  state + `print*`, `(register)` → import, export-of-state `(get)`, and **conformance-neutral**
  byte-identity for every import-free prior module.

**Freeze:** produces no new milestone; it is a prerequisite (with 03/04/05/06/07/08 + the WAT
parser 10) for the conformance expansion (11) and the capstone (12).

## Depends on

| Needs | From | Why |
|---|---|---|
| `«IR3-FROZEN»` | P5-01 | the import/export state variants + `RefType`/`IdxType`/`MemoryDecl`/`TableDecl` this unit reads |
| `«RT3-SIG-FROZEN»` | P5-01 | the `StateDecl`/`InstanceState` extension shape it fills; `rt_mem.fresh`/`rt_table.new` the spectest provider calls |
| `«INSTANTIATE3»` | P5-01 | the `instantiate/1(Imports)` contract shape units 06/11 compose against |
| emit_core `instantiate/1` codegen | unit 06 | the *emitter* of the generated instantiate; this unit specifies the contract it must satisfy (§A/§F) |
| `rt_state` memories-vector field (co-owned) | unit 08 | pin who owns the field (§D / Open questions) |
| the `(register)`/`(get)`/`assert_unlinkable` harness | unit 11 | the script layer that drives `link_imports` + the registry (§E/§F) |

---

## A. The instantiation/link contract — «INSTANTIATE3» (the import externval model)

### A.1 The model: imports are *external values supplied at instantiation*

The WebAssembly spec instantiates `module` against a vector `externval*` — one **external value**
per import, in the module's **import-declaration order**, supplied by the embedder
([§4.5.4](https://webassembly.github.io/spec/core/exec/modules.html#instantiation)). An external
value is a *function address*, *table address*, *memory address*, or *global address* into the
store. In 2core the store is per-instance and process-local (E1, one-instance-one-process), so an
external value is one of four concrete term shapes:

```gleam
/// A resolved external value supplied to an instance for ONE of its imports (spec §4.5.4
/// externval). It is the OUTPUT of link resolution (§B) and the INPUT to the generated
/// `instantiate/1` — the "provided state" of H4. Distinct in kind from a capability: a host
/// FUNCTION import never becomes a `Provided`; it is dispatched by `rt_host.call_host` at its
/// call site, so a `Provided` is only ever a global/table/memory value.
pub type Provided {
  /// A provided global's CURRENT value as a raw bit pattern (D5 — i32/i64/f32/f64 all `Int`,
  /// never a BEAM double). `mutable` is carried for the fail-closed matching check (§B.2) and
  /// is not needed by the installer.
  ProvidedGlobal(bits: Int, ty: RefOrVal, mutable: Bool)
  /// A provided table externval — the OPAQUE `rt_table` value (built by the exporter or by the
  /// `spectest` provider). `rt_state` stores it as-is; `rt_table` owns its shape.
  ProvidedTable(value: Dynamic, ref_ty: RefType, min: Int, max: Option(Int))
  /// A provided memory externval — the OPAQUE `rt_mem` value. `min_pages`/`max_pages`/`idx_type`
  /// are carried for matching (§B.2); the installer stores `value` opaquely into the memories
  /// vector slot.
  ProvidedMemory(value: Dynamic, min_pages: Int, max_pages: Option(Int), idx_type: IdxType)
}
```

`RefOrVal` is the union of a numeric `ValType` and a `RefType` (a global may hold `externref`);
the keystone pins whether this reuses `ValType` directly (recommended — `ValType` already has
`TFuncRef`/`TExternRef`, so `ProvidedGlobal(bits, ty: ValType, mutable)` suffices). See Open
questions.

### A.2 The generated `instantiate` arity — conformance-neutral by construction (H7)

The generated entry today is `instantiate/0`: it builds a `StateDecl` from build-controlled
constant-folded values, seeds the cell (or returns the `InstanceState` record under `Threaded`),
runs active element → data segments → `start` (emit_core §emit_instantiate). This unit's contract
keeps that path **byte-identical for every module with no state import** and introduces a **new
arity only when the module actually imports a global/table/memory**:

| Module imports | Generated entry | Rationale |
|---|---|---|
| no non-function imports (the entire Phase-1..4 corpus) | **`instantiate/0`** — unchanged | H7 byte-identity: no argument, no new codegen; the prior `.beam` is bit-for-bit the same |
| ≥ 1 imported global/table/memory | **`instantiate/1(Imports)`** | `Imports` is the ordered list of provided **state** externvals (function imports excluded — they need no runtime value) |

`Imports` is a **positional list** in the order of the module's *state* imports (imported globals,
tables, and memories interleaved exactly as declared; a function import contributes **no** element).
emit_core (unit 06) bakes each position's *kind* and *local slot* statically from the `ImportDecl`
list, so `Imports` carries only the values, never any name/kind data — keeping the wiring
build-controlled (D3a: no data-driven dispatch on an import name at run time). Because imported
entities occupy the **low indices** of each index space (spec
[§2.5.1](https://webassembly.github.io/spec/core/syntax/modules.html#indices) — imports precede
definitions), each provided value maps to a fixed low slot; module-defined entities fill the
remaining slots with freshly-built values as today.

> **Why an argument, not a pdict seed.** `seed_fuel`/`seed_policy` are pdict seeds because fuel and
> the host posture are tier-O policy overlays, orthogonal to instance state. Provided **state** is
> instance state, so under `state_strategy: Threaded` (the `portable()` runs-anywhere build) it
> must **not** live in the process dictionary — it must flow as a value. Passing `Imports` as a
> function argument keeps `portable()` working with imports (the record-threading build never
> touches the pdict) and keeps a `Cell` build byte-identical to a value-argument seed. A pdict
> `seed_imports` alternative is recorded in Open questions and rejected for exactly this reason.

### A.3 Instantiation order (unchanged) with provided state spliced in

The generated `instantiate/1` runs the spec's instantiation order
([§4.5.4](https://webassembly.github.io/spec/core/exec/modules.html#instantiation)), with provided
externvals **installed as the initial cell state** *before* any segment writes:

1. `seed_fuel` (MeterFuel only) → `seed_policy` — **unchanged** pdict seeds (§Phase-3).
2. Build the `StateDecl` (§D) where **imported slots take their `Provided` value** and
   module-defined slots take freshly-built values (`rt_mem.fresh` / `rt_table.new` / const-folded
   global inits). Seed the cell (`Cell`) or `fresh` the record (`Threaded`).
3. Active **element** segments (`rt_table.init_elem`), then active **data** segments
   (`rt_mem.init_data`) — element **before** data, per spec order; each is trap-at-instantiation
   (an OOB active segment raises → instantiation fails, the modern `assert_uninstantiable` / legacy
   `assert_unlinkable` case, already modelled by Phase-2's `AssertUninstantiable` command).
4. `start` — runs against the fully-wired state (including provided imports).

Provided memory/table externvals are installed **opaquely** (rt_state never inspects them, §D), so
a provided memory can be written by an active data segment the same way a fresh one is — the
matching-checked provider guarantees the segment's `[offset, offset+n)` bound is meaningful.

---

## B. Import resolution + matching + fail-closed (the link resolver)

### B.1 The resolver: module imports × providers → ordered provided values

`link_imports` is the pure resolution seam (in `pipeline.gleam`). It turns a module's `ImportDecl`
list plus the set of **providers** (the `(register)`ed prior instances' exports + the build-fixed
`spectest`) into the ordered `Imports` list `instantiate/1` consumes — or a **fail-closed
`ImportError`**:

```gleam
/// A source of externvals for a `#(module, name)` import (spec §4.5.4 external values). Two
/// build-controlled providers only — there is NO ambient/data-driven provider (D3a):
///
/// - `Registered(name, exports)`: a prior instance registered under link-name `name` (the
///   `(register "name" $mod)` command); `exports` maps its exported-state names → externvals,
///   extracted via the export-of-state accessors (§E). Under snapshot semantics (§E.2) each is
///   the exporting instance's CURRENT value at register time.
/// - the built-in `spectest` module (resolved by `rt_host.spectest_export`, §C) — always present.
pub type Provider {
  Registered(link_name: String, exports: Dict(String, Provided))
}

/// A fail-closed link failure (spec §4.5.4 — an unprovided or mismatched import is a link error;
/// the `.wast` `assert_unlinkable` case). NEVER an ambient default: the instance is not created.
///
/// - `UnknownImport(module, name)`: no provider supplies `#(module, name)` — the spec phrase
///   "unknown import".
/// - `IncompatibleImportType(module, name, detail)`: a provider supplies it but its externtype
///   does NOT match the declared import type (§B.2) — the spec phrase "incompatible import type".
pub type ImportError {
  UnknownImport(module: String, name: String)
  IncompatibleImportType(module: String, name: String, detail: String)
}

/// Resolve every non-function import of `module` against `providers` (+ the built-in `spectest`),
/// producing the ordered `Imports` list for `instantiate/1` — or the FIRST link failure
/// (fail-closed, spec §4.5.4). Function imports contribute NO element (they are call-site
/// capabilities, §H4). Total; pure; no runtime dispatch.
///
/// - `module`: the IR module whose imports drive resolution (its `imports` order is the
///   `Imports` order).
/// - `providers`: the registry's `(register)`ed instances (unit 11 supplies these from
///   `registry.gleam`); `spectest` is always consulted in addition.
/// - Returns `Ok(provided_in_import_order)` when EVERY import is provided AND matches, else the
///   first `Error(ImportError)` — the instance is never instantiated (fail-closed, H6).
pub fn link_imports(
  module: ir.Module,
  providers: List(Provider),
) -> Result(List(Provided), ImportError)
```

The resolver walks `module.imports` **in order**; for each state import it (a) finds the provider
for `#(module, name)` (`spectest` special-cased to `rt_host.spectest_export`, then the `Registered`
providers by link-name), failing `UnknownImport` if none; (b) checks the provided externtype
**matches** the declared import type (§B.2), failing `IncompatibleImportType` otherwise; (c) emits
the `Provided`. Function imports are skipped (no value) — but a function import to `spectest` (e.g.
`print_i32`) is still validated to *exist* as a handler so `assert_unlinkable` fires when a bogus
`spectest` function is imported (see §C.3).

### B.2 Import matching (spec §3.2 / §4.5.4) — the fail-closed type gate

The provided externval's type must **match** (be a subtype of) the declared import type. The gate
is exact per external kind:

| Import kind | Match rule (provided `p` vs declared `d`) | Spec |
|---|---|---|
| **global** | `p.ty == d.ty` **and** `p.mutable == d.mutable` — globals are **invariant** (a mutable and an immutable global do not match either way) | [§3.2 global matching](https://webassembly.github.io/spec/core/valid/matching.html#globals) |
| **table** | `p.ref_ty == d.ref_ty` **and** limits match: `p.min ≥ d.min` **and** (`d.max == None` **or** (`p.max == Some(pm)` **and** `pm ≤ dm`)) | [§3.2 table matching](https://webassembly.github.io/spec/core/valid/matching.html#tables) |
| **memory** | `p.idx_type == d.idx_type` **and** limits match (same rule as table) | [§3.2 memory matching](https://webassembly.github.io/spec/core/valid/matching.html#memories) |
| **function** | provided handler's `FuncType` equals the declared `ty` (checked structurally, §C.3) | [§3.2 function matching](https://webassembly.github.io/spec/core/valid/matching.html#functions) |

The **limits matching direction** is load-bearing: the import declares what it *requires* (a floor
on `min`, a ceiling on `max`); the provided entity must actually satisfy it — `provided.min ≥
required.min` (the provider is at least as large) and `provided.max ≤ required.max` when the import
caps it. Getting this backwards silently admits an under-sized import; the tests (§Verification)
assert both a satisfying and a violating case for each rule, sourced from `linking.wast`.

### B.3 Fail-closed — no ambient default (H6, D3a)

The resolver **never fabricates** a missing import. There is no "zero global", no "empty table
fallback", no ambient memory: `UnknownImport` is returned and the instance is **not** created, so a
module that imports something 2core does not provide cannot run at all — matching the spec's link
error and the `assert_unlinkable` expectation. The only providers are (a) the build-controlled
`spectest` registry (a literal `case`, §C — no `apply/3`) and (b) instances a `.wast` script
**explicitly** `(register)`ed. No `#(module, name)` from program text is ever turned into a module
atom or an `apply/3` — the resolver reads names only to *select among build-controlled providers*,
never to *construct* a target (D3a, exactly as `rt_host` never builds a module atom from
`capability`/`name`).

---

## C. The `spectest` module — the build-fixed provider (`rt_host`)

The official suite's standard host module ships as a **build-fixed registry**, following the
Phase-3 `resolve_handler/2` pattern precisely (a literal `case`, no ambient authority, one arm per
name — the F8 promise: "spectest plugs into this same registry … one new arm each, no dispatch
change"). It has two faces: **host functions** (`print*`, dispatched by `call_host`) and **provided
state** (the globals/table/memory, supplied by the link resolver).

### C.1 The `print*` host functions — new `resolve_handler` arms (side-effecting, return nothing)

The six mandated functions are added as arms to the existing `resolve_handler/2`, under the
capability string `"spectest"`. Each **consumes its arguments and returns nothing** (the WASM
result type is `[]`), so its `HostHandler` (`fn(List(Int)) -> List(Int)`) returns `[]`:

| Name | WASM type | Handler |
|---|---|---|
| `print` | `[] -> []` | `fn(_) { [] }` |
| `print_i32` | `[i32] -> []` | `fn(_) { [] }` (may emit a side-effecting trace to stderr — see below) |
| `print_f32` | `[f32] -> []` | `fn(_) { [] }` |
| `print_i32_f32` | `[i32 f32] -> []` | `fn(_) { [] }` |
| `print_f64` | `[f64] -> []` | `fn(_) { [] }` |
| `print_f64_f64` | `[f64 f64] -> []` | `fn(_) { [] }` |

```gleam
fn resolve_handler(capability: String, name: String) -> Result(HostHandler, Nil) {
  case capability, name {
    "env", "identity" -> Ok(fn(args) { args })
    // ── Phase 5: the official `spectest` print family (spec test host module). Each consumes
    //    its args and returns [] (WASM result type []). Deterministic + node-safe (tier-P/O);
    //    a no-op body is spec-adequate (the suite NEVER asserts on print output). A trace to
    //    stderr, if any, is an effect the optimizer already treats as a `CallHost` barrier.
    "spectest", "print" -> Ok(fn(_args) { [] })
    "spectest", "print_i32" -> Ok(fn(_args) { [] })
    "spectest", "print_f32" -> Ok(fn(_args) { [] })
    "spectest", "print_i32_f32" -> Ok(fn(_args) { [] })
    "spectest", "print_f64" -> Ok(fn(_args) { [] })
    "spectest", "print_f64_f64" -> Ok(fn(_args) { [] })
    _, _ -> Error(Nil)
  }
}
```

Because these are ordinary `resolve_handler` arms, they are **denied unless the instance's
`HostPolicy` admits `#("spectest", name)`** — the fail-closed conjunction is unchanged (§D of
Phase-3). The conformance harness links `spectest`-importing modules under a **whitelist that
admits exactly the `spectest` pairs** (§G) — never `HostOpen`, so an unrelated host capability
stays denied. A no-op body keeps them deterministic and side-effect-free enough that they perturb
no optimizer differential; the honest option of a stderr trace is noted as a build-time toggle
(Open questions) since the suite never observes it.

### C.2 The `spectest` state provider — the four globals, the table, the memory

The provided *state* externvals are supplied by a new build-fixed `spectest_export/1` in `rt_host`,
consulted by `link_imports` when the import module is `"spectest"`:

```gleam
/// The build-fixed `spectest` module's exported STATE externvals (spec test host module). A
/// literal `case` — NO ambient authority (D3a); `name` selects among build-controlled results,
/// never constructs a target. Returns `Ok(Provided)` for a known export, `Error(Nil)` otherwise
/// (→ the resolver's `UnknownImport`). The reference values are the official spectest module's:
///
/// - `global_i32 : i32 = 666`, `global_i64 : i64 = 666`, `global_f32 : f32 = 666.6`,
///   `global_f64 : f64 = 666.6` — all IMMUTABLE. f32/f64 are stored as their raw IEEE-754 bit
///   pattern (D5), NEVER a BEAM double. (The EXACT f32/f64 bit pattern of 666.6 is pinned by the
///   keystone/decode literal encoder — flagged in Open questions rather than asserted here.)
/// - `table : funcref (min 10, max 20)` — a fresh empty funcref table (`rt_table.new(10, Some(20))`).
/// - `memory : (min 1, max 2)` pages — a fresh Idx32 memory (`rt_mem.fresh(1, Some(2), safe_cap)`).
///
/// The table/memory values are built through the SAME `rt_table.new`/`rt_mem.fresh` the importing
/// binding uses, so the tier matches (paged is the default/import-file tier; the tier-agnostic
/// build seam is flagged in Open questions).
pub fn spectest_export(name: String) -> Result(Provided, Nil)
```

The exact global constants (`666`, `666`, `666.6`, `666.6`) and the table/memory limits (`10..20`,
`1..2`) are the reference interpreter's `spectest` module (the spec's
[`test/core/imports.wast`](https://github.com/WebAssembly/spec/blob/main/test/core/imports.wast)
host module), transcribed faithfully. **`f32`/`f64` are raw bits (D5)** — the `666.6` literal's
exact 32-/64-bit pattern is decoded by the keystone's constant-folder, not asserted in this doc
(Open questions), so this unit stores whatever raw `Int` the pinned encoder yields, bit-exact.

### C.3 Function-import existence (why `spectest.print*` must be *checked*, not just dispatched)

A function import is a capability, not provided state — but a module importing `#("spectest",
"does_not_exist")` (a *function*) must still fail `assert_unlinkable` with "unknown import" per the
spec (the import has no provider). So `link_imports` checks each **function** import too: for a
`"spectest"` function import it verifies `resolve_handler("spectest", name)` is `Ok` **and** the
handler's declared `FuncType` matches the import's `ty` (§B.2 function matching, checked against a
build-fixed `spectest` signature table); a `Registered` module's function export is matched against
its recorded signature. A missing/mismatched function import is `UnknownImport` /
`IncompatibleImportType` at link time — it does **not** wait to be a runtime `call_host` denial.
This keeps the *link* failure (the module cannot be instantiated) distinct from the *call* denial
(the module instantiates but the capability is denied), both fail-closed, matching the spec's two
phases (link error at §4.5.4 vs. host-call trap at §4.4.7).

---

## D. Provided-state wiring in `rt_state` (imported-state + the memories vector)

### D.1 The extended `StateDecl` — provided slots interleaved with fresh ones

`rt_state`'s `StateDecl` (the fresh per-layer values the generated `instantiate` installs) is
extended so an **imported slot carries its provided value** instead of a fresh one. Today's
`StateDecl(mem, globals, table)` grows to the multi-memory + multi-table + imported shape (final
names frozen by the keystone; scoped against the provisional surface):

```gleam
/// What the generated `instantiate` passes to `seed`/`fresh` — the FRESH-OR-PROVIDED per-layer
/// values to install into a brand-new cell/record.
///
/// - `mems`: the instance's memories in index order (multi-memory, H3). A module-defined memory
///   is a fresh `rt_mem.fresh` value; an IMPORTED memory is its provided externval (installed
///   opaquely). Single-memory-index-0 modules have exactly one element ⇒ byte-identical to
///   Phase-4 (H7). Opaque `Dynamic` (rt_state never inspects a memory).
/// - `globals`: `#(name, raw_bits)` in declaration order; an imported global's pair is its
///   PROVIDED bits, a defined global's is its const-folded init (D5 raw bits).
/// - `tables`: the instance's tables by name (multiple tables, unit 07); a defined table is a
///   fresh `rt_table.new`, an imported table is its provided externval (opaque `Dynamic`).
/// - `dropped_data` / `dropped_elem`: the passive-segment drop-state (units 07/08) — a fresh
///   instance drops nothing; carried here so seed/fresh install it uniformly.
pub type StateDecl {
  StateDecl(
    mems: List(Dynamic),
    globals: List(#(String, Int)),
    tables: Dict(String, Dynamic),
    dropped_data: Set(Int),
    dropped_elem: Set(Int),
  )
}
```

The **crucial invariant** for this unit: `StateDecl` is *value-shaped* — the generated
`instantiate/1` splices each `Provided` externval into the right `mems`/`globals`/`tables` slot
**before** calling `seed`/`fresh`. So `rt_state` needs **no** knowledge of imports at all: it
receives a `StateDecl` whose imported slots already hold their provided values, and installs it
exactly as it installs a fresh one. This keeps `rt_state` opaque (it imports neither `rt_mem` nor
`rt_table` — the memory/table values stay `Dynamic`, per the standing no-circular-import rule) and
keeps the imported-state wiring a *codegen* concern (unit 06 weaves `Provided` → `StateDecl`
slot), not an `rt_state` concern. `rt_state`'s only additive work is holding the wider record
(`mems` vector, `tables` dict, drop-state) — the *shape* extension, both the `Cell` `seed` path and
the `Threaded` `fresh`/`build` path (the shared `build` constructor keeps them byte-identical, G7).

### D.2 The memories-vector field — ownership (coordinate with unit 08)

`InstanceState.mem: Dynamic` becomes `mems: List(Dynamic)` (multi-memory). **The field belongs in
`rt_state` and is single-owned by this unit** (P5-09), because `rt_state` is the state container and
this unit owns its `StateDecl`/`InstanceState` extension; **unit 08 (`rt_mem`) operates on the
memories *through a field seam*, not by owning the field** — exactly as unit 04/06 (Phase-4)
operate on the single `mem` field through `rt_state.mem`/`with_mem` without owning it. The seam
generalises to an index:

```gleam
/// Read memory `index` out of this process's cell (`Cell`) — opaque `Dynamic` for `rt_mem`.
/// Fail-closed: `panic`s on an un-seeded cell or an out-of-range index (both internal-invariant
/// violations, unreachable post-validation — validation bounds every memory index, §04).
pub fn mem_at(index: Int) -> Dynamic
/// Rebind memory `index` (`Cell`) — the read-modify-write for `rt_mem`.
pub fn with_mem_at(index: Int, mem: Dynamic) -> Nil
/// The threaded twins (`Threaded`, no pdict): project / rebind one memory of the record.
pub fn t_mem_at(st: InstanceState, index: Int) -> Dynamic
pub fn t_with_mem_at(st: InstanceState, index: Int, mem: Dynamic) -> InstanceState
```

This resolves the overview's flagged double-ownership ("the `rt_state` memories-vector +
imported-state ownership between 08/09/keystone is a known seam to pin"): **P5-09 owns the field +
the seam signatures; P5-08 (`rt_mem`) consumes the seam** to route a memory-indexed op to the right
vector element, and keeps the tier-specific memory *value* shape (`rt_mem` never leaks it through
`rt_state`, opacity preserved). The keystone doc-freezes the seam signatures in `«RT3-SIG-FROZEN»`
so 08 and 09 compose. (Recorded in Open questions for the reconcile pass to ratify.)

### D.3 Why provided memory/table are installed *opaquely* (opacity + the tier match)

A `ProvidedMemory.value` / `ProvidedTable.value` is stored into `StateDecl.mems`/`.tables`
**verbatim**, never inspected by `rt_state` (it holds `Dynamic`). The provider (`spectest` or a
registered instance) built the value through the *same* `mem_module`/`table_module` the importing
binding links, so `rt_mem`/`rt_table` can operate on it uniformly. Under `paged` (the import/spectest
tier) this is an immutable-binary value — a pure term, safely installed. Under `atomics`/`nif` a
memory value is a *reference*, which raises the cross-instance-aliasing question (§E.2 / Open
questions); the import/spectest suite files run under `paged`, so the shipped path is clean, and the
tier interaction is flagged, not silently assumed.

---

## E. Export-of-state + `(register)`/`(get)` (the accessor externval seam)

### E.1 Exporting a global/table/memory as an externval

For a later module to *import* — or an `assert_return (get $m "g")` to *read* — a prior instance's
exported global/table/memory, the instance must hand out that entity as an externval. emit_core
(unit 06) generates, for each new `ExportDecl` state variant, a **0-arity accessor export**:

| Export | Generated accessor `export_name/0` returns |
|---|---|
| `ExportGlobal(export_name, global_name)` | the global's **current** raw bits — `rt_state.global_get(global_name)` (`Cell`) / threaded read (`Threaded`) |
| `ExportTable(export_name, table_name)` | the opaque table externval — `rt_state`'s table-field projection |
| `ExportMemory(export_name, mem_index)` | the opaque memory externval — `rt_state.mem_at(mem_index)` |

These accessors run **inside the exporting instance's owned process** (state is process-local, E1),
so the harness reads an export by routing an `invoke export_name` into that process (the existing
`call_instance` seam). `(get $m "g")` (fixture `Get`) becomes exactly `invoke $m:export_name()` and
compares against the expected `SpecValue` — Phase-2 already stubbed `Get` as "unsupported"; this
unit makes it real for exported globals, and extends it to exported memory/table where a `(get)`
targets them (rare; globals are the common `(get)` case).

### E.2 `(register)` → import (snapshot semantics — the honest boundary)

`(register "name" $mod)` records `$mod`'s current exported-state externvals under link-name
`"name"` (the registry's `registered` map). When a later module imports `#("name", "g")`, the
resolver supplies the **externval captured at register/resolve time** (`Provided`). This is
**value/snapshot semantics**: the importing instance installs its *own copy* of the provided
memory/table/global (§D.3). This is:

- **Fully correct** for `spectest` (fresh state used by one importer) and for every immutable-global
  import and every linking assertion that does not mutate a **shared** entity across instances after
  linking — the large majority of `linking.wast` and all of `imports.wast`'s `spectest` cases.
- **Not faithful** for the advanced `linking.wast` cases that *mutate an imported mutable global or
  memory/table from one instance and observe it through another* — true aliasing requires a shared
  store entity, which the process-per-instance model (E1) does not provide by value. These
  assertions are an **honest, categorized skip** (never a silent mis-pass), exactly as Phase-2/4
  categorized their gaps. The faithful path (owner-routed handles, or a shared tier-O ETS/atomics
  store for exported-and-imported entities) is recorded in Open questions as deferred.

This boundary is stated explicitly so the conformance report (unit 11) categorizes the aliasing
skips honestly and does not overstate `linking.wast`.

---

## F. The pipeline instantiate seam + the run-ABI

### F.1 The extended `instantiate` — threading the resolved import map

`pipeline.instantiate` gains the resolved import map. To preserve every existing pure/import-free
caller (H7 byte-identity + the Phase-2/4 contract), the import-free path is unchanged and a new
import-aware entry is added:

```gleam
/// Instantiate a loaded module in its own owned process, wiring RESOLVED imports (§B) as
/// provided state (H4). The shim calls `instantiate/0` when `imports == []` (byte-identical to
/// Phase-4) or `instantiate/1(Imports)` otherwise; the strategy (Cell/Threaded) is self-detected
/// from the return, unchanged (P4-08 §C).
///
/// - `beam`/`mod`: as Phase-4.
/// - `imports`: the ordered provided-state externvals from `link_imports` (empty for an
///   import-free module).
/// - Returns `Ok(InstanceProc)` once seeded, or `Error(reason)` for an instantiation-time trap
///   (OOB active segment / trapping start). A LINK failure is surfaced BEFORE this (by
///   `link_imports`), so this function never sees an unresolved import.
pub fn instantiate_linked(
  beam: BitArray,
  mod: String,
  imports: List(Provided),
) -> Result(InstanceProc, String)
```

The existing `instantiate/2` remains as `instantiate_linked(beam, mod, [])` for import-free modules,
so `run_source`'s current call sites and the whole prior corpus are untouched. `link_imports` is run
**before** `instantiate_linked`; an `ImportError` is surfaced as an `Error("unlinkable: <phrase>")`
where `<phrase>` is the spec link phrase — `"unknown import"` for `UnknownImport`, `"incompatible
import type"` for `IncompatibleImportType` — so the harness's `assert_unlinkable` (a `.wast`
`assert_unlinkable "phrase"`) matches on the spec text (via the existing `trap_matches` /
phrase-contains predicate).

### F.2 The FFI shim arity (coordinate with unit 11)

`twocore_cli_ffi.start_instance` today applies `Module:instantiate()`. The import-aware path applies
`Module:instantiate(Imports)` when the module has state imports. The shim (owned by the
CLI/conformance harness, unit 11 — `twocore_cli_ffi.erl` / `twocore_conformance_ffi.erl`, both
`twocore_`-prefixed, single-owned there) discriminates arity from whether `imports` is empty; this
unit **specifies the contract** (call `instantiate/0` iff import-free, else `instantiate/1(Imports)`)
and flags the shim edit as unit 11's, not claiming those files (D1).

### F.3 The driver/registry loop (unit 11 substrate)

The conformance driver's per-command fold already carries a `Registry` (§`runner.gleam`). This
unit's contract slots in: on a `ModuleCmd`, the driver runs `link_imports(module_ir,
providers_from_registry)`; on success it `instantiate_linked`s and `registry.define`s the instance
**together with its exported-state externvals** (read via the §E accessors, in the instance's
process); on a link `Error` it records the module's instantiation result as a link failure (so
dependent `assert_unlinkable` asserts match and dependent `invoke`s skip). `Register` aliases the
instance's exports under the link-name (registry's `registered` map, unchanged). This is unit 11's
code; §F states the seam it calls.

---

## G. `profiles` — the `spectest` whitelist + the import-capable Safe binding

`spectest`-importing modules need a policy that **admits exactly the `spectest` `print*` pairs** and
nothing else — fail-closed, D3a-clean, never `HostOpen`. This unit adds the build-fixed whitelist
and the Safe binding the harness links these files under:

```gleam
/// The build-fixed allow-set for the official `spectest` host functions — exactly the six
/// `#("spectest", print*)` pairs (§C.1), nothing more. A LITERAL list in this module (D3a — no
/// data-driven allow-set); every other capability stays denied. Used to build the import-capable
/// Safe binding the conformance harness links `spectest`-importing modules under.
pub fn spectest_allow() -> List(#(String, String)) {
  [
    #("spectest", "print"), #("spectest", "print_i32"),
    #("spectest", "print_f32"), #("spectest", "print_i32_f32"),
    #("spectest", "print_f64"), #("spectest", "print_f64_f64"),
  ]
}

/// The **Safe** binding that admits the `spectest` host functions (a `HostWhitelist`, NEVER
/// `HostOpen`) — the fail-closed posture the conformance harness links `spectest`-importing
/// modules under. Identical to `safe()` except `host_policy: HostWhitelist(spectest_allow())`;
/// every non-`spectest` capability stays denied (the whitelist conjunction, Phase-3 §D). Total.
pub fn safe_spectest() -> Binding {
  Binding(..safe(), host_policy: HostWhitelist(spectest_allow()))
}
```

`safe_spectest()` is a **Safe** posture (mode `Safe`, deny-all for everything but the six vetted
`spectest` prints) — it is *not* an Unsafe opt-out, so the fail-closed enumeration (Phase-4 §E) is
unperturbed: `unsafe()`/`ceiling()` remain the only `mode: Unsafe` constructors. It composes with
`link/1` unchanged (it changes only `host_policy`, no tier/module field), so `link(safe_spectest())`
is `Ok` and the binding threads through the pipeline exactly as `safe()`.

---

## Effect / soundness / security note

- **Provided state is not a capability (H4).** An imported global/table/memory becomes instance
  state (a `Provided` spliced into the `StateDecl`), *never* a `call_host` target — so it cannot
  widen the capability surface. Host *functions* (incl. `spectest.print*`) remain gated by the
  per-instance `HostPolicy` at each call site; the import machinery adds no path around it.
- **No ambient authority survives the new surface (D3a).** The `spectest` provider is a literal
  `case` (`spectest_export` + the `resolve_handler` arms) selected by a build-controlled name — it
  **never** builds a module atom or `apply/3`s a data-derived name, exactly like Phase-3's
  `resolve_handler`. The link resolver reads `#(module, name)` only to *select among
  build-controlled providers* (the fixed `spectest` case + the explicitly-`(register)`ed instances),
  never to *construct* a runtime target. `spectest_allow()` is a literal list. Unit 06 extends the
  emit-side structural security-invariant test to the `instantiate/1` import path (no data-driven
  `apply` in the import wiring).
- **Fail-closed linking (H6).** An unsatisfied or mismatched import is an `ImportError` and the
  instance is **not** created — there is no ambient default, no fabricated zero/empty import
  (spec §4.5.4 link error / `assert_unlinkable`). Import matching (§B.2) rejects an under-sized
  table/memory or a mutability/type-mismatched global fail-closed. The `spectest` host functions
  are denied unless the instance is linked under `safe_spectest()`'s explicit whitelist — an
  unrelated capability stays denied.
- **`externref` opacity preserved.** A provided `externref` global flows as an opaque BEAM term
  (raw-bits/`Dynamic`, D5/H1) — Safe code holds and null-tests it but cannot forge or inspect it;
  the import path introduces no way to read the underlying host term.
- **Conformance-neutral (H7).** An import-free module emits `instantiate/0` byte-identically to
  Phase-4 (no argument, no new codegen); the extended `StateDecl` collapses to Phase-4's shape for a
  single-memory, single-table, import-free module (one-element `mems`, empty drop-sets), so `seed`/
  `fresh` materialise byte-identical state. The whole Phase-1..4 corpus + prior suite stay
  byte-identical under both strategies and every shipped tier.
- **Honest aliasing boundary (§E.2).** Snapshot semantics for `(register)`ed imports are correct
  for `spectest` and non-aliasing linking; genuine cross-instance shared mutation is a categorized
  skip, never a silent mis-pass — the worst case of the import machinery is a *reported skip* or a
  *fail-closed link error*, never a host escape or a wrong-but-green result.

## Verification — Definition of Done (D8)

Tests assert **spec behaviour** (link/instantiation semantics, `spectest` reference values), never
"whatever the code emits" (no change-detector tests). Cite the spec:
[§4.5.4 instantiation](https://webassembly.github.io/spec/core/exec/modules.html#instantiation),
[§3.2 import matching](https://webassembly.github.io/spec/core/valid/matching.html),
[§7.5 embedding](https://webassembly.github.io/spec/core/appendix/embedding.html), and the suite
files `imports.wast` / `linking.wast` / the `spectest`-importing corpus. **"Done" = the
import/`spectest`/link suite passes**, never "it compiles."

1. **Fail-closed unsatisfied import (spec §4.5.4).** A module importing `#("no_such_module", "g")`
   (a global) resolves to `Error(UnknownImport(...))` and `run_source` surfaces
   `Trapped`/`Error` with the phrase `"unknown import"`; the instance is never created. Assert the
   same for a missing `spectest` *function* import (`#("spectest", "not_a_print")`) — a link error,
   not a call denial.
2. **Fail-closed type-mismatch (spec §3.2 matching).** Assert `IncompatibleImportType` for each
   rule: (a) a global imported `const i32` but provided `mut i32` (mutability mismatch); (b) a
   global imported `i64` but provided `i32` (type mismatch); (c) a table imported `min 10` but
   provided `min 1` (limits violate `p.min ≥ d.min`); (d) a memory imported `max 1` but provided
   `max 2` (limits violate `p.max ≤ d.max`). Each surfaces `"incompatible import type"`. Also assert
   the **satisfying** counterpart of each admits (`Ok`).
3. **`spectest` provided state (reference values).** A module importing `spectest.global_i32` +
   `global_i64` + `global_f32` + `global_f64` reads back `666`, `666`, and the raw f32/f64 bit
   pattern of `666.6` (D5, bit-exact — the pinned literal, not a re-derived double). A module
   importing `spectest.memory` and storing/loading round-trips; a `memory.size` sees the provided
   `min 1`. A module importing `spectest.table` and `table.size` sees `10`. (Sourced from the
   official `spectest` module definition, cited in the test.)
4. **`spectest` `print*` dispatched under the whitelist, denied otherwise.** Under
   `safe_spectest()`, `call_host("spectest", "print_i32", [42])` returns `[]` (dispatched, side-effect
   only); under `safe()` (deny-all) the same call **denies** (the fail-closed default). A non-listed
   capability (`#("spectest", "print_i64")` — not in the mandated set) **denies** even under
   `safe_spectest()` (the whitelist conjunction). Each `print*` name's handler returns `[]`.
5. **`(register)` → import (export-of-state, snapshot).** Instantiate module `A` exporting a global
   `g = 7` and a memory; `(register "M" A)`; instantiate module `B` importing `#("M", "g")` and
   `#("M", "mem")`; `B` reads `g == 7` and stores/loads through the imported memory. Assert via the
   `(get)` path that `A`'s exported global reads `7` (spec `assert_return (get "M" "g")`).
6. **Export-of-state `(get)`.** `assert_return (get $m "g")` on a module-defined exported global
   returns its current value after a `global.set` invoke mutates it (the accessor reads the live
   cell). Assert an exported memory/table `(get)` where the suite uses it.
7. **Conformance-neutral byte-identity (H7).** For a representative Phase-1..4 module (import-free),
   assert the emitted `.core` and `.beam` are **byte-identical** to Phase-4 (`instantiate/0` arity
   unchanged, `StateDecl` collapses to the prior shape). Run the full prior conformance under
   `safe()` and assert `fail == 0`, pass unchanged.
8. **The suite lights up honestly.** The `spectest`-importing files + `imports.wast` +
   the non-aliasing `linking.wast` assertions move **skip → pass**; the cross-instance-aliasing
   `linking.wast` assertions are **categorized skips with a reason** (§E.2), never silent passes;
   the report is `fail == 0`.
9. **Gate.** `gleam format --check src test` clean; `gleam build` **zero warnings** (no `todo`,
   no unused params); **every public function doc-commented** with contract + failure modes (D8);
   `gleam test` green before and after (906 → 906 + the new cases). Done = the import/`spectest`/link
   suite passes.

## What this unit leaves

- **Unit 06 (`emit_core`)** — emits the generated `instantiate/1(Imports)` for import-bearing
  modules (arity `0` when import-free, H7), weaving each `Provided` externval into the right
  `StateDecl` slot from the static `ImportDecl` order; emits the export-of-state accessors (§E.1);
  extends the D3a structural security test to the import wiring. This unit specifies the contract;
  06 emits the code.
- **Unit 08 (`rt_mem`)** — consumes the `rt_state` memories-vector field seam (`mem_at`/`with_mem_at`
  + threaded twins, §D.2) to route memory-indexed ops; owns the tier-specific memory value shape.
  This unit owns the field + seam signatures; 08 owns the routing.
- **Unit 07 (`rt_table`)** — consumes the `StateDecl.tables` dict + provided-table install for
  multiple tables; owns the table value shape.
- **Unit 11 (conformance/harness)** — drives `link_imports` from the registry, edits the
  `twocore_*_ffi` shim to call `instantiate/0` vs `instantiate/1(Imports)` by import-presence,
  reads exported-state externvals for `(register)`/`(get)`, maps `ImportError` → the
  `assert_unlinkable` phrase, and categorizes the aliasing skips honestly. The `.wast` script layer
  (`register`/`get`/`assert_unlinkable`) is unit 10/11's.
- **Deferred, stated:** genuine **cross-instance shared-mutation** aliasing of imported
  mutable memories/tables/globals (owner-routed handles or a shared tier-O store) — a categorized
  skip in Phase 5, a faithful mechanism later. `print_i64` and the reference `spectest`'s
  `global_i64`-vs-`print_i64` completeness (the brief's set omits `print_i64`) — see Open questions.

## Open questions (for the planner / cross-unit reconcile)

1. **`instantiate/1` arity vs. a pdict `seed_imports` (recommend the argument).** This doc passes
   `Imports` as a **function argument** to `instantiate/1` (arity `0` when import-free) so
   `portable()`'s `Threaded` build never puts instance state in the pdict. The alternative — a
   pdict `rt_state.seed_imports(list)` seeded like `seed_fuel` — keeps `instantiate/0` arity stable
   (simpler FFI) but breaks the no-pdict-instance-state property under `Threaded`. **Recommend the
   argument; keystone to ratify the frozen `instantiate/1` shape** so unit 06 emits it and unit 11's
   shim calls it. (This is the load-bearing `«INSTANTIATE3»` decision.)
2. **`rt_state` memories-vector field ownership (recommend P5-09 owns the field, P5-08 consumes the
   seam).** The overview flags this as double-owned between 08/09/keystone. This doc claims the
   **field + `mem_at`/`with_mem_at` seam** for P5-09 (rt_state is the state container; this unit
   owns its `StateDecl`/`InstanceState` extension) and leaves the **routing** to P5-08 (rt_mem),
   mirroring Phase-4's `mem`/`with_mem` split. Reconcile must ratify or reassign; if P5-08 owns
   rt_state instead, this unit's imported-state install still only *shapes* the `StateDecl`, so the
   split is clean either way — but **exactly one** unit must own the file (D1).
3. **The exact f32/f64 bit pattern of `spectest`'s `666.6`.** Stored as raw bits (D5); this doc does
   **not** assert the 32-/64-bit encoding (to avoid a wrong-value assertion). The keystone/decode
   literal encoder pins it; the test sources it from the reference `spectest` module, not from a
   BEAM double. Confirm the encoder yields the reference interpreter's exact `666.6` f32/f64 bits.
4. **`print_i64` (and `global_i64`↔`print_i64` completeness).** The brief's mandated set omits
   `print_i64`, but the reference `spectest` module (and `imports.wast`) define/use it. **Recommend
   adding `print_i64 : [i64] -> []`** as a seventh arm + allow-pair, or the `imports.wast`
   `print_i64` cases stay a categorized skip. Planner to confirm the mandated set.
5. **Provider tier for `spectest.memory`/`table` under non-paged bindings.** `spectest_export` builds
   the table/memory via `rt_mem.fresh`/`rt_table.new` (paged, the import-file default tier). Under
   `atomics`/`nif` the value shape differs and a fresh spectest memory would need the tier's `fresh`
   — a tier-agnostic build seam. The import/spectest suite runs under `paged`, so this is not on the
   shipped path; flagged so the capstone (12) does not silently claim spectest under every tier.
6. **`Provided`/`ProvidedGlobal.ty` — reuse `ValType` vs. a new `RefOrVal`.** This doc sketches
   `RefOrVal`; since `ValType` already carries `TFuncRef`/`TExternRef` (H1), `ProvidedGlobal(bits,
   ty: ValType, mutable)` likely suffices. Keystone to pin the `Provided` encoding in
   `«INSTANTIATE3»`.
7. **`ImportError` home — `pipeline` vs. a new `link` module.** This doc puts `link_imports` +
   `ImportError` + `Provided` in `pipeline.gleam` (owned here). If the harness (unit 11) needs them
   without a pipeline dependency, a small `runtime/link.gleam` (new, single-owned) may be cleaner.
   Flagged; either composes.
</content>
</invoke>
