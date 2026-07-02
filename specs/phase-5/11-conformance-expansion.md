# Unit P5-11 — Conformance expansion + differential

> **Owner: 1 agent · Wave B · depends on the whole Phase-5 pipeline + runtime (P5-01
> keystone, P5-03 decode, P5-04 validate, P5-05 lower, P5-06 emit_core, P5-07 rt_table,
> P5-08 rt_mem, P5-09 imports/spectest/linker, P5-10 the WAT parser).** Read
> [`00-overview.md`](00-overview.md) (decisions H1–H8) first, then the two template docs this
> mirrors — Phase-4 [`09-tier-differential.md`](../phase-4/09-tier-differential.md) (the
> `combos.binding_for` / `Outcome` differential seam this unit reuses **unchanged**) and Phase-1
> [`07-conformance-harness.md`](../phase-1/07-conformance-harness.md) (the fixture/oracle/registry/
> runner/driver machinery this unit **extends, never duplicates**). This unit owns a **test suite +
> the vendor allowlist/pin**, no production code. Its headline deliverable is a **number**: the
> pinned spec suite's **skip count drops materially** as whole categories light up (reference types,
> bulk memory & table, multi-memory, memory64, `spectest`-importing files, and the WAT-only files),
> **`fail` stays `0`, `pass` rises**, and the residual skips are **categorised and honest** (D9 — no
> silent truncation). Spec-first, never a change-detector (D8).

---

## Context

Phases 1–4 left the conformance harness at **15747 pass / 411 skip / 0 fail** under every shipped
`(mode × state_strategy × mem_tier)` binding — but that green is over a **deliberately narrow
allowlist**. The suite skips (or never allowlists) thousands of assertions that exercise the rest of
standardised WebAssembly, for exactly three reasons, each of which a Phase-5 unit now removes:

1. **The engine could not run the construct.** Reference types (`ref.null`/`ref.func`/`ref.is_null`,
   `table.get/set/size/grow/fill`, typed `select`, reference-typed & passive/declarative element
   segments), bulk memory & table (`memory.fill/copy/init`, `data.drop`, `table.init/copy`,
   `elem.drop`), multiple memories, and 64-bit memories all decoded/validated/lowered/ran nowhere.
   P5-03..P5-08 build them; this unit **turns the corresponding `.wast` files on**.
2. **The fixture imported `spectest` or non-function imports.** `linking.wast`/`imports.wast` and the
   many files that import `spectest`'s globals/table/memory/print-funcs skipped wholesale because the
   decoder skipped the import section and there was no `spectest` provider. P5-09 wires the
   instantiation/link contract + the build-fixed `spectest` module; this unit **drives those files
   through it and supplies the import environment**.
3. **The file was un-`wast2json`-able at the pin.** `memory.wast`/`memory_grow.wast`/`table.wast`
   (multi-memory / typed-ref / `2^32` literals at the pinned SHA) and text-syntax `assert_malformed`
   cases had no binary the decoder could eat. P5-10 gives us a first-class WAT text parser producing
   the **same `frontend/wasm/ast.gleam` Module** the binary decoder produces; this unit **routes the
   un-convertible files through OUR parser** instead of `wast2json`.

