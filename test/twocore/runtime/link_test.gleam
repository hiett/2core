//// Spec-grounded tests for `runtime/link` — the non-function-import instantiation/link contract
//// (H4, R4). Assertions target the WebAssembly SPEC (link/instantiation semantics + the reference
//// `spectest` module values), never "whatever the code emits":
////
//// - **Fail-closed linking** — an unprovided import is `UnknownImport` and a type/limits-mismatched
////   one is `IncompatibleImportType`; the instance is never created (spec
////   [§4.5.4](https://webassembly.github.io/spec/core/exec/modules.html#instantiation), the
////   `.wast` `assert_unlinkable` case). NO ambient default is ever fabricated (H6/D3a).
//// - **Import matching** — globals are invariant (type + mutability); table/memory limits match in
////   the load-bearing direction `p.min ≥ d.min` / `p.max ≤ d.max` (spec
////   [§3.2](https://webassembly.github.io/spec/core/valid/matching.html)).
//// - **`spectest` reference values** — `global_i32/i64 = 666`, `global_f32/f64 = 666.6` (raw
////   IEEE-754 bits, D5), `table : funcref 10..20`, `memory : 1..2` (the spec's `imports.wast` host
////   module).
//// - **Positional, name-free `Imports`** — one `Provided` per STATE import in declaration order;
////   function imports contribute no element (they are call-site capabilities, H4).

import gleam/dict
import gleam/dynamic
import gleam/list
import gleam/option.{None, Some}
import gleeunit/should
import twocore/ir
import twocore/runtime/link.{
  type ImportError, type Provided, IncompatibleImportType, ProvidedFunc,
  ProvidedGlobal, ProvidedMemory, ProvidedRefGlobal, ProvidedTable, Registered,
  UnknownImport,
}
import twocore/runtime/rt_mem
import twocore/runtime/rt_state
import twocore/runtime/rt_table

/// A minimal module whose only content is `imports` — the fixture the resolver walks (every other
/// field empty, so `link_imports` sees exactly the imports under test in declaration order).
fn module_with_imports(imports: List(ir.ImportDecl)) -> ir.Module {
  ir.Module(
    name: "twocore@link@test",
    uses_numerics: False,
    memories: [],
    globals: [],
    imports: imports,
    functions: [],
    exports: [],
    data_segments: [],
    tables: [],
    elements: [],
    start: None,
  )
}

// ── 1. Fail-closed: unsatisfied import (spec §4.5.4 "unknown import") ─────────────

/// A global imported from a module 2core does NOT provide resolves to `UnknownImport`, and the
/// instance is never created (fail-closed, no ambient zero-global default). The spec phrase is
/// "unknown import".
pub fn unknown_state_import_fails_closed_test() {
  let m =
    module_with_imports([ir.ImportGlobal("no_such_module", "g", ir.TI32, False)])
  is_unknown(link.link_imports(m, []), "no_such_module", "g")
  |> should.be_true
  phrase_of(link.link_imports(m, [])) |> should.equal(Ok("unknown import"))
}

/// A MISSING `spectest` FUNCTION import (`#("spectest","not_a_print")`) is ALSO a link error
/// ("unknown import"), not merely a deferred call denial (§C.3) — the import has no provider.
pub fn unknown_spectest_function_fails_closed_test() {
  let m =
    module_with_imports([
      ir.ImportFn("spectest", "not_a_print", ir.FuncType([], [])),
    ])
  is_unknown(link.link_imports(m, []), "spectest", "not_a_print")
  |> should.be_true
}

// ── 2. Fail-closed: import type-mismatch (spec §3.2 matching) + satisfying counterparts ─

