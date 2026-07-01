//// `rt_table_ets` — the tier-O, closure-native funcref-table backend (owner: unit P4-06).
//// A **private, process-local ETS table** mapping slot-index → `#(FuncType, closure)`,
//// behind the frozen uniform `rt_table` interface (keystone §B.2). A pure module swap the
//// linker (unit 07) resolves for `table_tier: TableEts`; nothing about the generated code or
//// the `call_indirect` seam changes (G5/G7).
////
//// **The 3-fault fail-closed dispatch is byte-identical to `TablePaged`** (§F, unchanged from
//// P2-05, <https://webassembly.github.io/spec/core/exec/instructions.html>): the three guards
//// fire in spec order and return the three distinct `TrapReason`s —
//// 1. `index` in `[0, size)` — else `UndefinedElement`;
//// 2. slot filled (an ETS entry present) — else `UninitializedElement`;
//// 3. exact STRUCTURAL `FuncType` match — else `IndirectCallTypeMismatch`.
//// The order is observable: an OOB index traps `UndefinedElement` BEFORE any null/type check;
//// a null in-range slot traps `UninitializedElement` BEFORE any type comparison.
////
//// **No ambient authority (D3a).** The dispatched target is ALWAYS a build-controlled closure
//// supplied by the generated `instantiate` via `init_elem`/`t_init_elem` (`emit_core` captures
//// a compile-time-literal `'twocore@wasm@<mod>':'f<idx>'/arity` inside it). ETS stores the
//// closure term natively; dispatch invokes it DIRECTLY as `target(args)` (a fun application).
//// This module constructs NO module/function atom from its inputs and calls NO `erlang:apply/3`
//// on data-derived names — the ONLY runtime-data input reaching a control transfer is the
//// integer `index`.
////
//// **Process-local; tier-O never NIF (G6/G8).** The ETS table is `private` (a second process
//// cannot read it) and UNNAMED (no node-global name to collide), owned by the instance process
//// under the one-instance-one-process contract (E1). It is process-local mutable storage, never
//// shared memory. ETS is OTP-native/memory-safe; there is no `nif` table tier, so Safe permits
//// it. A `private` ETS table is not GC'd while the process lives, so `new` deletes the prior
//// table this process owns before creating a fresh one (the §C re-instantiation lifecycle).
////
//// **Fail-closed on an un-seeded cell (E3).** The cell-backed ops read the handle via
//// `rt_state.table_get`, which raises (a node-safe internal error) on an un-seeded cell rather
//// than fabricating an empty table that silently "succeeds"; the threaded ops require the
//// handle present in `st.table`.
////
//// **Both op families.** The **cell-backed** family (`new`/`init_elem`/`call_indirect`, reached
//// through the pdict cell) and the **threaded** family (`t_init_elem`/`t_call_indirect`, over
//// an `InstanceState`) both compose with this tier (§C — tier and state-strategy are
//// orthogonal). Because ETS is mutated IN PLACE, a threaded op returns the SAME `st` (the `tid`
//// is unchanged; nothing to re-inject) — the §10 uniform-threading rule.

import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option, None, Some}
import twocore/ir.{
  type FuncType, type TrapReason, IndirectCallTypeMismatch, TableOutOfBounds,
  UndefinedElement, UninitializedElement,
}
import twocore/runtime/rt_state.{type InstanceState}

/// The ETS-backed funcref table handle (opaque; carried as `Dynamic` in the `table` slot).
///
/// - `tid`: the PRIVATE, unnamed `set` ETS table owned by the instance process, keyed
///   `slot_index -> #(FuncType, closure)` (ETS stores the closure term natively). A stable
///   reference: a mutating op writes THROUGH it in place, so the handle value is unchanged.
/// - `size`: the number of slots — the declared `min`. Fixed at `new` time (no runtime
///   `table.grow` in the MVP); `call_indirect`'s bounds guard checks `index` against it.
type EtsTable {
  EtsTable(tid: Dynamic, size: Int)
}

// ───────────────────────────── the `ets` FFI (twocore_-namespaced shim) ─────────────────────────────

