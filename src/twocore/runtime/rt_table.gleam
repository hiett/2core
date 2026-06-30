//// `rt_table` — the funcref table value + the 3-fault fail-closed `call_indirect`
//// dispatch (owner: unit 05). SIGNATURES frozen by unit 01; BODIES implemented by unit 05.
////
//// **State location.** The table value lives in the `table` field of THIS process's cell
//// (read via `rt_state.table_get`, written via `rt_state.table_put`); it is OPAQUE to
//// `rt_state`. `rt_table` owns its shape and coerces.
////
//// **No ambient authority (E3, D3a).** Dispatch goes through BUILD-CONTROLLED closures
//// populated from element segments — NEVER a data-driven `apply(Module, Fun, Args)` where
//// `Module`/`Fun` come from table/runtime data. Each entry is TYPE-TAGGED `#(FuncType,
//// closure)`: `emit_core` passes each element function's IR `FuncType` plus a closure over
//// the generated function.
////
//// **Three guards, in order, each fail-closed:**
//// 1. index in bounds — else `UndefinedElement`;
//// 2. slot non-null (filled) — else `UninitializedElement`;
//// 3. exact structural `FuncType` match against the call site's expected type — else
////    `IndirectCallTypeMismatch`.
//// Tier-O, never NIF.
////
//// NB (freeze): the public signatures below are frozen by name/arity/types. Their `todo`
//// bodies leave every parameter unused, so each is written `_name` (the Gleam idiom for an
//// unimplemented stub); unit 05 drops the underscore when it implements the body.

import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option}
import twocore/ir.{type FuncType, type TrapReason}

/// Build a FRESH opaque table of `min` null (uninitialised) slots.
///
/// - `min`: the table's initial entry count.
/// - `max`: optional maximum entry count, or `None` for unbounded (table growth is a
///   post-MVP op; Phase-2 only fills via element segments).
/// - Returns the fresh table value as `Dynamic` (opaque, ready to hand to
///   `rt_state.seed`). `rt_state` cannot construct it (it does not import `rt_table`), so
///   the generated `instantiate` entry calls this. Total.
pub fn new(_min: Int, _max: Option(Int)) -> Dynamic {
  todo
}

/// Write an active ELEMENT segment's `entries` into this process's table starting at
/// `offset`, at instantiation. Bounds-checked.
///
/// - `offset`: the first entry index written.
/// - `entries`: the type-tagged build-controlled closures — each `#(FuncType, closure)`
///   pairs an element function's IR signature with a closure over the generated function.
///   The `FuncType` tag is what guard 3 of `call_indirect` matches.
/// - Returns `Ok(Nil)`, or `Error(TableOutOfBounds)` if the segment does not fit (an
///   instantiation-time trap).
pub fn init_elem(
  _offset: Int,
  _entries: List(#(FuncType, fn(List(Int)) -> List(Int))),
) -> Result(Nil, TrapReason) {
  todo
}

/// Dispatch a `call_indirect` through this process's table.
///
/// - `index`: the table entry index to call.
/// - `expected_type`: the call site's statically-required `FuncType` (guard 3 matches the
///   stored entry's type tag against this, structurally and exactly).
/// - `args`: the call arguments as raw bit patterns.
/// - Returns `Ok(results)` (the callee's result values as raw bit patterns), or an
///   `Error`: `UndefinedElement` (index out of bounds), `UninitializedElement` (null
///   slot), or `IndirectCallTypeMismatch` (type tag mismatch) — checked in that order.
pub fn call_indirect(
  _index: Int,
  _expected_type: FuncType,
  _args: List(Int),
) -> Result(List(Int), TrapReason) {
  todo
}
