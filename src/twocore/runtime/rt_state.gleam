//// `rt_state` — the per-instance **cell** holder (`«CELL-STATE-ABI-FROZEN»`; owner: unit
//// 03). SIGNATURES frozen by unit 01; BODIES implemented by unit 03.
////
//// **One-instance-one-process (E1).** An instance's mutable state — its linear memory,
//// its mutable globals, and its table — lives in THIS process's dictionary under a single
//// fixed namespaced key, holding an opaque `InstanceState` record. The harness/linker
//// (unit 11) runs `instantiate` plus every `invoke` of an instance inside one owned
//// process, so the cell is naturally isolated and reset per (re)instantiation. Generated
//// function arities are unchanged — the state handle never becomes a loop-carried value
//// (it stays hidden in the cell), preserving the Phase-1 constant-space tail loop.
////
//// **Fail-closed (E3).** Operating on an UN-SEEDED cell is an internal invariant
//// violation (it is unreachable under the one-instance-one-process harness contract), NOT
//// a WASM `TrapReason`: the bodies raise a distinct internal error (a node-safe process
//// crash) rather than reading garbage. Tier-O (process-local), never NIF.
////
//// **Opacity.** `rt_state` does NOT import `rt_mem`/`rt_table`, so there is no circular
//// import: the memory and table values are held as `gleam/dynamic.Dynamic`. `rt_mem` owns
//// the memory value's shape and `rt_table` owns the table value's shape; each coerces its
//// own field via `mem_get`/`mem_put` / `table_get`/`table_put`. Mutable globals are
//// raw-bit-pattern `Int`s keyed by name.
////
//// NB (freeze): the public signatures below are frozen by name/arity/types. Their `todo`
//// bodies leave every parameter unused, so each is written `_name` (the Gleam idiom for an
//// unimplemented stub); unit 03 drops the underscore when it implements the body.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}

/// The opaque per-instance state record held in the process cell.
///
/// - `mem`: the linear-memory value, OPAQUE to `rt_state` (built and interpreted by
///   `rt_mem`). Held as `Dynamic` to avoid importing `rt_mem`.
/// - `globals`: the mutable globals as raw IEEE/two's-complement bit patterns, keyed by
///   global name.
/// - `table`: the funcref-table value, OPAQUE to `rt_state` (built and interpreted by
///   `rt_table`). Held as `Dynamic` to avoid importing `rt_table`.
pub type InstanceState {
  InstanceState(mem: Dynamic, globals: Dict(String, Int), table: Dynamic)
}

/// What the generated `instantiate` entry passes to `seed`: the FRESH per-layer values to
/// install into a brand-new cell.
///
/// - `mem`: a fresh memory value built by `rt_mem.fresh` (rt_state stores it as-is,
///   preserving opacity — it never constructs memory).
/// - `globals`: the initial globals as `#(name, raw_bits)` pairs (from each global's
///   constant init expression).
/// - `table`: a fresh table value built by `rt_table.new` (stored as-is).
pub type StateDecl {
  StateDecl(mem: Dynamic, globals: List(#(String, Int)), table: Dynamic)
}

/// Seed a FRESH per-instance cell for THIS process from `decl`, RESETTING any prior state
/// (one-instance-one-process). Called once by the generated `instantiate` entry before any
/// element/data segment is written or the start function runs.
///
/// - `decl`: the fresh mem/globals/table to install.
/// - Returns `Nil`. The body installs the cell (a process-local side effect).
pub fn seed(_decl: StateDecl) -> Nil {
  todo
}

/// Drop this process's cell (used between instances when a process is reused). After
/// `clear`, any state accessor is an un-seeded-cell invariant violation until the next
/// `seed`.
///
/// - Returns `Nil`. Side-effecting (process-local).
pub fn clear() -> Nil {
  todo
}

/// Read the opaque memory value out of this process's cell (for `rt_mem`).
///
/// - Returns the `Dynamic` memory value. Fail-closed: raises an internal error on an
///   un-seeded cell (never returns garbage).
pub fn mem_get() -> Dynamic {
  todo
}

/// Write a new opaque memory value back into this process's cell (for `rt_mem`).
///
/// - `mem`: the updated memory value (rt_mem produces it; rt_state stores it opaquely).
/// - Returns `Nil`. Fail-closed on an un-seeded cell.
pub fn mem_put(_mem: Dynamic) -> Nil {
  todo
}

/// Read the opaque table value out of this process's cell (for `rt_table`).
///
/// - Returns the `Dynamic` table value. Fail-closed on an un-seeded cell.
pub fn table_get() -> Dynamic {
  todo
}

/// Write a new opaque table value back into this process's cell (for `rt_table`).
///
/// - `table`: the updated table value (rt_table produces it; rt_state stores it opaquely).
/// - Returns `Nil`. Fail-closed on an un-seeded cell.
pub fn table_put(_table: Dynamic) -> Nil {
  todo
}

/// Read mutable global `name`'s current raw bit pattern from this process's cell.
///
/// - `name`: the global's name.
/// - Returns the global's value as a raw bit pattern (`Int`). Fail-closed on an un-seeded
///   cell or an undeclared global (internal invariant violation, not a WASM trap).
pub fn global_get(_name: String) -> Int {
  todo
}

/// Write `value` (a raw bit pattern) into mutable global `name` in this process's cell.
///
/// - `name`: the global's name.
/// - `value`: the new raw bit pattern.
/// - Returns `Nil`. Side-effecting; fail-closed on an un-seeded cell.
pub fn global_set(_name: String, _value: Int) -> Nil {
  todo
}