/// Create a fresh PRIVATE `set` ETS table owned by this process, first deleting any prior table
/// this process created (§C lifecycle — no leak on re-instantiation). Returns the opaque `tid`.
@external(erlang, "twocore_rt_table_ets_ffi", "new")
fn ets_new() -> Dynamic

/// Insert the opaque type-tagged `entry` at slot `key`, mutating the table IN PLACE (a `set`
/// upsert). `entry` is the `#(FuncType, closure)` term, boxed as `Dynamic` (both closure ABIs
/// coerce to the same stored shape). Returns `Nil`.
@external(erlang, "twocore_rt_table_ets_ffi", "insert")
fn ets_insert(tid: Dynamic, key: Int, entry: Dynamic) -> Nil

/// Read slot `key`: `Ok(entry)` (the stored `#(FuncType, closure)` term as an opaque `Dynamic`)
/// when the slot is filled, or `Error(Nil)` when it is null/absent (the guard-2 signal).
@external(erlang, "twocore_rt_table_ets_ffi", "lookup")
fn ets_lookup(tid: Dynamic, key: Int) -> Result(Dynamic, Nil)

// ───────────────────────────── opaque `Dynamic` coercions (identity at run time) ─────────────────────────────

/// Coerce an `EtsTable` handle into the opaque `Dynamic` the cell / threaded record stores.
/// Identity at run time (`gleam_stdlib:identity/1`); tier-O, cannot fail.
@external(erlang, "gleam_stdlib", "identity")
fn ets_to_dynamic(t: EtsTable) -> Dynamic

/// Coerce the cell / record's opaque `Dynamic` back into an `EtsTable`. Identity at run time;
/// sound because `rt_table_ets` is the sole producer of the term held in the `table` slot.
@external(erlang, "gleam_stdlib", "identity")
fn dynamic_to_ets(value: Dynamic) -> EtsTable

