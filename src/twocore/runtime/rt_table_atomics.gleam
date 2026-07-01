//// `rt_table_atomics` — the tier-O, O(1)-integer-slot funcref-table backend (owner: unit
//// P4-06). An Erlang `atomics` array of per-slot dense entry keys (`0` = null) BESIDE an
//// immutable `#(FuncType, closure)` companion `Dict`, behind the frozen uniform `rt_table`
//// interface (keystone §B.2). A pure module swap the linker (unit 07) resolves for
//// `table_tier: TableAtomics`; nothing about the generated code or the `call_indirect` seam
//// changes (G5/G7).
////
//// **The honest sharp edge (§E).** BEAM `atomics` arrays hold only 64-bit integers, so the FUNS
//// cannot live in the array. Each slot's `atomics` word holds a 1-based DENSE KEY (`0` = null,
//// `k>0` = the key into the companion), and the companion `Dict(dense_key -> #(FuncType,
//// closure))` is the immutable source of truth for the closure + type tag. The `atomics` layer is
//// the O(1) sparse-slot → dense-entry index; the closure is invoked from the companion.
////
//// **The 3-fault fail-closed dispatch is byte-identical to `TablePaged`** (§F, unchanged from
//// P2-05, <https://webassembly.github.io/spec/core/exec/instructions.html>): the three guards
//// fire in spec order and return the three distinct `TrapReason`s —
//// 1. `index` in `[0, size)` — else `UndefinedElement`;
//// 2. slot filled (`atomics:get != 0`) — else `UninitializedElement`;
//// 3. exact STRUCTURAL `FuncType` match — else `IndirectCallTypeMismatch`.
//// The order is observable: an OOB index traps `UndefinedElement` BEFORE any null/type check; a
//// null in-range slot (`atomics:get == 0`) traps `UninitializedElement` BEFORE any type check.
////
//// **No ambient authority (D3a).** The only runtime-data inputs reaching a control transfer are
//// the integer `index` and the integer dense key `d` — NEITHER is ever turned into a
//// module/function atom. The dispatched target is the build-controlled companion closure
//// (`emit_core` captures a compile-time-literal `'twocore@wasm@<mod>':'f<idx>'/arity` inside it),
//// invoked DIRECTLY as `target(args)`; this module calls NO `erlang:apply/3` on data-derived names.
////
//// **Process-local; tier-O never NIF (G6/G8).** The `atomics` ref is reachable only through the
//// handle, confined to the instance process under the one-instance-one-process contract (E1) —
//// never cross-process, never shared memory. `atomics` is OTP-native/memory-safe; there is no
//// `nif` table tier, so Safe permits it.
////
//// **Fail-closed on an un-seeded cell (E3).** The cell-backed ops read the handle via
//// `rt_state.table_get`, which raises on an un-seeded cell rather than fabricating an empty table;
//// the threaded ops require the handle present in `st.table`.
////
//// **Both op families.** The **cell-backed** family and the **threaded** family both compose with
//// this tier (§C — tier and state-strategy are orthogonal). The `atomics` array is mutated IN
//// PLACE, but the companion `Dict` is IMMUTABLE, so a mutating op returns a handle with the GROWN
//// companion (the `occ` ref unchanged) — the §10 uniform-threading rule for a hybrid backend.
////
//// **Forward-compat (Phase 5, §E).** The array is fixed-size at creation — exactly right for the
//// MVP (funcref tables do not grow at runtime). A future `table.set` becomes an O(1) in-place
//// `atomics:put`; a future `table.grow` inherits `rt_mem`'s `atomics` pre-allocation sharp edge
//// (noted, not built here).

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/int
import gleam/list
import gleam/option.{type Option, None, Some}
import twocore/ir.{
  type FuncType, type TrapReason, IndirectCallTypeMismatch, TableOutOfBounds,
  UndefinedElement, UninitializedElement,
}
import twocore/runtime/rt_state.{type InstanceState}

