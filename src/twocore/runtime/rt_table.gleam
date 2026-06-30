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
import gleam/option.{type Option}
import twocore/ir.{
  type FuncType, type TrapReason, IndirectCallTypeMismatch, TableOutOfBounds,
  UndefinedElement, UninitializedElement,
}
import twocore/runtime/rt_state

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
