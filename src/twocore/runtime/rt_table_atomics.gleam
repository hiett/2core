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
import twocore/runtime/rt_meter
import twocore/runtime/rt_ref
import twocore/runtime/rt_state.{type InstanceState}
import twocore/runtime/rt_table.{type RefValue, effective_max}

/// The atomics-backed typed reference-table handle (opaque; carried as `Dynamic` in a
/// `tables`-vector slot). Phase-5 generalises the funcref store to a typed REFERENCE store (§A).
///
/// - `occ`: an `atomics` array of `max(size, 1)` unsigned 64-bit words (1-based; slot `i` is
///   `atomics` index `i + 1`). Each word is `0` (**null**) or a `k>0` dense key into `entries`. A
///   store mutates it IN PLACE; `grow` REALLOCATES it (a bigger array, the old words copied).
/// - `entries`: the IMMUTABLE companion `Dict(dense_key -> RefValue)` — the source of truth for a
///   non-null reference (funcref `#(FuncType, closure)` or externref `{ref_extern, term}`, stored
///   OPAQUELY). A mutating op REBUILDS this (structural sharing keeps it cheap). **Null is `occ =
///   0`**, never a companion entry — so `call_indirect`'s `occ == 0 ⇒ UninitializedElement` guard
///   stays byte-identical.
/// - `size`: the current slot count (`table.size`). Grows via `grow`.
/// - `max`: the EFFECTIVE maximum entry count (`min(declared_max, hard_max_slots)`), baked at
///   `new` time; `grow` never exceeds it.
/// - `next`: the next dense key to assign — a monotonically increasing counter (1-based), so a
///   store never reuses a companion key (overwrites orphan the old entry; the documented non-goal).
type AtomicsTable {
  AtomicsTable(
    occ: Dynamic,
    entries: Dict(Int, RefValue),
    size: Int,
    max: Int,
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

/// Box a funcref tuple `#(FuncType, closure)` as a `RefValue` for the companion. Identity at run
/// time; a funcref value *is* a table-entry shape (R1).
@external(erlang, "gleam_stdlib", "identity")
fn funcref_tuple_to_ref(e: #(FuncType, Dynamic)) -> RefValue

/// Unbox a companion `RefValue` back to a funcref tuple `#(FuncType, closure)`. Identity at run
/// time; sound after the `atomics` slot (`!= 0`) established the value is a stored reference and
/// (for `call_indirect`) validation guarantees it is a funcref.
@external(erlang, "gleam_stdlib", "identity")
fn ref_to_funcref_tuple(v: RefValue) -> #(FuncType, Dynamic)

// ───────────────────────────── construction (both strategies) ─────────────────────────────

/// Build a FRESH atomics-backed table of `min` null (uninitialised) slots, returned as the opaque
/// `Dynamic` the cell / threaded record stores.
///
/// - `min`: the table's initial entry count (the declared minimum). Becomes the fixed `size`; the
///   `atomics` array is zero-initialised (every slot `0` = null), the companion is empty, so a
///   `call_indirect` to any in-range slot before an element segment fills it traps
///   `UninitializedElement`.
/// - `max`: the declared maximum entry count, or `None` for unbounded. The EFFECTIVE cap baked
///   into the handle is `min(declared_max, hard_max_slots)`; `grow` enforces it.
/// - Returns the fresh handle. Total. (At least one `atomics` word is allocated even for a
///   0-slot table — `atomics:new` requires `arity >= 1`; the extra word is never in bounds.)
pub fn new(min: Int, max: Option(Int)) -> Dynamic {
  atomics_to_dynamic(AtomicsTable(
    occ: atomics_new(int.max(min, 1)),
    entries: dict.new(),
    size: min,
    max: effective_max(max),
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
      rt_state.table_put(
        atomics_to_dynamic(write_entries(table, offset, boxed)),
      )
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
          let #(entry_type, closure) =
            ref_to_funcref_tuple(companion_get(table, dense))
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

/// Dispatch a `call_indirect` through table `table_idx` — the INDEXED twin of `call_indirect`
/// (reference-types multi-table dispatch). Behaviourally identical to `call_indirect` for
/// `table_idx == 0`; reads table `table_idx` via `rt_state.table_at`, then applies the SAME
/// 3-fault fail-closed dispatch (bounds → `atomics == 0` null → exact `FuncType`) verbatim. No
/// ambient `apply` of a data-derived name (D3a). See `rt_table.call_indirect_at`.
pub fn call_indirect_at(
  table_idx: Int,
  index: Int,
  expected_type: FuncType,
  args: List(Int),
) -> Result(List(Int), TrapReason) {
  let table = dynamic_to_atomics(rt_state.table_at(table_idx))
  case index < 0 || index >= table.size {
    True -> Error(UndefinedElement)
    False ->
      case atomics_get(table.occ, index + 1) {
        0 -> Error(UninitializedElement)
        dense -> {
          let #(entry_type, closure) =
            ref_to_funcref_tuple(companion_get(table, dense))
          case entry_type == expected_type {
            False -> Error(IndirectCallTypeMismatch)
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
      Ok(rt_state.with_table(
        st,
        atomics_to_dynamic(write_entries(table, offset, boxed)),
      ))
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
          let #(entry_type, closure) =
            ref_to_funcref_tuple(companion_get(table, dense))
          case entry_type == expected_type {
            False -> Error(IndirectCallTypeMismatch)
            True -> Ok(dynamic_to_threaded_closure(closure)(st, args))
          }
        }
      }
  }
}

/// Threaded `call_indirect` through table `table_idx` — the INDEXED twin of `t_call_indirect`
/// (multi-table dispatch over `st`'s `tables` vector). Behaviourally identical to
/// `t_call_indirect` for `table_idx == 0`; the 3-fault dispatch is VERBATIM the frozen twin,
/// invoking the companion target as `target(st, args) -> #(results, st')`. See
/// `rt_table.t_call_indirect_at`.
pub fn t_call_indirect_at(
  st: InstanceState,
  table_idx: Int,
  index: Int,
  expected_type: FuncType,
  args: List(Int),
) -> Result(#(List(Int), InstanceState), TrapReason) {
  let table = dynamic_to_atomics(rt_state.t_table_at(st, table_idx))
  case index < 0 || index >= table.size {
    True -> Error(UndefinedElement)
    False ->
      case atomics_get(table.occ, index + 1) {
        0 -> Error(UninitializedElement)
        dense -> {
          let #(entry_type, closure) =
            ref_to_funcref_tuple(companion_get(table, dense))
          case entry_type == expected_type {
            False -> Error(IndirectCallTypeMismatch)
            True -> Ok(dynamic_to_threaded_closure(closure)(st, args))
          }
        }
      }
  }
}

/// Project THIS record's default `AtomicsTable` out of `st.table` (the field seam
/// `rt_state.table`) and coerce it. Read-only.
fn project(st: InstanceState) -> AtomicsTable {
  dynamic_to_atomics(rt_state.table(st))
}

// ───────────────────────────── cell-backed reference/bulk surface (§B) ─────────────────────────────
//
// The Phase-5 reference-types + bulk-table ops (state_strategy: Cell), reaching table `idx` via the
// R7 index-keyed `rt_state.table_at`/`with_table_at` accessors. The `occ` array is mutated IN
// PLACE, but the companion `Dict` is IMMUTABLE, so every mutating op returns a handle with the
// GROWN companion (the `occ` ref stable, except `grow` reallocates it) — the §10 rule for a hybrid
// backend — and is re-injected. The op cores charge fuel (R9) identically to the threaded family.

/// `table.get idx` — the reference at `index`; `occ == 0` ⇒ null sentinel; `Error(TableOutOfBounds)`
/// out of range. No mutation.
pub fn get(idx: Int, index: Int) -> Result(RefValue, TrapReason) {
  do_get(read_at(idx), index)
}

/// `table.set idx` — write `value` at `index` (eager bounds, no write on trap). Null ⇒ `occ = 0`.
pub fn set(idx: Int, index: Int, value: RefValue) -> Result(Nil, TrapReason) {
  commit(idx, do_set(read_at(idx), index, value))
}

/// `table.size idx`.
pub fn size(idx: Int) -> Int {
  do_size(read_at(idx))
}

/// `table.grow idx` — append `delta` slots of `init`; the OLD size, or `-1` past `max`/cap
/// (unchanged, no fuel). Charges `delta` fuel on success (R9). Re-injects the reallocated handle.
pub fn grow(idx: Int, delta: Int, init: RefValue) -> Int {
  case do_grow(read_at(idx), delta, init) {
    #(-1, _) -> -1
    #(old, table) -> {
      rt_state.with_table_at(idx, atomics_to_dynamic(table))
      old
    }
  }
}

/// `table.fill idx` — eager bounds (checked even for `count == 0`, R10), no partial writes; charges
/// `count` fuel on success (R9).
pub fn fill(
  idx: Int,
  offset: Int,
  value: RefValue,
  count: Int,
) -> Result(Nil, TrapReason) {
  commit(idx, do_fill(read_at(idx), offset, value, count))
}

/// `table.init idx` from segment `items` (R2) — eager double bounds, no partial writes; `count`
/// fuel on success (R9). A dropped segment arrives as `items = []`.
pub fn table_init(
  idx: Int,
  items: List(RefValue),
  dst: Int,
  src: Int,
  count: Int,
) -> Result(Nil, TrapReason) {
  commit(idx, do_table_init(read_at(idx), items, dst, src, count))
}

/// `table.copy dst_idx src_idx` — memmove/overlap-correct (R11); eager bounds, no partial writes;
/// `count` fuel on success (R9).
pub fn table_copy(
  dst_idx: Int,
  src_idx: Int,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(Nil, TrapReason) {
  commit(
    dst_idx,
    do_table_copy(read_at(dst_idx), read_at(src_idx), dst, src, count),
  )
}

/// Active reference-segment write into table `idx` at `offset` (no fuel; whole-range bounds).
pub fn init_elem_ref(
  idx: Int,
  offset: Int,
  refs: List(RefValue),
) -> Result(Nil, TrapReason) {
  commit(idx, do_init_elem_ref(read_at(idx), offset, refs))
}

/// Read table `idx`'s `AtomicsTable` from the cell. Fail-closed on an un-seeded cell (via `rt_state`).
fn read_at(idx: Int) -> AtomicsTable {
  dynamic_to_atomics(rt_state.table_at(idx))
}

/// Commit a mutating op's `Result(AtomicsTable, _)` back into table `idx` of the cell: on `Ok`,
/// re-inject the handle (grown companion / reallocated `occ`) and return `Ok(Nil)`; on `Error`,
/// propagate (nothing was written).
fn commit(
  idx: Int,
  result: Result(AtomicsTable, TrapReason),
) -> Result(Nil, TrapReason) {
  case result {
    Ok(table) -> {
      rt_state.with_table_at(idx, atomics_to_dynamic(table))
      Ok(Nil)
    }
    Error(reason) -> Error(reason)
  }
}

// ───────────────────────────── threaded reference/bulk surface (§B) ─────────────────────────────
//
// The threaded twins reach table `idx` via `rt_state.t_table_at`/`t_with_table_at`, re-injecting
// the handle with the grown companion (`occ` mutated in place / reallocated by `grow`) — the §10
// rule for a hybrid backend. Each drives the SAME `do_*` core the cell family uses.

/// Threaded `table.get` (read-only). See `get`.
pub fn t_get(
  st: InstanceState,
  idx: Int,
  index: Int,
) -> Result(RefValue, TrapReason) {
  do_get(read_at_t(st, idx), index)
}

/// Threaded `table.set`: re-injects the handle with the grown companion (§10). See `set`.
pub fn t_set(
  st: InstanceState,
  idx: Int,
  index: Int,
  value: RefValue,
) -> Result(InstanceState, TrapReason) {
  commit_t(st, idx, do_set(read_at_t(st, idx), index, value))
}

/// Threaded `table.size` (read-only). See `size`.
pub fn t_size(st: InstanceState, idx: Int) -> Int {
  do_size(read_at_t(st, idx))
}

/// Threaded `table.grow`: `#(old_or_-1, st')`; on success re-injects the reallocated handle and
/// charges `delta` fuel (parity with cell `grow`). See `grow`.
pub fn t_grow(
  st: InstanceState,
  idx: Int,
  delta: Int,
  init: RefValue,
) -> #(Int, InstanceState) {
  case do_grow(read_at_t(st, idx), delta, init) {
    #(-1, _) -> #(-1, st)
    #(old, table) -> #(
      old,
      rt_state.t_with_table_at(st, idx, atomics_to_dynamic(table)),
    )
  }
}

/// Threaded `table.fill`: eager bounds, no partial writes; `count` fuel on success. See `fill`.
pub fn t_fill(
  st: InstanceState,
  idx: Int,
  offset: Int,
  value: RefValue,
  count: Int,
) -> Result(InstanceState, TrapReason) {
  commit_t(st, idx, do_fill(read_at_t(st, idx), offset, value, count))
}

/// Threaded `table.init` from segment `items` (R2): eager double bounds; `count` fuel on success.
pub fn t_table_init(
  st: InstanceState,
  idx: Int,
  items: List(RefValue),
  dst: Int,
  src: Int,
  count: Int,
) -> Result(InstanceState, TrapReason) {
  commit_t(st, idx, do_table_init(read_at_t(st, idx), items, dst, src, count))
}

/// Threaded `table.copy` (memmove, R11): eager bounds; `count` fuel on success. See `table_copy`.
pub fn t_table_copy(
  st: InstanceState,
  dst_idx: Int,
  src_idx: Int,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(InstanceState, TrapReason) {
  commit_t(
    st,
    dst_idx,
    do_table_copy(
      read_at_t(st, dst_idx),
      read_at_t(st, src_idx),
      dst,
      src,
      count,
    ),
  )
}

/// Threaded active reference-segment write (no fuel). See `init_elem_ref`.
pub fn t_init_elem_ref(
  st: InstanceState,
  idx: Int,
  offset: Int,
  refs: List(RefValue),
) -> Result(InstanceState, TrapReason) {
  commit_t(st, idx, do_init_elem_ref(read_at_t(st, idx), offset, refs))
}

/// Project table `idx`'s `AtomicsTable` out of the threaded record. Read-only.
fn read_at_t(st: InstanceState, idx: Int) -> AtomicsTable {
  dynamic_to_atomics(rt_state.t_table_at(st, idx))
}

/// Commit a mutating op's result into table `idx` of the threaded record: on `Ok`, re-inject the
/// handle (§10) and return `Ok(st')`; on `Error`, propagate `st` untouched.
fn commit_t(
  st: InstanceState,
  idx: Int,
  result: Result(AtomicsTable, TrapReason),
) -> Result(InstanceState, TrapReason) {
  case result {
    Ok(table) ->
      Ok(rt_state.t_with_table_at(st, idx, atomics_to_dynamic(table)))
    Error(reason) -> Error(reason)
  }
}

// ───────────────────────────── the op cores (occ in place + immutable companion; §H) ─────────────────────────────
//
// One core per op, driven by BOTH families — so behaviour AND fuel are identical across state
// strategies. Cores mutate `occ` IN PLACE and rebuild the immutable companion, returning the new
// `AtomicsTable`. Reference values are OPAQUE; fuel (R9) is charged on the success path.

/// `table.get` core: bounds-check, else the slot's reference (`occ == 0` ⇒ null sentinel).
fn do_get(t: AtomicsTable, index: Int) -> Result(RefValue, TrapReason) {
  case index < 0 || index >= t.size {
    True -> Error(TableOutOfBounds)
    False -> Ok(slot_ref(t, index))
  }
}

/// `table.set` core: bounds-check FIRST (no write on trap), else write the slot.
fn do_set(
  t: AtomicsTable,
  index: Int,
  value: RefValue,
) -> Result(AtomicsTable, TrapReason) {
  case index < 0 || index >= t.size {
    True -> Error(TableOutOfBounds)
    False -> Ok(put_slot(t, index, value))
  }
}

/// `table.size` core.
fn do_size(t: AtomicsTable) -> Int {
  t.size
}

/// `table.grow` core: `#(old, grown)` on success — REALLOCATE `occ` to the new size (copying the
/// old words), fill new slots with `init`, charge `delta` fuel (R9) — or `#(-1, t)` if `delta < 0`
/// or `old + delta` exceeds the effective `max` (unchanged, nothing allocated, no charge).
fn do_grow(
  t: AtomicsTable,
  delta: Int,
  init: RefValue,
) -> #(Int, AtomicsTable) {
  let old = t.size
  let new = old + delta
  case delta >= 0 && new <= t.max {
    False -> #(-1, t)
    True -> {
      let new_occ = atomics_new(int.max(new, 1))
      copy_occ(t.occ, new_occ, old)
      let grown = AtomicsTable(..t, occ: new_occ, size: new)
      let filled = fill_run(grown, old, init, delta)
      rt_meter.charge(delta)
      #(old, filled)
    }
  }
}

/// `table.fill` core: eager bounds (checked even for `count == 0`, R10), no partial writes; else
/// fill (a single shared dense key for a non-null run), charging `count` fuel.
fn do_fill(
  t: AtomicsTable,
  offset: Int,
  value: RefValue,
  count: Int,
) -> Result(AtomicsTable, TrapReason) {
  case offset < 0 || count < 0 || offset + count > t.size {
    True -> Error(TableOutOfBounds)
    False -> {
      let filled = fill_run(t, offset, value, count)
      rt_meter.charge(count)
      Ok(filled)
    }
  }
}

/// `table.init` core from `items`: eager bounds against BOTH the segment length and the table size,
/// no partial writes; else write, charging `count` fuel.
fn do_table_init(
  t: AtomicsTable,
  items: List(RefValue),
  dst: Int,
  src: Int,
  count: Int,
) -> Result(AtomicsTable, TrapReason) {
  case
    dst < 0
    || src < 0
    || count < 0
    || dst + count > t.size
    || src + count > list.length(items)
  {
    True -> Error(TableOutOfBounds)
    False -> {
      let written = write_run(t, dst, list.take(list.drop(items, src), count))
      rt_meter.charge(count)
      Ok(written)
    }
  }
}

/// `table.copy` core (memmove, R11): eager bounds, no partial writes; SNAPSHOT the whole source
/// slice as a list BEFORE writing the destination (overlap-correct); charge `count` fuel.
fn do_table_copy(
  dst_t: AtomicsTable,
  src_t: AtomicsTable,
  dst: Int,
  src: Int,
  count: Int,
) -> Result(AtomicsTable, TrapReason) {
  case
    dst < 0
    || src < 0
    || count < 0
    || dst + count > dst_t.size
    || src + count > src_t.size
  {
    True -> Error(TableOutOfBounds)
    False -> {
      let slice = snapshot(src_t, src, count)
      let written = write_run(dst_t, dst, slice)
      rt_meter.charge(count)
      Ok(written)
    }
  }
}

/// Active reference-segment write core (no fuel): whole-range bounds, no partial writes.
fn do_init_elem_ref(
  t: AtomicsTable,
  offset: Int,
  refs: List(RefValue),
) -> Result(AtomicsTable, TrapReason) {
  case offset < 0 || offset + list.length(refs) > t.size {
    True -> Error(TableOutOfBounds)
    False -> Ok(write_run(t, offset, refs))
  }
}

// ───────────────────────────── slot helpers ─────────────────────────────

/// The reference value at slot `index`: `occ == 0` ⇒ null sentinel, else the companion reference.
fn slot_ref(t: AtomicsTable, index: Int) -> RefValue {
  case atomics_get(t.occ, index + 1) {
    0 -> rt_ref.null_ref()
    dense -> companion_get(t, dense)
  }
}

/// Write `value` into slot `index`: a NULL reference sets `occ = 0` in place (no companion entry);
/// a non-null reference assigns the next dense key, `atomics:put`s it in place, and inserts the
/// value into the (rebuilt) immutable companion. Returns the updated `AtomicsTable`.
fn put_slot(t: AtomicsTable, index: Int, value: RefValue) -> AtomicsTable {
  case rt_ref.is_null(value) {
    True -> {
      atomics_put(t.occ, index + 1, 0)
      t
    }
    False -> {
      let dense = t.next
      atomics_put(t.occ, index + 1, dense)
      AtomicsTable(
        ..t,
        entries: dict.insert(t.entries, dense, value),
        next: dense + 1,
      )
    }
  }
}

/// Fill slots `[start, start + count)` all with `value`. A non-null run shares ONE dense key (all
/// slots point at the same companion entry — they hold the same value); a null run zeroes `occ`.
fn fill_run(
  t: AtomicsTable,
  start: Int,
  value: RefValue,
  count: Int,
) -> AtomicsTable {
  case count <= 0 {
    True -> t
    False ->
      case rt_ref.is_null(value) {
        True -> {
          occ_put_run(t.occ, start, 0, count)
          t
        }
        False -> {
          let dense = t.next
          occ_put_run(t.occ, start, dense, count)
          AtomicsTable(
            ..t,
            entries: dict.insert(t.entries, dense, value),
            next: dense + 1,
          )
        }
      }
  }
}

/// Write `values` into consecutive slots from `start` (`values[k]` → slot `start + k`), each via
/// `put_slot` (distinct dense keys for distinct non-null values).
fn write_run(
  t: AtomicsTable,
  start: Int,
  values: List(RefValue),
) -> AtomicsTable {
  list.index_fold(values, t, fn(acc, value, k) {
    put_slot(acc, start + k, value)
  })
}

/// `atomics:put` the same `word` into the 1-based `occ` indices for slots `[start, start + count)`.
fn occ_put_run(occ: Dynamic, start: Int, word: Int, count: Int) -> Nil {
  case count <= 0 {
    True -> Nil
    False -> {
      atomics_put(occ, start + 1, word)
      occ_put_run(occ, start + 1, word, count - 1)
    }
  }
}

/// Copy the first `count` `occ` words from `src` to `dst` (1-based), for `grow`'s reallocation.
fn copy_occ(src: Dynamic, dst: Dynamic, count: Int) -> Nil {
  copy_occ_loop(src, dst, 0, count)
}

fn copy_occ_loop(src: Dynamic, dst: Dynamic, k: Int, count: Int) -> Nil {
  case k >= count {
    True -> Nil
    False -> {
      atomics_put(dst, k + 1, atomics_get(src, k + 1))
      copy_occ_loop(src, dst, k + 1, count)
    }
  }
}

/// Snapshot source slots `[src, src + count)` into a list of reference values (read BEFORE any
/// destination write — the memmove guarantee).
fn snapshot(t: AtomicsTable, src: Int, count: Int) -> List(RefValue) {
  snapshot_loop(t, src, count, [])
}

fn snapshot_loop(
  t: AtomicsTable,
  at: Int,
  remaining: Int,
  acc: List(RefValue),
) -> List(RefValue) {
  case remaining <= 0 {
    True -> list.reverse(acc)
    False -> snapshot_loop(t, at + 1, remaining - 1, [slot_ref(t, at), ..acc])
  }
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
      dense -> {
        let value = companion_get(table, dense)
        case rt_ref.classify_ref(value) {
          rt_ref.FuncRef -> Some(ref_to_funcref_tuple(value).0)
          _ -> None
        }
      }
    }
  })
}

// ───────────────────────────── shared helpers ─────────────────────────────

/// Fold each boxed funcref entry into the table: assign the next dense key, `atomics:put` it at the
/// slot's 1-based `occ` index IN PLACE, and `dict.insert` the entry (as a `RefValue`) into the
/// companion. Returns the updated `AtomicsTable` (occ mutated in place; companion + `next` grown).
/// Callers MUST have bounds-checked the whole `[offset, offset+len)` range (all-or-nothing). Used
/// by the funcref `init_elem` fast path.
fn write_entries(
  table: AtomicsTable,
  offset: Int,
  entries: List(#(FuncType, Dynamic)),
) -> AtomicsTable {
  list.index_fold(entries, table, fn(t, entry, k) {
    let dense = t.next
    atomics_put(t.occ, offset + k + 1, dense)
    AtomicsTable(
      ..t,
      entries: dict.insert(t.entries, dense, funcref_tuple_to_ref(entry)),
      next: dense + 1,
    )
  })
}

/// Read the companion reference value for a `dense` key derived from a non-null `atomics` slot.
/// The `let assert` upholds a BUILD INVARIANT (a slot's dense key is written in the same step its
/// companion entry is inserted, so a non-zero slot ALWAYS has a companion entry); a violation is
/// an internal bug, not a WASM trap — it `panic`s node-safe rather than fabricating a value.
fn companion_get(table: AtomicsTable, dense: Int) -> RefValue {
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