/// The atomics-backed funcref table handle (opaque; carried as `Dynamic` in the `table` slot).
///
/// - `occ`: an `atomics` array of `max(size, 1)` unsigned 64-bit words (1-based; slot `i` is
///   `atomics` index `i + 1`). Each word is `0` (null) or a `k>0` dense key into `entries`. A
///   store mutates it IN PLACE; the ref is stable across mutations.
/// - `entries`: the IMMUTABLE companion `Dict(dense_key -> #(FuncType, closure))` — the source of
///   truth for the closure + type tag (the closure is boxed as `Dynamic`; both ABIs coerce to the
///   same stored shape). A mutating op REBUILDS this (structural sharing keeps it cheap).
/// - `size`: the number of slots — the declared `min`. Fixed at `new` time (no runtime
///   `table.grow` in the MVP); `call_indirect`'s bounds guard checks `index` against it.
/// - `next`: the next dense key to assign — a monotonically increasing counter (1-based), so
///   successive `init_elem` segments never reuse a companion key.
type AtomicsTable {
  AtomicsTable(
    occ: Dynamic,
    entries: Dict(Int, #(FuncType, Dynamic)),
    size: Int,
    next: Int,
  )
}

// ───────────────────────────── the `atomics` FFI (reuses the unit-04 shim) ─────────────────────────────

/// Allocate a fresh zero-initialised `atomics` array of `arity` unsigned 64-bit words (all slots
/// default `0` = null). `arity >= 1`. Reuses `twocore_rt_mem_atomics_ffi` (the same `{signed,
/// false}` shim unit 04 ships) — a table needs no separate atomics primitive.
@external(erlang, "twocore_rt_mem_atomics_ffi", "new")
fn atomics_new(arity: Int) -> Dynamic

/// Read the 1-indexed word `ix` (a `0..2^64-1` integer) from `ref`. No copy.
@external(erlang, "twocore_rt_mem_atomics_ffi", "get")
fn atomics_get(ref: Dynamic, ix: Int) -> Int

/// Write dense key `val` into the 1-indexed word `ix`, mutating `ref` IN PLACE.
@external(erlang, "twocore_rt_mem_atomics_ffi", "put")
fn atomics_put(ref: Dynamic, ix: Int, val: Int) -> Nil

// ───────────────────────────── opaque `Dynamic` coercions (identity at run time) ─────────────────────────────

/// Coerce an `AtomicsTable` handle into the opaque `Dynamic` the cell / threaded record stores.
/// Identity at run time (`gleam_stdlib:identity/1`); tier-O, cannot fail.
@external(erlang, "gleam_stdlib", "identity")
fn atomics_to_dynamic(t: AtomicsTable) -> Dynamic

/// Coerce the cell / record's opaque `Dynamic` back into an `AtomicsTable`. Identity at run time;
/// sound because `rt_table_atomics` is the sole producer of the term held in the `table` slot.
@external(erlang, "gleam_stdlib", "identity")
fn dynamic_to_atomics(value: Dynamic) -> AtomicsTable

/// Box a CELL-family closure as the opaque `Dynamic` the companion stores. Identity at run time;
/// the cell family is the sole reader of what it inserts.
@external(erlang, "gleam_stdlib", "identity")
fn cell_closure_to_dynamic(f: fn(List(Int)) -> List(Int)) -> Dynamic

/// Unbox a companion closure back to the CELL-family shape. Identity at run time; sound because a
/// cell-inserted closure is only ever read by the cell family.
@external(erlang, "gleam_stdlib", "identity")
fn dynamic_to_cell_closure(d: Dynamic) -> fn(List(Int)) -> List(Int)

/// Box a THREADED-family closure as the opaque `Dynamic` the companion stores. Identity at run
/// time; the threaded family is the sole reader of what it inserts.
@external(erlang, "gleam_stdlib", "identity")
fn threaded_closure_to_dynamic(
  f: fn(InstanceState, List(Int)) -> #(List(Int), InstanceState),
) -> Dynamic

/// Unbox a companion closure back to the THREADED-family shape. Identity at run time; sound
/// because a threaded-inserted closure is only ever read by the threaded family.
@external(erlang, "gleam_stdlib", "identity")
fn dynamic_to_threaded_closure(
  d: Dynamic,
) -> fn(InstanceState, List(Int)) -> #(List(Int), InstanceState)

// ───────────────────────────── construction (both strategies) ─────────────────────────────

/// Build a FRESH atomics-backed table of `min` null (uninitialised) slots, returned as the opaque
/// `Dynamic` the cell / threaded record stores.
///
/// - `min`: the table's initial entry count (the declared minimum). Becomes the fixed `size`; the
///   `atomics` array is zero-initialised (every slot `0` = null), the companion is empty, so a
///   `call_indirect` to any in-range slot before an element segment fills it traps
///   `UninitializedElement`.
/// - `max`: optional maximum entry count. UNUSED in the MVP — funcref tables cannot grow.
/// - Returns the fresh handle. Total. (At least one `atomics` word is allocated even for a
///   0-slot table — `atomics:new` requires `arity >= 1`; the extra word is never in bounds.)
pub fn new(min: Int, _max: Option(Int)) -> Dynamic {
  atomics_to_dynamic(AtomicsTable(
    occ: atomics_new(int.max(min, 1)),
    entries: dict.new(),
    size: min,
    next: 1,
  ))
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
///   return `Error(TableOutOfBounds)` and write NOTHING (no `atomics:put`, no companion insert —
///   a slot the failed segment would have filled still reads null). On success returns `Ok(Nil)`;
///   the `atomics` array is mutated in place, but the companion grew, so the new handle is written
///   back with `table_put`.
/// - Failure modes: `Error(TableOutOfBounds)`; raises (fail-closed, via `rt_state.table_get`) on
///   an un-seeded cell.
pub fn init_elem(
  offset: Int,
  entries: List(#(FuncType, fn(List(Int)) -> List(Int))),
) -> Result(Nil, TrapReason) {
  let table = current_atomics()
  case offset < 0 || offset + list.length(entries) > table.size {
    True -> Error(TableOutOfBounds)
    False -> {
      let boxed =
        list.map(entries, fn(e) { #(e.0, cell_closure_to_dynamic(e.1)) })
      rt_state.table_put(atomics_to_dynamic(fill(table, offset, boxed)))
      Ok(Nil)
    }
  }
}

/// Dispatch a `call_indirect` through THIS process's cell table — the 3-fault fail-closed
/// dispatch (§F). Reads the cell's handle, applies the three guards IN ORDER, and on success
/// invokes the companion `target` with `args` directly (`target(args)`).
///
/// - `index`/`expected_type`/`args`: as the frozen interface. Guard 3 is exact STRUCTURAL
///   `FuncType` equality (`==`).
/// - Returns `Ok(results)`, or an `Error(reason)` checked in this order: `UndefinedElement`
///   (guard 1, bounds); `UninitializedElement` (guard 2, `atomics:get == 0`);
///   `IndirectCallTypeMismatch` (guard 3, type). Raises (fail-closed) on an un-seeded cell.
pub fn call_indirect(
  index: Int,
  expected_type: FuncType,
  args: List(Int),
) -> Result(List(Int), TrapReason) {
  let table = current_atomics()
  // Guard 1 — bounds. Must fire before any null/type inspection.
  case index < 0 || index >= table.size {
    True -> Error(UndefinedElement)
    False ->
      // Guard 2 — null slot. A `0` word is an uninitialised slot.
      case atomics_get(table.occ, index + 1) {
        0 -> Error(UninitializedElement)
        dense -> {
          let #(entry_type, closure) = companion_get(table, dense)
          // Guard 3 — exact structural FuncType match.
          case entry_type == expected_type {
            False -> Error(IndirectCallTypeMismatch)
            // Build-controlled invocation: invoke the STORED companion closure directly.
            True -> Ok(dynamic_to_cell_closure(closure)(args))
          }
        }
      }
  }
}

/// Read THIS process's current `AtomicsTable` out of the cell. Fail-closed: `rt_state.table_get`
/// `panic`s on an un-seeded cell (never returns garbage), which propagates here.
fn current_atomics() -> AtomicsTable {
  dynamic_to_atomics(rt_state.table_get())
}

// ───────────────────────────── threaded family (state_strategy: Threaded) ─────────────────────────────

/// Threaded `init_elem`: project `st.table`, whole-range bounds-check, write each slot's dense key
/// into `occ` IN PLACE + grow the companion, and RETURN the record with the grown companion.
///
/// - `st`: the threaded instance-state record; its `table` slot holds this handle.
/// - `offset`/`entries`: as `init_elem`, but the closures are threaded.
/// - Returns `Ok(st')` where `st'.table` is the handle with the GROWN companion (the `occ` ref
///   unchanged, written in place) — the §10 rule for a hybrid backend — or `Error(TableOutOfBounds)`
///   with NO write (all-or-nothing).
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
      let boxed =
        list.map(entries, fn(e) { #(e.0, threaded_closure_to_dynamic(e.1)) })
      Ok(rt_state.with_table(st, atomics_to_dynamic(fill(table, offset, boxed))))
    }
  }
}

/// Threaded `call_indirect`: the 3-fault dispatch (§F) over `st.table`, invoking the companion
/// target as `target(st, args) -> #(results, st')`.
///
/// - `st`: the threaded instance-state record.
/// - `index`/`expected_type`/`args`: as `call_indirect`.
/// - Returns `Ok(#(results, st'))` where `st'` is whatever the invoked build-controlled closure
///   threaded, or the three `Error(reason)`s in guard order. The handle (table slot) is unchanged
///   — the MVP dispatch never mutates the table.
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
      case atomics_get(table.occ, index + 1) {
        0 -> Error(UninitializedElement)
        dense -> {
          let #(entry_type, closure) = companion_get(table, dense)
          case entry_type == expected_type {
            False -> Error(IndirectCallTypeMismatch)
            True -> Ok(dynamic_to_threaded_closure(closure)(st, args))
          }
        }
      }
  }
}

/// Project THIS record's `AtomicsTable` out of `st.table` (the field seam `rt_state.table`) and
/// coerce it. Read-only.
fn project(st: InstanceState) -> AtomicsTable {
  dynamic_to_atomics(rt_state.table(st))
}

// ───────────────────────────── differential canon hook (tests only, §F) ─────────────────────────────

/// The tier's whole slot image as a `size`-length list — the table analog of `rt_mem.to_flat`
/// (§B.2). `None` = a null slot (`atomics:get == 0`), `Some(ty)` = a filled slot's structural
/// `FuncType` tag (the companion entry's type). Tests only.
pub fn to_canon(handle: Dynamic) -> List(Option(FuncType)) {
  let table = dynamic_to_atomics(handle)
  list.map(indices(table.size), fn(i) {
    case atomics_get(table.occ, i + 1) {
      0 -> None
      dense -> Some(companion_get(table, dense).0)
    }
  })
}

// ───────────────────────────── shared helpers ─────────────────────────────

/// Fold each boxed entry into the table: assign the next dense key, `atomics:put` it at the slot's
/// 1-based `occ` index IN PLACE, and `dict.insert` the entry into the companion. Returns the
/// updated `AtomicsTable` (occ mutated in place; companion + `next` grown). Callers MUST have
/// bounds-checked the whole `[offset, offset+len)` range (all-or-nothing).
fn fill(
  table: AtomicsTable,
  offset: Int,
  entries: List(#(FuncType, Dynamic)),
) -> AtomicsTable {
  list.index_fold(entries, table, fn(t, entry, k) {
    let dense = t.next
    atomics_put(t.occ, offset + k + 1, dense)
    AtomicsTable(
      ..t,
      entries: dict.insert(t.entries, dense, entry),
      next: dense + 1,
    )
  })
}

/// Read the companion entry for a `dense` key derived from a non-null `atomics` slot. The `let
/// assert` upholds a BUILD INVARIANT (`fill` inserts the companion entry and writes the slot in
/// the same step, so a non-zero slot ALWAYS has a companion entry); a violation is an internal
/// bug, not a WASM trap — it `panic`s node-safe rather than fabricating a value.
fn companion_get(table: AtomicsTable, dense: Int) -> #(FuncType, Dynamic) {
  let assert Ok(entry) = dict.get(table.entries, dense)
  entry
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