/// Box a CELL-family entry (`#(FuncType, fn(List(Int)) -> List(Int))`) as the opaque `Dynamic`
/// ETS stores. Identity at run time; the cell family is the sole reader of what it inserts.
@external(erlang, "gleam_stdlib", "identity")
fn cell_entry_to_dynamic(e: #(FuncType, fn(List(Int)) -> List(Int))) -> Dynamic

/// Unbox a stored entry back to the CELL-family shape. Identity at run time; sound because a
/// cell-inserted entry is only ever read by the cell family.
@external(erlang, "gleam_stdlib", "identity")
fn dynamic_to_cell_entry(d: Dynamic) -> #(FuncType, fn(List(Int)) -> List(Int))

/// Box a THREADED-family entry as the opaque `Dynamic` ETS stores. Identity at run time; the
/// threaded family is the sole reader of what it inserts.
@external(erlang, "gleam_stdlib", "identity")
fn threaded_entry_to_dynamic(
  e: #(FuncType, fn(InstanceState, List(Int)) -> #(List(Int), InstanceState)),
) -> Dynamic

/// Unbox a stored entry back to the THREADED-family shape. Identity at run time; sound because a
/// threaded-inserted entry is only ever read by the threaded family.
@external(erlang, "gleam_stdlib", "identity")
fn dynamic_to_threaded_entry(
  d: Dynamic,
) -> #(FuncType, fn(InstanceState, List(Int)) -> #(List(Int), InstanceState))

/// Read just a stored entry's `FuncType` tag (for `to_canon`), leaving the closure opaque.
/// Identity at run time; sound for any family (the type tag is element 0 regardless of ABI).
@external(erlang, "gleam_stdlib", "identity")
fn dynamic_to_type_entry(d: Dynamic) -> #(FuncType, Dynamic)

// ───────────────────────────── construction (both strategies) ─────────────────────────────

/// Build a FRESH ETS-backed table of `min` null (uninitialised) slots, returned as the opaque
/// `Dynamic` the cell / threaded record stores.
///
/// - `min`: the table's initial entry count (the declared minimum). Becomes the fixed `size`;
///   the ETS table starts empty, so a `call_indirect` to any in-range slot before an element
///   segment fills it traps `UninitializedElement`.
/// - `max`: optional maximum entry count. UNUSED in the MVP — funcref tables cannot grow
///   (`table.grow` is a post-MVP reference-types op) and are only ever filled via `init_elem`.
/// - Returns the fresh handle. Side effect: creates a PRIVATE ETS table and (§C lifecycle)
///   deletes any prior one this process created, so re-instantiation never leaks. Total.
pub fn new(min: Int, _max: Option(Int)) -> Dynamic {
  ets_to_dynamic(EtsTable(tid: ets_new(), size: min))
}

// ───────────────────────────── cell-backed family (state_strategy: Cell) ─────────────────────────────

/// Write an active ELEMENT segment's `entries` into THIS process's cell table starting at
/// `offset`, at instantiation. Whole-range bounds-checked (all-or-nothing).
///
/// - `offset`: the first slot written; `entries[k]` goes into slot `offset + k`.
/// - `entries`: the type-tagged build-controlled closures — each `#(FuncType, closure)` pairs an
///   element function's IR signature with a closure over the generated function (invoked directly,
///   never `apply` of a data-derived name).
/// - Bounds check FIRST, before any write: if `offset < 0` or `offset + length(entries) > size`,
///   return `Error(TableOutOfBounds)` and write NOTHING (a slot the failed segment would have
///   filled still reads null). On success returns `Ok(Nil)`; the ETS table is mutated in place,
///   so NO `table_put` is needed (the `tid` is unchanged).
/// - Failure modes: `Error(TableOutOfBounds)`; raises (fail-closed, via `rt_state.table_get`) on
///   an un-seeded cell.
pub fn init_elem(
  offset: Int,
  entries: List(#(FuncType, fn(List(Int)) -> List(Int))),
) -> Result(Nil, TrapReason) {
  let table = current_ets()
  case offset < 0 || offset + list.length(entries) > table.size {
    True -> Error(TableOutOfBounds)
    False -> {
      list.index_fold(entries, Nil, fn(_acc, entry, k) {
        ets_insert(table.tid, offset + k, cell_entry_to_dynamic(entry))
      })
      Ok(Nil)
    }
  }
}

/// Dispatch a `call_indirect` through THIS process's cell table — the 3-fault fail-closed
/// dispatch (§F). Reads the cell's `tid`, applies the three guards IN ORDER, and on success
/// invokes the slot's build-controlled `target` with `args` directly (`target(args)`).
///
/// - `index`: the table entry index to call (the only runtime-data input reaching a control
///   transfer).
/// - `expected_type`: the call site's statically-required `FuncType`. Guard 3 matches the stored
///   entry's type tag against this with exact STRUCTURAL equality (`==`).
/// - `args`: the call arguments as raw bit patterns.
/// - Returns `Ok(results)`, or an `Error(reason)` checked in this order: `UndefinedElement`
///   (guard 1, bounds); `UninitializedElement` (guard 2, null slot); `IndirectCallTypeMismatch`
///   (guard 3, type). Raises (fail-closed) on an un-seeded cell.
pub fn call_indirect(
  index: Int,
  expected_type: FuncType,
  args: List(Int),
) -> Result(List(Int), TrapReason) {
  let table = current_ets()
  // Guard 1 — bounds. Must fire before any null/type inspection.
  case index < 0 || index >= table.size {
    True -> Error(UndefinedElement)
    False ->
      // Guard 2 — null slot. An absent ETS entry is an uninitialised slot.
      case ets_lookup(table.tid, index) {
        Error(Nil) -> Error(UninitializedElement)
        Ok(entry) -> {
          let #(entry_type, target) = dynamic_to_cell_entry(entry)
          // Guard 3 — exact structural FuncType match.
          case entry_type == expected_type {
            False -> Error(IndirectCallTypeMismatch)
            // Build-controlled invocation: invoke the STORED closure directly.
            True -> Ok(target(args))
          }
        }
      }
  }
}

/// Read THIS process's current `EtsTable` out of the cell. Fail-closed: `rt_state.table_get`
/// `panic`s on an un-seeded cell (never returns garbage), which propagates here.
fn current_ets() -> EtsTable {
  dynamic_to_ets(rt_state.table_get())
}

// ───────────────────────────── threaded family (state_strategy: Threaded) ─────────────────────────────

/// Threaded `init_elem`: project `st.table`, whole-range bounds-check, insert each entry into the
/// ETS table IN PLACE, and return the record.
///
/// - `st`: the threaded instance-state record; its `table` slot holds this handle's `tid`.
/// - `offset`/`entries`: as `init_elem`, but the closures are threaded
///   (`fn(InstanceState, List(Int)) -> #(List(Int), InstanceState)`).
/// - Returns `Ok(st)` — the SAME `st` (the §10 rule for a mutable-in-place backend: ETS is
///   mutated through the stable `tid`, so there is nothing to re-inject) — or
///   `Error(TableOutOfBounds)` with NO write (all-or-nothing).
pub fn t_init_elem(
  st: InstanceState,
  offset: Int,
  entries: List(
    #(FuncType, fn(InstanceState, List(Int)) -> #(List(Int), InstanceState)),
  ),
) -> Result(InstanceState, TrapReason) {
  let table = project(st)
  case offset < 0 || offset + list.length(entries) > table.size {
    True -> Error(TableOutOfBounds)
    False -> {
      list.index_fold(entries, Nil, fn(_acc, entry, k) {
        ets_insert(table.tid, offset + k, threaded_entry_to_dynamic(entry))
      })
      Ok(st)
    }
  }
}

/// Threaded `call_indirect`: the 3-fault dispatch (§F) over `st.table`, invoking the target as
/// `target(st, args) -> #(results, st')`.
///
/// - `st`: the threaded instance-state record.
/// - `index`/`expected_type`/`args`: as `call_indirect`.
/// - Returns `Ok(#(results, st'))` where `st'` is whatever the invoked build-controlled closure
///   threaded (memory/global updates the callee made), or the three `Error(reason)`s in guard
///   order. The `tid` (the table slot) is unchanged — the MVP dispatch never mutates the table.
pub fn t_call_indirect(
  st: InstanceState,
  index: Int,
  expected_type: FuncType,
  args: List(Int),
) -> Result(#(List(Int), InstanceState), TrapReason) {
  let table = project(st)
  case index < 0 || index >= table.size {
    True -> Error(UndefinedElement)
    False ->
      case ets_lookup(table.tid, index) {
        Error(Nil) -> Error(UninitializedElement)
        Ok(entry) -> {
          let #(entry_type, target) = dynamic_to_threaded_entry(entry)
          case entry_type == expected_type {
            False -> Error(IndirectCallTypeMismatch)
            True -> Ok(target(st, args))
          }
        }
      }
  }
}

/// Project THIS record's `EtsTable` out of `st.table` (the field seam `rt_state.table`) and
/// coerce it. Read-only.
fn project(st: InstanceState) -> EtsTable {
  dynamic_to_ets(rt_state.table(st))
}

// ───────────────────────────── differential canon hook (tests only, §F) ─────────────────────────────

/// The tier's whole slot image as a `size`-length list — the table analog of `rt_mem.to_flat`
/// (§B.2). `None` = a null slot, `Some(ty)` = a filled slot's structural `FuncType` tag.
/// Closures are not comparable, so behaviour is compared via `call_indirect`; this gives unit 09
/// a structural cross-tier equality it can assert without invoking. Tests only.
pub fn to_canon(handle: Dynamic) -> List(Option(FuncType)) {
  let table = dynamic_to_ets(handle)
  list.map(indices(table.size), fn(i) {
    case ets_lookup(table.tid, i) {
      Error(Nil) -> None
      Ok(entry) -> Some(dynamic_to_type_entry(entry).0)
    }
  })
}

/// The ascending slot indices `[0, 1, …, size-1]` (`[]` for `size <= 0`). Built by hand so it
/// never depends on `list.range`'s descending-range edge behaviour. Private helper for `to_canon`.
fn indices(size: Int) -> List(Int) {
  build_indices(size - 1, [])
}

fn build_indices(i: Int, acc: List(Int)) -> List(Int) {
  case i < 0 {
    True -> acc
    False -> build_indices(i - 1, [i, ..acc])
  }
}
