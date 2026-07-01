//// `rt_table` — the funcref table value + the 3-fault fail-closed `call_indirect`
//// dispatch (owner: unit 05). SIGNATURES frozen by unit 01; BODIES implemented by unit 05.
////
//// **State location.** The table value lives in the `table` field of THIS process's cell
//// (read via `rt_state.table_get`, written via `rt_state.table_put`); it is OPAQUE to
//// `rt_state`. `rt_table` owns its shape — the private `Table` record below — and coerces
//// to/from the cell's `Dynamic` via `gleam_stdlib:identity/1` (a tier-O no-op; `rt_table`
//// is the sole producer/consumer of this term, so the coercion is sound).
////
//// **Representation.** A `Table` is `{size, slots}` where `size` is the declared `min`
//// entry count (MVP has no `table.grow`, so the table is fixed-size after `new`) and
//// `slots` is a SPARSE `Dict(Int, #(FuncType, closure))`: a PRESENT key in `[0, size)` is a
//// filled slot, an ABSENT key in `[0, size)` is a null/uninitialised slot
//// (→ `UninitializedElement`). Only `init_elem` ever writes slots (active element segments
//// at instantiation); funcref tables are immutable at run time in the MVP, so structural
//// sharing across the immutable `Table` versions is free.
////
//// **No ambient authority (E3, D3a).** Dispatch goes through BUILD-CONTROLLED closures
//// populated from element segments — NEVER a data-driven `apply(Module, Fun, Args)` where
//// `Module`/`Fun` come from table/runtime data. Each entry is TYPE-TAGGED `#(FuncType,
//// closure)`: `emit_core` (unit 10) passes each element function's IR `FuncType` plus a
//// closure that captures a COMPILE-TIME-LITERAL `'twocore@wasm@<mod>':'f<idx>'/arity`
//// reference; `rt_table` only stores and invokes it. The ONLY runtime-data input that
//// reaches a control transfer is the integer `index`; the dispatched target is the stored
//// closure, invoked DIRECTLY as `target(args)` (a fun application). `rt_table` never
//// constructs a module/function atom from its inputs and never calls `erlang:apply/3` on
//// data-derived names — assert by construction/review (the unit-10 structural security
//// test extends this to the generated `call_indirect` lowering).
////
//// **Three guards, in order, each fail-closed**
//// (<https://webassembly.github.io/spec/core/exec/instructions.html>):
//// 1. `index` in `[0, size)` — else `UndefinedElement` ("undefined element");
//// 2. slot non-null (filled by an element segment) — else `UninitializedElement`
////    ("uninitialized element");
//// 3. exact STRUCTURAL `FuncType` match against the call site's expected type — else
////    `IndirectCallTypeMismatch` ("indirect call type mismatch").
//// The order is observable: an OOB index traps `UndefinedElement` BEFORE any null/type
//// check; a null in-range slot traps `UninitializedElement` BEFORE any type comparison.
////
//// **Fail-closed on an un-seeded cell (E3 isolation).** `init_elem`/`call_indirect` read
//// the cell via `rt_state.table_get`, which raises (a node-safe internal error) on an
//// un-seeded cell rather than fabricating an empty table that silently "succeeds".
//// Tier-O, never NIF.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}
import gleam/list
import gleam/option.{type Option, None, Some}
import twocore/ir.{
  type FuncType, type TrapReason, IndirectCallTypeMismatch, TableOutOfBounds,
  UndefinedElement, UninitializedElement,
}
import twocore/runtime/rt_state.{type InstanceState}