This unit is the **surface-completion phase's measuring instrument**. It does not add engine
behaviour; it **proves** — honestly, against the [WebAssembly spec](https://webassembly.github.io/spec/)
and differentially against `wasmtime` — that the behaviour the other ten units built is spec-correct,
under **both named modes and every `(state_strategy × mem_tier)` combination**, and it publishes the
one number that makes Phase 5 legible: **how far the skip count fell**.

## Goal

> **Light up the categories, report honestly, stay green everywhere.** Extend the vendor allowlist
> to the reference-types / bulk / multi-memory / memory64 / `spectest`-importing / WAT-only files;
> teach the harness the *values* and *actions* the new surface needs (reference values in
> `SpecValue`/oracle/invoke-ABI; exported-global `get`; the `spectest` + `(register)` import
> substrate; `assert_unlinkable`); route the un-`wast2json`-able files through the P5-10 parser;
> differentially check the new surface against `wasmtime` and prove `wat_parse(text) ≡
> decode(wat2wasm(text))`; and keep the whole thing at **`fail == 0`** under both profiles and the
> full `(state_strategy × mem_tier)` matrix. **Measurable done:** the pinned suite's **skip count
> drops materially** from the Phase-4 baseline of **411**, `pass` rises by the assertions the new
> files/categories contribute, the residual skips are enumerated by **category** (SIMD text, GC-
> proposal reftypes, `assert_exhaustion` stack-depth, and memory64-if-cut per H8), and the new
> surface is byte-identical across every shipped combination (H7) — never "it compiles".

## Files owned

All under `test/twocore/conformance/**` (D1 — this unit is the sole owner of the harness and the
vendor pin; it **extends** the P1-07 machinery in place). Nothing in `src/` is touched.

| Path | Change | Purpose |
|---|---|---|
| `vendor/ALLOWLIST` | **extend** | Add the reftype / bulk / table / multi-memory / memory64 / `spectest`-importing files + per-file `wast2json` flag columns; annotate the WAT-only files as parser-driven. |
| `vendor/PIN` | **review/bump** | Confirm (or bump) the testsuite SHA + wabt/wasmtime versions so the newly-allowlisted files convert and their baked expected values are trustworthy. |
| `vendor/vendor.sh` | **extend** | Route WAT-only files (un-convertible by `wast2json`) to a parser-driven path instead of dropping them; keep the `spectest-interp` self-check for convertible files. |
| `fixture.gleam` | **extend** | `SpecValue` reference variants (`NullRef`/`ExternRefVal`/`FuncRefVal`); decode reftype JSON values; the `assert_unlinkable` command kind. |
| `oracle.gleam` | **extend** | Reference-value comparison (null-by-type, externref-by-identity, funcref non-null). Still the single comparison authority. |
| `runner.gleam` | **extend** | Route `Get` → exported-global read; `AssertUnlinkable` → link-fail assertion; carry an **import environment** to `instantiate`; the reftype-aware `Driver` seam. |
| `driver.gleam` | **extend** | The reftype **term invoke-ABI**; `get_global`; build the `spectest` + registered-module import env; the `instantiate_ast` path for WAT-sourced modules. |
| `ffi.gleam` + `../../twocore_conformance_ffi.erl` | **extend** | Term-carrying invoke (`List(Dynamic)` in, `Dynamic` out); `mk_externref`/`classify_ref` helpers over the keystone's frozen reference representation. |
| `wat_fixture.gleam` | **new** | Adapter: P5-10's `wat.parse_script` output → the harness's `Fixture`/driving (converts WAT value literals → `SpecValue`, inline `ast.Module` → `instantiate_ast`). |
| `reference/wasmtime.gleam` + `reference/wasmtime_test.gleam` | **extend** | Tier-B differential over the new surface + the `wat_parse ≡ decode∘wat2wasm` equivalence. |
| `conformance_test.gleam` | **extend** | The category roll-up (honest skip histogram), the matrix wiring for the new tier-sensitive files, CI right-sizing. |
| `corpus/*.wat` + `*.expected` | **add** | A reftype / bulk-memory / multi-memory acceptance program with spec-sourced expected values (feeds the new-surface tier differential). |
| `refexpansion_differential_test.gleam` | **new** | The new-surface `(state_strategy × mem_tier)` differential over the added corpus programs (reuses `combos.binding_for` / `Outcome`). |
| `skipcount_test.gleam` | **new** | The headline: asserts the skip count is below a pinned ceiling **and** that the residual skips fall only into the enumerated honest categories. |

> `test/twocore/tier/**` (the P4-09 differential suite + `combos.gleam`) is **not owned here** —
> this unit *consumes* `combos.binding_for` / `combos.shipped` (public, D1) and adds its own
> conformance-side differential rather than editing P4-09's file. Adding a program to
> `combos.corpus_programs` would be an edit to P4-09's const; this unit instead drives its new corpus
> programs from its own `refexpansion_differential_test.gleam` (see §H, and the seam in Open questions).

## Deliverables & freeze milestones

**Consumes** (every Phase-5 freeze + the landed pipeline/runtime):
- `«IR3-FROZEN»` (P5-01) — the reference `ValType`s + `RefType`, the H2/H3 `Expr` nodes, the
  `Module.memories`/mem-index/`idx_type` shape, the import/export state variants, `TableDecl.ref_ty`,
  the passive/droppable segment model, and any new `TrapReason` (to name reftype/bulk trap phrases).
- `«RT3-SIG-FROZEN»` (P5-01) — the **reference value representation** (the null sentinel; the
  `funcref` type-tagged entry; the `externref` opaque-term shape), which the harness's `mk_externref`
  / `classify_ref` must match byte-for-byte to construct and inspect reftype invoke args/results.
- `«INSTANTIATE3»` (P5-01/P5-09) — the instantiation/link contract that takes an **import map** and
  wires provided global/table/memory state; the build-fixed `spectest` provider; the fail-closed
  unsatisfied-import behaviour (drives `assert_unlinkable`).
- The landed frontend (P5-03 decode / P5-04 validate / P5-05 lower), `emit_core` (P5-06), the runtime
  (P5-07 rt_table, P5-08 rt_mem), the imports/spectest/linker (P5-09), and the WAT parser (P5-10).

**Produces** (terminal for the conformance axis — the **capstone P5-12** consumes this unit's green +
skip-count to write the phase's honest close; nothing else builds on it): the expanded allowlist, the
reftype-aware harness, the WAT-only path, the new-surface differential, and the two headline tests
(`skipcount_test`, `refexpansion_differential_test`). This unit publishes **no** freeze milestone.

## Depends on (freeze milestones)

`«IR3-FROZEN»` · `«RT3-SIG-FROZEN»` · `«INSTANTIATE3»` — all from P5-01, plus the *landed*
implementations of P5-03..P5-10. Like P1-07's `Driver` seam, the harness machinery (fixture/oracle
value model, allowlist, WAT adapter shape) can be **built and self-tested against a stub driver**
before the pipeline lands; the compare-to-our-output assertions go green as each upstream unit lands
and flip fully green at the P5-12 capstone.

---

## A. The headline metric — the honest skip-count drop

The one number Phase 5's conformance story turns on. State it as a **before/after with a categorised
residual**, and pin it in a test so a regression (a category silently going dark, or a skip creeping
back) goes red.

### A.1 The baseline (Phase-4, measured)

| Metric | Phase-4 value | Source |
|---|---|---|
| **pass** | 15747 | `state.md` P4-11 row (each shipped combo reports the identical count) |
| **skip** | 411 | within-allowlist skips (reftype asserts, text `assert_malformed`, `assert_exhaustion`, …) |
| **fail** | 0 | the hard gate |
| whole files **excluded** from the allowlist | `memory` `memory_grow` `table` `elem` `select`(typed) `table_get/set/size/grow/fill/copy/init` `bulk` `memory_fill/copy/init` `data` `linking` `imports` + multi-memory + memory64 | ALLOWLIST "DEFERRED" comment block |

The 411 in-allowlist skips are **not** the whole gap — the larger gap is the **excluded files**
(each worth hundreds of assertions). So the headline is two movements at once: **411 in-allowlist
skips fall to a small categorised residual**, *and* **the excluded files enter the allowlist and add
their passes**.

### A.2 The after (what P5-11 must demonstrate)

- **Every allowlisted reftype/bulk/multi-mem file reaches `fail == 0`**, its assertions counted as
  `pass` (not skip). The previously within-file skips in `global.wast` (externref/funcref get/set),
  `call_indirect.wast` (the reftype multi-table module), and `select.wast` (typed `select`) **become
  passes**.
- **The residual skip set is enumerated and asserted closed** — the only permitted categories are:
  1. **SIMD** text/binary asserts (`v128`, lane ops) — Phase 6 (H8).
  2. **GC-proposal reference types** — typed function references, `struct`/`array`/`i31`,
     `call_ref`, `br_on_null` (H8: Phase 5 is `funcref`/`externref` only).
  3. **`assert_exhaustion`** (call-stack depth) — a BEAM-vs-WASM stack-model mismatch, not a surface
     gap; kept a categorised skip (as in Phase 1).
  4. **memory64 — only if cut per H8.** If memory64 lands, its files pass; if it is honestly deferred
     to Phase 6, its files are a **named file-level skip**, never a silent drop.
  5. **Threads / shared memory** (`atomics.wast` shared-memory forms) — a hard non-goal.
- **The skip-count ceiling is pinned** in `skipcount_test.gleam` (§A.3). The exact post-expansion
  numbers are **measured by the implementer against the vendored corpus, not fabricated here** — this
  doc pins the *shape* (a material drop + a closed residual), and the capstone records the concrete
  `pass / skip / fail`.

### A.3 The test that guards it

```gleam
/// The Phase-5 headline (H1 acceptance "conformance expansion"). Runs the full pinned suite once
/// (Safe profile) and asserts (a) fail == 0, (b) the skip count is at or below the pinned ceiling
/// `max_residual_skips` (a MATERIAL drop from the Phase-4 baseline of 411 — the exact ceiling is
/// set from the measured post-expansion residual), and (c) EVERY residual skip's reason matches one
/// of the enumerated honest categories (`allowed_skip_categories`) — so a NEW kind of skip (an
/// engine construct that quietly went dark) turns this red instead of silently inflating the count.
/// Non-vacuous: also asserts pass rose above the Phase-4 baseline (the categories genuinely lit up).
pub fn skip_count_dropped_and_residual_is_honest_test() {
  let total = run_full_suite(driver.pipeline())
  assert total.fail == 0
  assert total.pass > phase4_baseline_pass          // categories genuinely lit up
  assert total.skip <= max_residual_skips           // the material drop (pinned ceiling)
  let uncategorised =
    list.filter(total.skips, fn(reason) { !in_allowed_category(reason) })
  assert uncategorised == []                         // every residual skip is honest (D9)
}
```

`in_allowed_category` matches each skip reason against the five categories above by a stable phrase
(the runner already tags skips with a reason prefix — §D/§E extend those prefixes for the new paths).
`max_residual_skips` and `phase4_baseline_pass` are named constants the implementer sets from the
measured run and the capstone quotes; **the assert direction (skip ↓, pass ↑, residual closed) is the
spec-grounded invariant**, not the exact integers.

---

## B. Allowlist + pin — turning on the categories

The allowlist is the switch. Add the Phase-5 files with the `wast2json` flag column the pinned wabt
needs, mirroring the Phase-2 `align → --enable-memory64` convention already in the file.

### B.1 Files to add (grouped by category, with the flag each needs)

| Category | `.wast` files | `wast2json` flag (verify against `WABT_VERSION`) |
|---|---|---|
| **reference types** | `ref_null` `ref_func` `ref_is_null` `select` (typed) | *(default-on at wabt 1.0.41 — verify)* |
| **reference tables** | `table_get` `table_set` `table_size` `table_grow` `table_fill` `table_copy` `table_init` `table`(if convertible) | *(default-on — verify)* |
| **element segments** | `elem` (active + passive + declarative, expression-form) | *(default-on — verify)* |
| **bulk memory** | `bulk` `memory_fill` `memory_copy` `memory_init` `data`(`data.drop`) | *(default-on — verify)* |
| **multi-memory** | the multi-memory forms of `memory` / `memory_grow` (un-convertible at the pin → §E WAT path), the dedicated multi-memory files | `--enable-multi-memory` |
| **memory64** *(H8 deferrable)* | the memory64 forms / dedicated files | `--enable-memory64` |
| **imports / spectest** | `imports` `linking` (+ every file that imports `spectest`, now runnable) | *(default-on — verify)* |

> **Flag defaults are a verify-item, not an assertion.** wabt enabled reference-types and bulk-memory
> **by default** around 1.0.24+; at the pinned 1.0.41 they should be flagless. `--enable-multi-memory`
> and `--enable-memory64` are **not** default and must be in the flag column. The implementer confirms
> each file's required flags by running `wast2json` at the pin (the `vendor.sh` `spectest-interp`
> self-check is the guard) and flags any drift as an Open question rather than guessing.