/// Global matching is invariant: a global imported `const i32` but provided `mut i32` (mutability
/// mismatch) and one imported `i64` but provided `i32` (type mismatch) both fail
/// `IncompatibleImportType`; the SATISFYING counterparts admit `Ok`. (spec §3.2 global matching.)
pub fn global_mismatch_and_match_test() {
  // (a) mutability mismatch: import const, provided mut.
  let provider =
    Registered("M", dict.from_list([#("g", ProvidedGlobal(0, ir.TI32, True))]))
  let import_const =
    module_with_imports([ir.ImportGlobal("M", "g", ir.TI32, False)])
  is_incompatible(link.link_imports(import_const, [provider]), "M", "g")
  |> should.be_true
  phrase_of(link.link_imports(import_const, [provider]))
  |> should.equal(Ok("incompatible import type"))

  // The satisfying counterpart (import mut, provided mut) admits, carrying the value through.
  let import_mut =
    module_with_imports([ir.ImportGlobal("M", "g", ir.TI32, True)])
  link.link_imports(import_mut, [provider])
  |> should.equal(Ok([ProvidedGlobal(0, ir.TI32, True)]))

  // (b) type mismatch: import i64, provided i32.
  let provider_i32 =
    Registered("M", dict.from_list([#("g", ProvidedGlobal(1, ir.TI32, False))]))
  let import_i64 =
    module_with_imports([ir.ImportGlobal("M", "g", ir.TI64, False)])
  is_incompatible(link.link_imports(import_i64, [provider_i32]), "M", "g")
  |> should.be_true
}

/// Table limits match in the load-bearing direction: a table imported `min 10` but provided
/// `min 1` violates `p.min ≥ d.min` ⇒ `IncompatibleImportType`; the satisfying `min 10` provider
/// admits. (spec §3.2 table matching.)
pub fn table_limits_mismatch_and_match_test() {
  let under =
    Registered(
      "M",
      dict.from_list([#("t", ProvidedTable(dynamic.nil(), ir.FuncRef, 1, None))]),
    )
  let m = module_with_imports([ir.ImportTable("M", "t", ir.FuncRef, 10, None)])
  is_incompatible(link.link_imports(m, [under]), "M", "t") |> should.be_true

  // A provider at least as large satisfies (p.min 10 ≥ d.min 10).
  let ok =
    Registered(
      "M",
      dict.from_list([
        #("t", ProvidedTable(dynamic.nil(), ir.FuncRef, 10, None)),
      ]),
    )
  link.link_imports(m, [ok])
  |> should.equal(Ok([ProvidedTable(dynamic.nil(), ir.FuncRef, 10, None)]))
}

/// Memory limits match in the load-bearing direction: a memory imported `max 1` but provided
/// `max 2` violates `p.max ≤ d.max` ⇒ `IncompatibleImportType`; a provider capped `≤ 1` admits.
/// (spec §3.2 memory matching.)
pub fn memory_limits_mismatch_and_match_test() {
  let over =
    Registered(
      "M",
      dict.from_list([
        #("mem", ProvidedMemory(dynamic.nil(), 1, Some(2), ir.Idx32)),
      ]),
    )
  let m =
    module_with_imports([ir.ImportMemory("M", "mem", 1, Some(1), ir.Idx32)])
  is_incompatible(link.link_imports(m, [over]), "M", "mem") |> should.be_true

  // A provider capped no larger than the import satisfies (p.max 1 ≤ d.max 1).
  let ok =
    Registered(
      "M",
      dict.from_list([
        #("mem", ProvidedMemory(dynamic.nil(), 1, Some(1), ir.Idx32)),
      ]),
    )
  link.link_imports(m, [ok])
  |> should.equal(Ok([ProvidedMemory(dynamic.nil(), 1, Some(1), ir.Idx32)]))
}

/// An imported reference-typed global (externref) matches on type + mutability like a numeric one
/// — the `ref_globals` parallel path (R8). A `funcref`-vs-`externref` type mismatch fails closed.
pub fn ref_global_match_and_mismatch_test() {
  let ext = dynamic.string("some-externref")
  let provider =
    Registered(
      "M",
      dict.from_list([#("r", ProvidedRefGlobal(ext, ir.TExternRef, False))]),
    )
  // Matching externref import admits, carrying the opaque value through.
  let m = module_with_imports([ir.ImportGlobal("M", "r", ir.TExternRef, False)])
  link.link_imports(m, [provider])
  |> should.equal(Ok([ProvidedRefGlobal(ext, ir.TExternRef, False)]))

  // funcref import vs externref provider ⇒ type mismatch.
  let m2 = module_with_imports([ir.ImportGlobal("M", "r", ir.TFuncRef, False)])
  is_incompatible(link.link_imports(m2, [provider]), "M", "r") |> should.be_true
}

// ── 3. `spectest` provided state — the reference values (spec's imports.wast host module) ─

/// The four `spectest` globals read back their reference values: `global_i32 = 666`,
/// `global_i64 = 666`, and `global_f32 = 666.6` / `global_f64 = 666.6` as their EXACT raw
/// IEEE-754 bit pattern (D5 — `0x4426A666` / `0x4084D4CCCCCCCCCD`, the f32/f64 nearest to `666.6`,
/// NOT a re-derived BEAM double). All immutable.
pub fn spectest_globals_reference_values_test() {
  link.spectest_export("global_i32")
  |> should.equal(Ok(ProvidedGlobal(666, ir.TI32, False)))
  link.spectest_export("global_i64")
  |> should.equal(Ok(ProvidedGlobal(666, ir.TI64, False)))
  link.spectest_export("global_f32")
  |> should.equal(Ok(ProvidedGlobal(0x4426A666, ir.TF32, False)))
  link.spectest_export("global_f64")
  |> should.equal(Ok(ProvidedGlobal(0x4084D4CCCCCCCCCD, ir.TF64, False)))
}

/// A module importing `spectest.global_i32` + `global_i64` resolves to the reference bits in
/// declaration order (the positional `Imports`). The immutable globals match a `const` import.
pub fn spectest_global_import_resolves_test() {
  let m =
    module_with_imports([
      ir.ImportGlobal("spectest", "global_i32", ir.TI32, False),
      ir.ImportGlobal("spectest", "global_i64", ir.TI64, False),
    ])
  link.link_imports(m, [])
  |> should.equal(
    Ok([
      ProvidedGlobal(666, ir.TI32, False),
      ProvidedGlobal(666, ir.TI64, False),
    ]),
  )
}

/// `spectest.table` is a REAL `funcref` table of `min 10` / `max 20`: its declared limits are
/// `10..20 funcref`, and once installed into a cell the table's `size` is `10` (spec's `spectest`
/// `(table 10 20 funcref)`).
pub fn spectest_table_is_real_test() {
  let assert Ok(ProvidedTable(value, ref_ty, min, max)) =
    link.spectest_export("table")
  ref_ty |> should.equal(ir.FuncRef)
  min |> should.equal(10)
  max |> should.equal(Some(20))

  // Install the provided table into a fresh cell and probe its size through `rt_table`.
  rt_state.seed_full(
    rt_state.FullDecl(mems: [], globals: [], tables: [value], ref_globals: []),
  )
  rt_table.size(0) |> should.equal(10)
}

/// `spectest.memory` is a REAL Idx32 memory of `min 1` / `max 2`: its declared limits are `1..2`,
/// and once installed its `memory.size` is `1` page (spec's `spectest` `(memory 1 2)`).
pub fn spectest_memory_is_real_test() {
  let assert Ok(ProvidedMemory(value, min_pages, max_pages, idx_type)) =
    link.spectest_export("memory")
  min_pages |> should.equal(1)
  max_pages |> should.equal(Some(2))
  idx_type |> should.equal(ir.Idx32)

  rt_state.seed_full(
    rt_state.FullDecl(mems: [value], globals: [], tables: [], ref_globals: []),
  )
  rt_mem.size_at(0) |> should.equal(1)
}

/// A non-existent `spectest` STATE export is `Error(Nil)` (→ `UnknownImport`) — the provider is a
/// closed set, never an ambient default.
pub fn spectest_unknown_export_is_error_test() {
  link.spectest_export("not_a_thing") |> should.equal(Error(Nil))
}

// ── 4. Function-import checking (spec §3.2 function matching, §C.3) ───────────────

/// A `spectest` FUNCTION import that EXISTS and whose signature MATCHES resolves `Ok` and
/// contributes NO positional state element (a function is a call-site capability, H4). A SIGNATURE
/// MISMATCH (right name, wrong type) fails `IncompatibleImportType`.
pub fn spectest_function_import_matching_test() {
  // print_i32 : [i32] -> []  — exists and matches ⇒ Ok, no state element.
  let ok =
    module_with_imports([
      ir.ImportFn("spectest", "print_i32", ir.FuncType([ir.TI32], [])),
    ])
  link.link_imports(ok, []) |> should.equal(Ok([]))

  // Right name, wrong signature ⇒ incompatible import type.
  let bad =
    module_with_imports([
      ir.ImportFn("spectest", "print_i32", ir.FuncType([ir.TI64], [])),
    ])
  is_incompatible(link.link_imports(bad, []), "spectest", "print_i32")
  |> should.be_true
}

/// A function import to a GENUINE host capability (`env`, not `spectest` and not a registered
/// module) is NOT link-checked — it is a call-site capability resolved by the `HostPolicy`, so it
/// neither errors nor contributes an element (`Ok([])`). This is why the existing corpus's `env`
/// function imports keep instantiating.
pub fn host_capability_function_import_not_link_checked_test() {
  let m =
    module_with_imports([
      ir.ImportFn("env", "anything", ir.FuncType([ir.TI32], [ir.TI32])),
    ])
  link.link_imports(m, []) |> should.equal(Ok([]))
}

// ── 5. (register) → import + positional, name-free ordering ──────────────────────

/// `(register "M" A)` then a later module importing `#("M","g")` reads the externval captured at
/// register time (snapshot semantics) — a registered global `g = 7` resolves to
/// `ProvidedGlobal(7, …)` (spec `assert_return (get "M" "g")` reads `7`).
pub fn registered_import_resolves_test() {
  let provider =
    Registered("M", dict.from_list([#("g", ProvidedGlobal(7, ir.TI32, False))]))
  let m = module_with_imports([ir.ImportGlobal("M", "g", ir.TI32, False)])
  link.link_imports(m, [provider])
  |> should.equal(Ok([ProvidedGlobal(7, ir.TI32, False)]))
}

/// The returned `Imports` is POSITIONAL and NAME-FREE: one `Provided` per STATE import in
/// declaration order, function imports contributing NO element. An interleaved
/// (fn, global, memory, fn, table) import list yields exactly [global, memory, table].
pub fn imports_are_positional_state_only_test() {
  let m =
    module_with_imports([
      ir.ImportFn("env", "f1", ir.FuncType([], [])),
      ir.ImportGlobal("spectest", "global_i32", ir.TI32, False),
      ir.ImportMemory("spectest", "memory", 1, Some(2), ir.Idx32),
      ir.ImportFn("spectest", "print_i32", ir.FuncType([ir.TI32], [])),
      ir.ImportTable("spectest", "table", ir.FuncRef, 10, Some(20)),
    ])
  // Exactly the three STATE imports, in order (function imports skipped).
  kind_tags(link.link_imports(m, []))
  |> should.equal(Ok(["global", "memory", "table"]))
  // The leading global is the reference i32 value.
  case link.link_imports(m, []) {
    Ok([ProvidedGlobal(bits, ..), ..]) -> bits
    _ -> -1
  }
  |> should.equal(666)
}

// ── 6. The weaving extractors (the `Provided` → `FullDecl` slot ABI for emit_core) ─

/// The extractors pull the right slot value out of a `Provided` (the ABI unit 06 weaves with):
/// numeric-global bits, reference value, and the opaque table/memory externvals round-trip.
pub fn weaving_extractors_round_trip_test() {
  link.provided_global_bits(ProvidedGlobal(0x7FC00001, ir.TF32, False))
  |> should.equal(0x7FC00001)

  let ext = dynamic.string("ext")
  link.provided_ref_value(ProvidedRefGlobal(ext, ir.TExternRef, False))
  |> should.equal(ext)

  let tbl = dynamic.string("tbl")
  link.provided_table_value(ProvidedTable(tbl, ir.FuncRef, 0, None))
  |> should.equal(tbl)

  let mem = dynamic.string("mem")
  link.provided_memory_value(ProvidedMemory(mem, 1, None, ir.Idx32))
  |> should.equal(mem)
}

// ── helpers ──────────────────────────────────────────────────────────────────────

/// `True` iff `r` is `Error(UnknownImport(module, name))`.
fn is_unknown(
  r: Result(List(Provided), ImportError),
  module: String,
  name: String,
) -> Bool {
  case r {
    Error(UnknownImport(m, n)) -> m == module && n == name
    _ -> False
  }
}

/// `True` iff `r` is `Error(IncompatibleImportType(module, name, _))` (the detail text is not
/// pinned — spec behaviour is the variant, not the diagnostic string).
fn is_incompatible(
  r: Result(List(Provided), ImportError),
  module: String,
  name: String,
) -> Bool {
  case r {
    Error(IncompatibleImportType(m, n, _)) -> m == module && n == name
    _ -> False
  }
}

/// Map a resolution result to the ordered list of provided KIND tags (or `Error(Nil)` on a link
/// failure) — asserts positional ordering + kind without pinning opaque values.
fn kind_tags(
  r: Result(List(Provided), ImportError),
) -> Result(List(String), Nil) {
  case r {
    Ok(ps) -> Ok(list.map(ps, kind_tag))
    Error(_) -> Error(Nil)
  }
}

fn kind_tag(p: Provided) -> String {
  case p {
    ProvidedGlobal(..) -> "global"
    ProvidedRefGlobal(..) -> "ref_global"
    ProvidedTable(..) -> "table"
    ProvidedMemory(..) -> "memory"
    ProvidedFunc(..) -> "func"
  }
}

/// Map a `link_imports` result to `Ok(spec-phrase)` on failure (`Error(Nil)` on success), so a
/// test can assert the exact `assert_unlinkable` phrase.
fn phrase_of(r: Result(List(Provided), ImportError)) -> Result(String, Nil) {
  case r {
    Ok(_) -> Error(Nil)
    Error(e) -> Ok(link.import_error_phrase(e))
  }
}