/// The funcref table value held (opaque, as `Dynamic`) in the cell's `table` field.
///
/// - `size`: the number of slots — the declared `min`. MVP has no `table.grow`, so it is
///   fixed at `new` time; `call_indirect`'s bounds guard checks `index` against it.
/// - `slots`: SPARSE map slot-index → `#(FuncType, closure)`. A PRESENT key = a filled
///   slot (guard 2 passes); an ABSENT key in `[0, size)` = a null/uninitialised slot
///   (guard 2 → `UninitializedElement`). Private: the value never escapes `rt_table`
///   except as the opaque `Dynamic` in the cell.
type Table {
  Table(size: Int, slots: Dict(Int, #(FuncType, fn(List(Int)) -> List(Int))))
}

/// Coerce a `Table` into the opaque `Dynamic` the cell stores. Identity at run time
/// (`gleam_stdlib:identity/1`); tier-O, cannot fail.
@external(erlang, "gleam_stdlib", "identity")
fn table_to_dynamic(table: Table) -> Dynamic

/// Coerce the cell's opaque `Dynamic` back into a `Table`. Identity at run time; sound
/// because `rt_table` is the sole producer of the term `rt_state` holds in the `table` slot.
@external(erlang, "gleam_stdlib", "identity")
fn dynamic_to_table(value: Dynamic) -> Table

/// Build a FRESH opaque table of `min` null (uninitialised) slots.
///
/// - `min`: the table's initial entry count (the declared minimum). Becomes the fixed
///   `size`; every slot is initially absent (null), so a `call_indirect` to any in-range
///   slot before an element segment fills it traps `UninitializedElement`.
/// - `max`: optional maximum entry count, or `None` for unbounded. UNUSED in the MVP:
///   funcref tables cannot grow (`table.grow` is a post-MVP reference-types op) and are
///   only ever filled via `init_elem`, so there is no growth to bound.
/// - Returns the fresh table value as `Dynamic` (opaque, ready to hand to
///   `rt_state.seed`). `rt_state` cannot construct it (it does not import `rt_table`), so
///   the generated `instantiate` entry calls this. Total.
pub fn new(min: Int, _max: Option(Int)) -> Dynamic {
  table_to_dynamic(Table(size: min, slots: dict.new()))
}

/// Write an active ELEMENT segment's `entries` into this process's table starting at
/// `offset`, at instantiation. Whole-range bounds-checked (all-or-nothing).
///
/// - `offset`: the first entry index written; `entries[k]` goes into slot `offset + k`.
/// - `entries`: the type-tagged build-controlled closures — each `#(FuncType, closure)`
///   pairs an element function's IR signature with a closure over the generated function.
///   The `FuncType` tag is what guard 3 of `call_indirect` matches; the closure is invoked
///   directly (never `apply` of a data-derived name).
/// - Bounds check FIRST, before any write: if `offset < 0` or
///   `offset + length(entries) > size`, return `Error(TableOutOfBounds)` and write NOTHING
///   (no partial table writes — a slot the failed segment would have filled still reads as
///   null). On success returns `Ok(Nil)` and the cell's table now holds the entries.
/// - Failure modes: `Error(TableOutOfBounds)` on an out-of-range segment; raises (fail-
///   closed, via `rt_state.table_get`) if this process's cell is un-seeded.
pub fn init_elem(
  offset: Int,
  entries: List(#(FuncType, fn(List(Int)) -> List(Int))),
) -> Result(Nil, TrapReason) {
  let table = dynamic_to_table(rt_state.table_get())
  // Whole-range bounds check up front: the segment must fit entirely, else write nothing.
  case offset < 0 || offset + list.length(entries) > table.size {
    True -> Error(TableOutOfBounds)
    False -> {
      // Fold each entry into its slot: entries[k] → slot offset + k.
      let new_slots =
        list.index_fold(entries, table.slots, fn(slots, entry, k) {
          dict.insert(slots, offset + k, entry)
        })
      rt_state.table_put(table_to_dynamic(Table(..table, slots: new_slots)))
      Ok(Nil)
    }
  }
}

/// Dispatch a `call_indirect` through this process's table — THE 3-fault fail-closed
/// dispatch.
///
/// Reads the cell's table, applies the three guards IN ORDER, and on success invokes the
/// slot's build-controlled `target` with `args` directly (`target(args)` — a closure
/// application, NOT a data-driven `apply`).
///
/// - `index`: the table entry index to call (the only runtime-data input that reaches a
///   control transfer).
/// - `expected_type`: the call site's statically-required `FuncType`. Guard 3 matches the
///   stored entry's type tag against this with exact STRUCTURAL equality (`==`) — two
///   structurally-equal `FuncType` values match even if they came from different typeidx
///   entries; differing params OR results mismatch.
/// - `args`: the call arguments as raw bit patterns.
/// - Returns `Ok(results)` (the callee's result values as raw bit patterns), or an
///   `Error(reason)` checked in this order:
///   - `UndefinedElement`         — `index < 0` or `index >= size`   (guard 1);
///   - `UninitializedElement`     — slot is null/absent              (guard 2);
///   - `IndirectCallTypeMismatch` — `entry_type != expected_type`    (guard 3).
/// - Failure modes: the three trap reasons above; raises (fail-closed, via
///   `rt_state.table_get`) if this process's cell is un-seeded.
pub fn call_indirect(
  index: Int,
  expected_type: FuncType,
  args: List(Int),
) -> Result(List(Int), TrapReason) {
  let table = dynamic_to_table(rt_state.table_get())
  // Guard 1 — bounds. Must fire before any null/type inspection.
  case index < 0 || index >= table.size {
    True -> Error(UndefinedElement)
    False ->
      // Guard 2 — null slot. An absent key is an uninitialised slot.
      case dict.get(table.slots, index) {
        Error(Nil) -> Error(UninitializedElement)
        Ok(#(entry_type, target)) ->
          // Guard 3 — exact structural FuncType match.
          case entry_type == expected_type {
            False -> Error(IndirectCallTypeMismatch)
            // Build-controlled invocation: invoke the STORED closure directly.
            True -> Ok(target(args))
          }
      }
  }
}

// ── the paged THREADED family (state_strategy: Threaded; owner: unit P4-06) ──────
//
// The purely-functional twin of the cell surface above (which owns `new`/`init_elem`/
// `call_indirect`, untouched). Under `state_strategy: Threaded` the SAME immutable `Table`
// handle travels in `st.table` (projected via `rt_state.table`, re-injected via
// `rt_state.with_table`) instead of the pdict cell — the §10 uniform-threading rule. The
// three guards and the `TrapReason`s are IDENTICAL to the cell surface (§F); only the state
// seam differs, so a tier is a pure state-strategy composition (unit 06's headline invariant:
// TablePaged ≡ ets ≡ atomics on `call_indirect`).
//
// The threaded closure ABI is `fn(InstanceState, List(Int)) -> #(List(Int), InstanceState)`
// (the callee threads any memory/global updates), which differs from the cell ABI
// `fn(List(Int)) -> List(Int)`. Both closure shapes are the SAME BEAM term at run time (a fun),
// so — since `new` builds one `Table` handle for BOTH strategies and the threaded family is the
// SOLE reader of what it writes — the threaded closure is coerced through the `Table`'s cell-typed
// slot via `gleam_stdlib:identity` on the way in and back out. No cell op ever reads a threaded
// slot (a threaded build never touches the pdict cell), so the coercion is sound.

/// Coerce a threaded closure into the cell-typed slot the `Table` record stores. Identity at run
/// time (`gleam_stdlib:identity/1`); sound because only the threaded family reads it back.
@external(erlang, "gleam_stdlib", "identity")
fn threaded_as_cell(
  f: fn(InstanceState, List(Int)) -> #(List(Int), InstanceState),
) -> fn(List(Int)) -> List(Int)

/// Coerce a stored slot closure back to the threaded ABI. Identity at run time; sound because a
/// threaded-written slot is only ever read by the threaded family.
@external(erlang, "gleam_stdlib", "identity")
fn cell_as_threaded(
  f: fn(List(Int)) -> List(Int),
) -> fn(InstanceState, List(Int)) -> #(List(Int), InstanceState)

/// Threaded `init_elem`: project `st.table`, whole-range bounds-check, and RETURN the record with
/// the rebuilt immutable `Table`.
///
/// - `st`: the threaded instance-state record; its `table` slot holds the `Table` handle.
/// - `offset`: the first slot written; `entries[k]` goes into slot `offset + k`.
/// - `entries`: the type-tagged build-controlled threaded closures — each `#(FuncType, closure)`
///   pairs an element function's IR signature with a closure over the generated function.
/// - Bounds check FIRST, before any write: if `offset < 0` or `offset + length(entries) > size`,
///   return `Error(TableOutOfBounds)` and write NOTHING (all-or-nothing). On success returns
///   `Ok(st')` where `st'.table` is a NEW immutable `Table` with the entries (the §10 rule for an
///   immutable backend: rebuilt handle, structural sharing across versions is free).
pub fn t_init_elem(
  st: InstanceState,
  offset: Int,
  entries: List(
    #(FuncType, fn(InstanceState, List(Int)) -> #(List(Int), InstanceState)),
  ),
) -> Result(InstanceState, TrapReason) {
  let table = dynamic_to_table(rt_state.table(st))
  case offset < 0 || offset + list.length(entries) > table.size {
    True -> Error(TableOutOfBounds)
    False -> {
      let new_slots =
        list.index_fold(entries, table.slots, fn(slots, entry, k) {
          dict.insert(slots, offset + k, #(entry.0, threaded_as_cell(entry.1)))
        })
      Ok(rt_state.with_table(
        st,
        table_to_dynamic(Table(..table, slots: new_slots)),
      ))
    }
  }
}

/// Threaded `call_indirect`: the 3-fault dispatch (§F) over `st.table`, invoking the slot's target
/// as `target(st, args) -> #(results, st')`.
///
/// - `st`: the threaded instance-state record.
/// - `index`/`expected_type`/`args`: as the cell `call_indirect`. Guard 3 is exact STRUCTURAL
///   `FuncType` equality (`==`).
/// - Returns `Ok(#(results, st'))` where `st'` is whatever the invoked build-controlled closure
///   threaded (memory/global updates the callee made), or the three `Error(reason)`s in guard
///   order (`UndefinedElement` → `UninitializedElement` → `IndirectCallTypeMismatch`). The table
///   slot is unchanged — the MVP dispatch never mutates the table.
pub fn t_call_indirect(
  st: InstanceState,
  index: Int,
  expected_type: FuncType,
  args: List(Int),
) -> Result(#(List(Int), InstanceState), TrapReason) {
  let table = dynamic_to_table(rt_state.table(st))
  case index < 0 || index >= table.size {
    True -> Error(UndefinedElement)
    False ->
      case dict.get(table.slots, index) {
        Error(Nil) -> Error(UninitializedElement)
        Ok(#(entry_type, target)) ->
          case entry_type == expected_type {
            False -> Error(IndirectCallTypeMismatch)
            True -> Ok(cell_as_threaded(target)(st, args))
          }
      }
  }
}

/// The differential canon hook (§B.2 / §F) — the tier's whole slot image as a `size`-length list:
/// `None` = a null slot, `Some(ty)` = a filled slot's structural `FuncType` tag. `TablePaged` is
/// the differential ORACLE, so this is the reference image unit 09 compares every tier against
/// (the table analog of `rt_mem.to_flat`). Closures are not comparable; behaviour is compared via
/// `call_indirect`. Tests only.
///
/// - `handle`: the opaque table `Dynamic` (from `rt_state.table(st)` or `rt_state.table_get()`).
/// - Returns the `size`-length `List(Option(FuncType))` slot image. Total.
pub fn to_canon(handle: Dynamic) -> List(Option(FuncType)) {
  let table = dynamic_to_table(handle)
  list.map(indices(table.size), fn(i) {
    case dict.get(table.slots, i) {
      Error(Nil) -> None
      Ok(#(ty, _target)) -> Some(ty)
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