### B.2 Pin discipline

The pinned `TESTSUITE_SHA` is already a **WASM-3.0-era** revision (the ALLOWLIST header states "root
file name == MVP is FALSE"), so reftypes/bulk/multi-memory/memory64 already live at this SHA — a
bump is likely **unnecessary**. Confirm the newly-added files exist at the pinned SHA and convert
cleanly; **only if** a needed file is absent or mis-converts at the pin do we bump `TESTSUITE_SHA`
(and re-record the wabt/wasmtime versions) — a deliberate, reviewed change, because the baked-in
expected values are only trustworthy against a known revision (P1-07 "Grounded facts").

### B.3 `vendor.sh` — the un-convertible files become parser-driven, not dropped

Today `vendor.sh` *skips* a file `wast2json` cannot convert (records it, moves on). For the WAT-only
files (§E) that skip becomes a **route change**: instead of a JSON fixture, `vendor.sh` copies the raw
`.wast` text into `fixtures/<name>.wast` (a new committed-subset artifact) so the runner can drive it
through the P5-10 parser. The `spectest-interp` self-check still gates every **convertible** file; the
parser-driven files are gated by the §F `wat_parse ≡ decode∘wat2wasm` differential instead.

---

## C. Reference values in the harness — `SpecValue`, oracle, and the term invoke-ABI

The invoke ABI is integer-only today (`call_instance(_, _, List(Int)) -> Result(Int, String)`;
`SpecValue` is i32/i64/f32/f64 + NaN). Reference values are BEAM **terms**, not integers, so three
layers extend in lock-step: the fixture value model, the oracle, and the marshalling FFI.

### C.1 `SpecValue` — reference variants (`fixture.gleam`)

wast2json encodes reference values as `{"type": "funcref"|"externref", "value": "null"|"<N>"}`
(VERIFY against wabt output — the exact `value` encoding for a non-null `funcref` is a verify-item;
`externref` non-null values are host-identity integers created by the test's `ref.extern N`).

```gleam
pub type SpecValue {
  I32Val(bits: Int)  I64Val(bits: Int)  F32Bits(bits: Int)  F64Bits(bits: Int)
  F32Nan(kind: NanKind)  F64Nan(kind: NanKind)
  // NEW (P5-11) — reference values:
  NullRef(ty: RefTypeTag)      // ref.null func | ref.null extern — a typed null sentinel
  ExternRefVal(id: Int)        // ref.extern N — a host extern with testable IDENTITY N
  FuncRefVal(index: Option(Int)) // a non-null funcref; identity is NOT compared (see oracle)
}

/// Which reference type a null / value expectation is tagged with (the spec JSON `type`).
pub type RefTypeTag { FuncRefTag  ExternRefTag }
```

Parsing (`parse_spec_value`): `"externref"` + `"null"` → `NullRef(ExternRefTag)`; `"externref"` +
`"<N>"` → `ExternRefVal(N)`; `"funcref"` + `"null"` → `NullRef(FuncRefTag)`; `"funcref"` + `"<N>"` →
`FuncRefVal(Some(N))`. (Today these fall through to an `I32Val` placeholder — that arm is replaced.)

### C.2 The oracle (`oracle.gleam`) — reference comparison

Per the spec's reference semantics (<https://webassembly.github.io/spec/core/exec/instructions.html#reference-instructions>
and the reference-types value model <https://webassembly.github.io/spec/core/syntax/types.html#reference-types>):

| `expected` | matches `actual` iff |
|---|---|
| `NullRef(t)` | `actual` is a null reference (either type — a null slot's type is not observable at the value layer; VERIFY whether the suite ever demands typed-null discrimination and tighten to `t == t'` if so) |
| `ExternRefVal(a)` | `actual == ExternRefVal(a)` — **externref identity is testable**: the test creates `ref.extern a`, the engine round-trips the *same* host term, and the id must match exactly |
| `FuncRefVal(_)` | `actual` is a **non-null** funcref — identity is **not** compared (our `funcref` is an opaque type-tagged table entry; the suite's funcref checks are null-vs-non-null, VERIFY) |

Null-ness and externref identity are the load-bearing, spec-observable properties; funcref identity
is deliberately *not* asserted (documented, not silently lenient). This keeps the oracle the single
comparison authority (D8) — no reference equality decided anywhere else.

### C.3 The term invoke-ABI (`ffi.gleam` + the `.erl` shim + `driver.gleam`)

To pass `ref.extern N` as an argument and read a reference back, the marshalling must carry **terms**,
not `Int`s. Add a term-typed invoke alongside the integer one (keep the integer path for the
overwhelmingly-common numeric case — byte-identical, conformance-neutral):

```gleam
/// Invoke `function` with reference/term args INSIDE the instance's owned process; `Ok(term)` is a
/// normal single result as an opaque BEAM term (a reference value / integer), `Error(reason)` a
/// trap. The term shape MUST match the keystone's frozen reference representation (`«RT3-SIG»`):
/// the null sentinel, the funcref type-tagged entry, the externref opaque term.
@external(erlang, "twocore_conformance_ffi", "call_instance_terms")
pub fn call_instance_terms(proc: Pid, function: Atom, args: List(Dynamic)) -> Result(Dynamic, String)

/// Construct the externref term a `ref.extern N` argument carries — the keystone's externref
/// representation wrapping host-identity `n` (Safe code cannot forge/inspect it; the harness is the
/// host, so it MAY construct one). CONTRACT with P5-01: this must be the exact shape emit_core /
/// rt_table treat as a non-null externref.
@external(erlang, "twocore_conformance_ffi", "mk_externref")
pub fn mk_externref(n: Int) -> Dynamic

/// Classify a returned reference term into the harness's value model. CONTRACT with P5-01: reads the
/// frozen null sentinel + externref/funcref shapes.
@external(erlang, "twocore_conformance_ffi", "classify_ref")
pub fn classify_ref(term: Dynamic) -> RefClass    // NullRef | ExternId(Int) | FuncRef | NotARef
```

`driver.invoke` then chooses the ABI by argument/result **type**: a call whose args and single result
are all numeric uses the existing integer path (unchanged — the numeric corpus stays byte-identical);
a call touching a reference uses `call_instance_terms`, mapping each `SpecValue` arg to a term
(`spec_to_term`) and each returned term back to a `SpecValue` at the export's declared reference type
(`tag_ref`). The export→result-type table (`export_types`) already carries `ir.ValType`; extend `tag`
to map `TFuncRef`/`TExternRef` results through `classify_ref`.

> **The externref term shape is a cross-unit contract, not a harness invention.** The keystone
> (H1/§H1) says the null sentinel and the externref/funcref representation are *frozen by P5-01*. The
> harness must construct and inspect exactly those. If P5-01's chosen representation is not
> host-constructible from the test side (e.g. it hides externref behind an unexported opaque type),
> that is an Open question for reconcile — flagged, not worked around.

---

## D. Exported state, the `Get` action, and the `spectest` + `(register)` substrate

The biggest unlock (H4) is that `spectest`-importing files stop skipping. Three harness changes make
it real; all three route through P5-09's instantiation/link contract — the harness **supplies** the
import environment and **asserts** fail-closed behaviour, it does not implement linking.

### D.1 `Get` → exported-global read

`assert_return (get $m "g")` reads an exported global; today `run_return`/`run_trap` skip `Get` with
"no globals". `spectest` exports `global_i32/i64/f32/f64`, and `elem`/`global`/`imports` files do
`(get …)`. Add a `Driver` seam and route `Get`:

```gleam
// runner.Driver gains:
get_global: fn(Instance, String) -> InvokeResult,   // read exported global `field`; Returned([v]) | DriverError

// run_return / run_trap Get arm:
Get(field, module) ->
  case resolve_instance(reg, module) {
    Ok(inst) -> judge(driver.get_global(inst, field), expected)   // via the oracle, same as invoke
    Error(why) -> skip(rep, at(src, line) <> why)
  }
```

`driver.get_global` calls the generated exported-global accessor P5-09 emits (or reads the instance
cell through a runtime accessor), tagging the result at the global's declared `ValType` (including a
reference-typed global → §C). The accessor's exact shape is P5-09's `ExportGlobal` wiring — a
cross-unit contract (Open questions).

### D.2 The import environment — `spectest` + registered modules

`instantiate` must receive an **import map** so P5-09 can wire provided state. Extend the `Driver` and
the runner to thread it:

```gleam
/// The values a module's imports resolve against: the build-fixed `spectest` module plus every
/// currently-registered instance's exports. Assembled by the runner from the registry, consumed by
/// the driver → P5-09's instantiation contract (which wires provided global/table/memory state and
/// FAILS CLOSED on an unsatisfied import).
pub type ImportEnv {
  ImportEnv(modules: Dict(String, InstanceExports))   // "spectest" is always present
}

// Driver.instantiate changes:  fn(BitArray) -> …   ⟶   fn(BitArray, ImportEnv) -> Result(Instance, String)
```

- **`spectest` is build-fixed (H4/H6).** P5-09 ships it as a literal registry (`global_i32=666`,
  `global_i64`, `global_f32`, `global_f64`, a `funcref` table `10..20`, a `memory` `1..2` pages, and
  the side-effecting `print*` functions). The harness obtains its exports from P5-09 (a fixed
  provider) and seeds `ImportEnv` with `"spectest" → spectest_exports`. **No `apply/3`, no ambient
  authority** — the harness passes a value set, the linker matches names (D3a intact).
- **`(register "name" $mod)`** — the registry already aliases instances (`registry.register`). The
  runner, on `register`, adds the aliased instance's **exports** to the `ImportEnv` under the link
  name, so a later module importing `"name" "export"` resolves against module A's provided state.
- **Unsatisfied import ⇒ link-time failure** (fail-closed, H6). See D.3.

> **Depth honesty (cross-unit).** Full cross-module *mutable* linking (module B imports and writes
> module A's memory — `linking.wast`) requires shared mutable state across two `one-instance-one-
> process` instances, which the E5 isolation model makes genuinely hard. `spectest`'s imports are
> used **read-mostly** (immutable globals; a provided table/memory read through), which is the
> primary unlock and works cleanly. The full mutable-import depth is **P5-09's instantiation
> contract**, not this unit's — P5-11 drives `linking.wast`/`imports.wast`, reports whatever passes,
> and **categorises the residual honestly** (a shared-mutable-import skip is a named category, not a
> silent drop). Flagged in Open questions.

### D.3 `assert_unlinkable` — the fail-closed import proof

`imports.wast`/`linking.wast` carry `assert_unlinkable` (a well-formed, valid module that **fails at
link/instantiation because an import is unsatisfied or type-mismatched**). Today it falls through
`Unhandled → skip`. Model it and assert fail-closed (this is the H6 security proof for imports):

```gleam
// fixture.Command gains:
AssertUnlinkable(line: Int, filename: String, text: String)   // valid, but linking MUST fail

// runner: load bytes + the current ImportEnv, instantiate, and REQUIRE a link failure whose phrase
// contains `text` ("unknown import" / "incompatible import type" / …). A success is a FAIL.
```

A `Ok(_instance)` where the spec demands `unlinkable` is a **real failure** (an unsatisfied import
that silently linked would be ambient authority — exactly what D3a forbids). A compile-stage
rejection of an out-of-scope construct is distinguished from a genuine link failure by the driver's
error prefix (as `run_uninstantiable` already distinguishes `instantiate:`), so an out-of-scope skip
is never counted as a link-fail pass.

---

## E. The WAT-only path — driving un-`wast2json`-able files through P5-10

The real payoff of the WAT parser (H5): `memory.wast` / `memory_grow.wast` / `table.wast` (and the
text-syntax `assert_malformed` cases) that `wast2json` cannot convert at the pin now run **from our
own parser**. The seam is a new adapter; the driver gains an **AST instantiation path** (validate/
lower serve the WAT-produced `ast.Module` unchanged — H5).

### E.1 The adapter (`wat_fixture.gleam`, new)

P5-10 owns `src/frontend/wasm/wat.gleam`, which (per H5) parses both the module text format and the
`.wast` script format. Because `wat.gleam` is in `src/`, it **cannot** produce test-side types
(`fixture.Command`/`SpecValue`); it produces its own `src`-side script model. This unit adapts it:

```gleam
/// Parse a `.wast` text file (P5-10) and adapt it into the harness's Fixture-driving model:
/// converts each WAT script command to the runner's execution, mapping WAT value literals to
/// `SpecValue` and inline `(module …)` text to an `ast.Module` driven via `Driver.instantiate_ast`
/// (NO binary re-encode — validate/lower serve the WAT AST directly, H5). Total; a parse failure is
/// a categorised skip, never a panic. CONTRACT with P5-10: the exact shape of `wat.parse_script`'s
/// output (command list; inline modules as `ast.Module`; value literals as raw-bit tagged) is
/// P5-10's to publish — this adapter is the sole consumer.
pub fn run_wat_fixture(driver: Driver, path: String) -> runner.Report
```

Two `(module …)` sub-forms need explicit handling (both appear in `assert_malformed` text cases):
- `(module quote "…")` — the quoted body is WAT text to parse (a malformed one must be **rejected**).
- `(module binary "…")` — an inline binary blob (route to the existing `check_frontend`/`instantiate`
  byte path, not the parser).

### E.2 The `instantiate_ast` driver seam

```gleam
// runner.Driver gains (the WAT path — skips decode, enters at validate):
instantiate_ast: fn(ast.Module, ImportEnv) -> Result(Instance, String),
check_frontend_ast: fn(ast.Module) -> Result(Nil, String),   // for text assert_invalid

// driver.gleam: reuse validate → lower → pipeline.ir_to_core(_, binding) → build → start_instance,
// entering at `validate` with the WAT-produced AST instead of `decode`. Everything downstream is
// SHARED with the binary path (H5: one validate/lower, two frontends).
```

### E.3 The differential that trusts the parser (§F cross-reference)

A parser-driven file has no `spectest-interp` self-check (it never became JSON). Its trust comes from
the §F `wat_parse(text) ≡ decode(wat2wasm(text))` differential over a corpus **plus** the baked-in
`assert_return`/`assert_trap` values in the `.wast` itself (which the parser reads directly — the
expected answers are still spec-sourced, Tier-A, not engine-derived).

---

## F. The new-surface differential (Tier-B `wasmtime` + `wat_parse ≡ decode∘wat2wasm`)

Two differential obligations, both extending `reference/wasmtime.gleam` (Tier-B — never on the
Tier-A path; the `.wast` files still carry their own expected values):

### F.1 `wat_parse(text) ≡ decode(wat2wasm(text))` (H5 DoD)

For a corpus of `.wat` inputs spanning the Phase-5 surface (reftypes, bulk, multi-memory, inline
import/export abbreviations, folded expressions), assert the P5-10 parser and the binary path produce
the **same runnable behaviour**:

```gleam
/// For each `.wat` in the differential corpus: (a) wat2wasm(text) → bytes → decode → validate →
/// lower → run  ≡  (b) wat.parse_module(text) → validate → lower → run, over a set of exported
/// invokes. Byte-identical results + identical traps (D7). Where feasible, ALSO assert structural
/// AST equality (`wat.parse_module(text) == decode(wat2wasm(text))`). This is the H5 promise that
/// the parser is a faithful second frontend, not a fixture crutch — a parser bug (a mis-folded
/// expression, a dropped abbreviation) diverges (a) from (b) and goes red on the exact input.
pub fn wat_parse_equiv_decode_test()
```

`wat2wasm` is the pinned reference for this differential (already a `vendor/PIN` prerequisite); it
skips gracefully when wabt is absent (like the existing `wasmtime.available()` guard), recorded — the
CI pin installs it.

### F.2 `wasmtime` differential over the new surface

For **authored / random** inputs where the spec `.wast` carries no baked answer (the Tier-B role),
cross-check the new numeric/memory surface against `wasmtime` 46: bulk `memory.fill/copy/init` byte
images, multi-memory routing, memory64 large-offset arithmetic. Honest scope: `wasmtime` prints ints
as signed decimal and floats as decimal (not raw bits — see the adapter's module docs), and it does
**not** print reference identities usefully, so **reftype identity stays Tier-A** (baked-in `.wast`
expected values via the oracle). The `wasmtime` differential covers the *numeric/memory* new surface;
the *reference* surface is proven against the spec's own baked answers. Both are spec-grounded (D8) —
neither is a change-detector.

---

## G. Full matrix × both profiles — tier-sensitivity of the new files + CI sizing

The new files are exactly the **tier-sensitive** ones (memory/table/reference stores), so they must
be green under **every** `(state_strategy × mem_tier)` combination (H7) — and that is precisely where
a tier bug hides. But re-running every new file ×5 combos risks the CI OOM the Phase-4 capstone
already fought ("right-size the Phase-4 full-matrix conformance so CI doesn't OOM").

### G.1 What runs under the matrix

- **Both named profiles** (`spec_suite_safe_test` / `spec_suite_unsafe_test`) run the **whole**
  expanded allowlist — the conformance-neutral + optimizer-soundness proof (F7/H7) now covers the new
  surface too. A reftype/bulk assertion that the Aggressive optimizer perturbs goes red here.
- **The five shipped combos** (`combos.shipped`) run the **tier-sensitive** files —
  reftype/table/bulk/memory/multi-memory — under `cell×paged`, `threaded×paged`, `cell×atomics`,
  `threaded×atomics`, `cell×nif`. This is the H7 "byte-identical across every combination" proof
  applied to the new stores: a mis-endianned `atomics` bulk-copy, a `threaded` table record dropped
  across a `table.set`, an `ets` table miss on `table.get` → red on the exact file.

### G.2 CI right-sizing (extend `matrix_skip_numeric`, don't gut coverage)

The existing `matrix_skip_numeric` already excludes the ~13.5k-assertion pure-numeric files from the
×5 matrix (they are tier-invariant by construction — the two full-profile runs cover them). Extend
the **same honest principle**, not a coverage cut:

- **Keep** every tier-sensitive new file in the ×5 matrix (that is the whole point).
- If a *specific* new file is both large and tier-invariant (e.g. a reftype **validation-only** file
  with no memory/table runtime state), add it to `matrix_skip_numeric` with a documented reason (it
  cannot differ across tiers; the profile runs cover it) — never for convenience, always with the
  tier-invariance justification the existing entries carry.
- If total matrix memory is still too high, **partition by combo** (run subsets of files under
  subsets of combos such that every tier-sensitive file is covered by every relevant tier at least
  once) rather than dropping files — and record the partition so coverage stays auditable. Flag the
  exact CI budget as an Open question for the capstone's CI config.

### G.3 memory64 under the matrix (H8)

If memory64 lands, its files run under the `paged`/`atomics` tiers like every other memory file (64-
bit addressing is a decode/validate/rt_mem concern, tier-orthogonal). **If memory64 is cut per H8**,
its allowlist entries are a **named file-level skip** in both the profile and matrix runs — the
skip-count test (§A.3) counts them in the `memory64-if-cut` category, never silently.

---

## H. New acceptance corpus programs (tier differential of the new surface)

The pinned suite proves spec-correctness; the P4-09 `combos` differential proves **byte-identity
across tiers** on a small, fast, spec-`.expected`-bearing corpus. Phase 5's new stores deserve the
same tight differential. Add three programs (authored `.wat` → `wat2wasm` → `.wasm`, `.expected`
sourced from the spec / cross-checked by `wasmtime`):

| Program | Exercises | Spec anchor for `.expected` |
|---|---|---|
| `reftab.wat` | `ref.func`/`ref.null`/`ref.is_null`, `table.get/set/grow/size/fill`, a null-slot `call_indirect` → `uninitialized element` trap | reference & table instructions <https://webassembly.github.io/spec/core/exec/instructions.html#table-instructions> |
| `bulkmem.wat` | `memory.fill/copy` (overlap = memmove), `memory.init` + `data.drop`, an out-of-range bulk op → `out of bounds memory access` **with no partial write** | memory instructions <https://webassembly.github.io/spec/core/exec/instructions.html#memory-instructions> (eager-bounds, H2) |
| `multimem.wat` | two memories, a store to memory 1 + load from memory 0 (independent regions), a `memory.copy` **across** memories | multi-memory (memory-index immediate on every memory op, H3) |

`refexpansion_differential_test.gleam` drives these under `combos.shipped` via the reused
`combos.binding_for` / `Outcome` machinery: each program's `Outcome` must (a) match `.expected` and
(b) be byte-identical across every shipped combination (the P4-09 two-assertion pattern, D7/D8). The
overlap-correct copy and the trap-before-write invariant are the load-bearing spec corners (H2/H6) —
a tier that did a naïve forward copy or wrote before checking bounds diverges here.

> **Seam note:** these programs live in `conformance/corpus/**` (this unit's), and the differential
> lives in `conformance/**` (this unit's), reusing `combos.binding_for` (public). It does **not** add
> them to `combos.corpus_programs` (P4-09's const) — that would double-own P4-09's file. If the
> capstone wants them in the canonical tier-differential list, that is a P4-09/P5-12 reconcile
> decision (Open questions).

---

## Effect / soundness / security note

- **The harness cannot make an unsound engine look sound (D8/H6).** Every expected value is
  spec-sourced (the baked-in `.wast` answers for Tier-A; the IEEE/reference-semantics rules for the
  oracle; `wasmtime` for authored Tier-B). "Green" means *every spec-observable was preserved* —
  values by bit pattern (D5/D7), traps by spec phrase, references by null-ness/externref-identity —
  not "it compiled". A wrong/missing bulk-op trap, a lost table store, an unsound optimizer pass, or
  a tier that diverges byte-for-byte all turn a **specific file** red.
- **Fail-closed imports are proven, not assumed (H6/D3a).** `assert_unlinkable` (§D.3) asserts an
  unsatisfied/mismatched import **fails at link time** — a silent link would be exactly the ambient
  authority D3a forbids. The `spectest`/host registry the harness draws from is P5-09's build-fixed
  literal (no `apply/3`), so no test-side machinery introduces ambient authority.
- **`externref` opacity holds across the seam (H1/H6).** The harness is the *host*, so it may
  construct externref terms (`mk_externref`) and inspect returned ones (`classify_ref`) — that is the
  host's privilege, not Safe code's. The property under test is that **Safe WASM** can hold/pass/
  null-test an externref but never forge or read one; the harness verifies round-trip **identity**
  (the same term comes back), which is precisely the opacity contract observed from outside.
- **Floats-as-bits throughout (D5/D7).** Reference expansion changes nothing here: numeric results
  and `.expected` values remain raw bit patterns; NaN stays class+payload matched; the new reference
  variants are orthogonal to the float path.
- **Isolation is unchanged (E5).** Every instance is one-process; the harness never spawns a second
  process against one instance's memory. Cross-module linking shares *provided state values* through
  P5-09's contract, not raw processes; the shared-**mutable**-import depth stays P5-09's concern and
  is reported honestly, never faked green.

---

## Verification — Definition of Done (D8)

- **Headline (§A) green.** `skipcount_test`: `fail == 0`; `pass` **above** the Phase-4 baseline
  (15747); `skip` **at or below** the pinned material-drop ceiling; and **every** residual skip in one
  of the five enumerated honest categories (SIMD / GC-reftypes / `assert_exhaustion` / memory64-if-cut
  / threads) — a new uncategorised skip goes red. The concrete post-expansion `pass / skip / fail`
  are **measured and recorded** (capstone), not asserted as magic integers.
- **Categories lit up (spec-cited).** The allowlisted reftype files (`ref_null`/`ref_func`/
  `ref_is_null`/`table_get`/`table_set`/`table_size`/`table_grow`/`table_fill`/`table_copy`/
  `table_init`/`elem`/`select`) and bulk files (`bulk`/`memory_fill`/`memory_copy`/`memory_init`/
  `data`) reach `fail == 0` with their assertions counted as **passes**; the previously within-file
  skips in `global`/`call_indirect`/`select` become passes. Trap corners cited: null-slot
  `call_indirect` → **uninitialized element**; out-of-range bulk op → **out of bounds memory/table
  access** with **no partial write** (H2/H6).
- **Reference oracle (§C) green.** Self-tests: `NullRef` matches a null of either type; `ExternRefVal`
  matches **by identity** and rejects a different id; `FuncRefVal` matches any non-null funcref and
  rejects null; the term invoke-ABI round-trips `ref.extern N` (arg → engine → result) with `N`
  preserved. Cited: reference value model + instruction semantics.
- **`spectest` + `(register)` (§D) green.** A `spectest`-importing file instantiates against the
  build-fixed provider and its `assert_return (get "global_i32")` / imported-table `call_indirect`
  pass; a `(register …)` cross-module invoke resolves; `assert_unlinkable` on an unsatisfied import
  **fails closed** with the spec phrase.
- **WAT-only path (§E) green.** At least one previously un-`wast2json`-able file (e.g. `memory.wast`
  at the pin) runs **from the P5-10 parser** to `fail == 0`; a `(module quote …)` malformed case is
  rejected; the `wat_parse ≡ decode∘wat2wasm` differential (§F.1) is green over the corpus.
- **Differential (§F) green.** The new numeric/memory surface agrees with `wasmtime` on authored
  inputs; the parser-equivalence differential agrees (both skip gracefully + recorded when wabt/
  wasmtime absent, installed+pinned in CI).
- **Matrix + both profiles (§G) green.** The whole expanded allowlist is `fail == 0 && pass > 0`
  under `profiles.safe()` **and** `profiles.unsafe()`; the tier-sensitive new files are `fail == 0`
  under **every** `combos.shipped` combination and **byte-identical** across them (H7); the new-
  surface corpus differential (§H) matches `.expected` and is byte-identical across combos. CI stays
  within budget (the documented `matrix_skip_numeric`/partition, coverage auditable).
- **Repo gate.** `gleam format --check src test` clean; `gleam build` **zero warnings**; `gleam test`
  green (≥ the current 906, now higher); every new public function carries a contract doc comment.
  **Done = the expanded suite passes** under real backends, never "it compiles".

---

## What this unit leaves

The Phase-5 surface is **proven runnable and spec-correct**: the reference-types / bulk / multi-
memory / (memory64-if-landed) / `spectest`-importing / WAT-only categories are green, the skip count
has **materially dropped** with a **categorised, honest** residual, the new surface is byte-identical
across every shipped `(state_strategy × mem_tier)` combination and under both modes, and it is
differentially checked against `wasmtime` and against the binary path via the WAT parser. This unit
consumes the whole Phase-5 pipeline and emits nothing downstream except the number and the green.

**Its sibling / consumer:** the **capstone P5-12** quotes this unit's measured `pass / skip / fail`,
refreshes `docs/wasm-conformance.svg` to Phase-5 scope, and writes the phase's honest close (what was
proved; what — SIMD, memory64-if-cut, full mutable cross-module linking — stays deferred).

**Deferred (stated, not dropped):** SIMD (Phase 6); memory64 if cut per H8 (Phase 6, named file-level
skip, never silent); full cross-module **mutable** linking depth (gated by P5-09's instantiation
contract — driven and reported here, not guaranteed); GC-proposal reference types (typed function
references, `struct`/`array`/`i31`, `call_ref`). *JS on the BEAM via Porffor* is a **goal** the
completed surface now largely enables (gated on a Porffor-ABI `rt_host` shim), not a deferred phase.
`assert_exhaustion` stays a categorised skip (a BEAM/WASM stack-model mismatch, not a surface gap).

---

## Open questions (for the planner / cross-unit sync)

1. **Externref term shape must be host-constructible (P5-01 / P5-07).** §C.3's `mk_externref` /
   `classify_ref` require the keystone's frozen `externref`/`funcref`/null-sentinel representation to
   be constructible **and** inspectable from the test side. If P5-01 hides the reference value behind
   an unexported opaque type with no host constructor, the harness cannot pass `ref.extern N` or judge
   a returned reference. **Ask:** P5-01 exposes a host-side `externref_of(Int)` + a reference
   classifier (or documents the term shape) as part of `«RT3-SIG-FROZEN»`.
2. **The `.wast` script-command seam with P5-10 (D1 boundary).** `wat.gleam` is in `src/` and cannot
   emit test-side `fixture.Command`/`SpecValue`. This unit assumes P5-10 publishes a `src`-side
   `wat.parse_script(text) -> Result(Script, WatError)` whose `Script` carries inline modules as
   `ast.Module` and value literals as raw-bit-tagged values, and that **this unit's `wat_fixture.gleam`
   is the sole adapter** to the harness model. **Ask:** confirm P5-10 owns the parser (src) and P5-11
   owns the adapter (test) — the overview's "the `.wast` script command layer (conformance-facing)"
   phrasing under unit 10 is ambiguous about which side owns the adapter. Pin it in reconcile.
3. **The import-environment threading changes the `Driver` signature.** §D makes
   `Driver.instantiate: fn(BitArray, ImportEnv) -> …` (was `fn(BitArray) -> …`) and adds
   `get_global` / `instantiate_ast` / `check_frontend_ast`. That is a change to a P1-07-authored type
   this unit now owns — benign (this unit owns `runner.gleam`), but P4-09's `combos.gleam` and the
   tier suite construct `Driver`s via `driver.pipeline_with`, which stays source-compatible only if
   the new `Driver` fields are added with defaults / the existing callers are updated. **Ask:** verify
   no P4-09 test breaks, or coordinate the one-line update.
4. **`spectest` provider handle (P5-09).** §D.2 needs P5-09 to expose the build-fixed `spectest`
   exports to the harness (a fixed provider function). **Ask:** P5-09 publishes `spectest_exports()`
   (or equivalent) as part of `«INSTANTIATE3»`.
5. **New-surface corpus in the canonical tier list (P4-09 / P5-12).** §H's programs run from this
   unit's own differential, not `combos.corpus_programs`. If the capstone wants them in the canonical
   list, that is a P4-09-const edit — decide ownership in reconcile.
6. **memory64 in/out (H8) is a scheduling input.** The allowlist flag column and the skip category
   both branch on whether memory64 lands (P5-08). **Ask:** confirm the memory64 go/no-go before the
   allowlist is finalised, so the `--enable-memory64` files are either driven or named-skipped, never
   silently dropped.
7. **`wast2json` feature-flag defaults at the pin (verify-item, not an assertion).** §B.1 assumes
   reference-types/bulk-memory are default-on at wabt 1.0.41 and multi-memory/memory64 need explicit
   flags. Confirm empirically against `WABT_VERSION`; any drift (or a needed `TESTSUITE_SHA` bump for
   a missing file) is a reviewed pin change.
