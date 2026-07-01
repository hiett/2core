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
//// **The key.** The cell lives under ONE fixed key, the 0-field Gleam constructor
//// `TwocoreRtState`, which compiles to the unique, namespace-hygienic atom
//// `twocore_rt_state` (exactly the `rt_meter` `TwocoreRtMeterFuel → twocore_rt_meter_fuel`
//// pattern). One key holds the WHOLE `{mem, globals, table}` record, so it cannot collide
//// with `rt_meter`'s fuel key (or any other pdict use) and a (re)seed is an atomic
//// one-`put` replacement of all prior state.
////
//// **Tier-O, by reference, constant space.** Reads use `erlang:get/1`, which returns the
//// stored term BY REFERENCE (no copy); writes use `erlang:put/2`, which replaces a single
//// root (the superseded record becomes garbage, GC'd with the process). This is the proven
//// `rt_meter` posture (a 100k-iteration pdict store loop was constant-space on OTP 29). It
//// is tier-O (OTP-native, memory-safe, no NIF), which Safe permits. ETS is the WRONG cell
//// here: it deep-copies the whole term on every read/write and has no auto-GC.
////
//// **Fail-closed (E3).** Operating on an UN-SEEDED cell is an internal invariant
//// violation (it is unreachable under the one-instance-one-process harness contract), NOT
//// a WASM `TrapReason`: the bodies raise a distinct internal error (a node-safe `panic`)
//// rather than reading garbage. Reading garbage out of an empty pdict — fabricating a
//// zeroed cell to "recover" — is exactly the bug this guard exists to prevent.
////
//// **Opacity.** `rt_state` does NOT import `rt_mem`/`rt_table`, so there is no circular
//// import: the memory and table values are held as `gleam/dynamic.Dynamic`. `rt_mem` owns
//// the memory value's shape and `rt_table` owns the table value's shape; each coerces its
//// own field via `mem_get`/`mem_put` / `table_get`/`table_put`. Mutable globals are
//// raw-bit-pattern `Int`s keyed by name.
////
//// **Globals are raw bits (D5).** i32/i64/f32/f64 globals are all stored identically as a
//// raw bit-pattern `Int`. f32/f64 are NEVER round-tripped through a BEAM double (a double
//// cannot hold NaN payloads / signalling bits), so `rt_state` does no float math and needs
//// no per-global type tag.
////
//// **Effect note (E6).** `global.get`/`global.set` (and the mem/table accessors) are
//// side-effecting: a future optimizer must treat them as barriers — never CSE, reorder, or
//// dead-code-eliminate across them.
////
//// **Pitfall — one-instance-one-process is load-bearing.** pdict is strictly per-process.
//// If a host or another process calls an instance export directly, `rt_state` reads the
//// CALLER's (empty) pdict → silent corruption. The contract is that every cross-process
//// entry goes via the instance's owned process; the harness (unit 11) enforces it.

import gleam/dict.{type Dict}
import gleam/dynamic.{type Dynamic}

/// `erlang:put/2` — store `value` under `key` in the current process dictionary; returns
/// the previous value (or the atom `undefined` if unset), which callers here discard.
/// Direct BIF reference; process-local, cannot crash the node.
@external(erlang, "erlang", "put")
fn erlang_put(key: k, value: v) -> Dynamic

/// `erlang:erase/1` — remove `key` from the current process dictionary, returning its
/// previous value (or `undefined`), which callers here discard. Direct BIF reference;
/// process-local, cannot crash the node.
@external(erlang, "erlang", "erase")
fn erlang_erase(key: k) -> Dynamic

/// Read this process's cell with a sound presence check (the `twocore_`-namespaced shim,
/// mirroring `twocore_codegen_ffi`/`twocore_cli_ffi`). Returns `Ok(state)` when the key
/// holds a cell, or `Error(Nil)` when it is absent (the BIF's `undefined`). The present
/// term is returned BY REFERENCE wrapped in `{ok, _}` (no deep copy) — `rt_state` is the
/// sole writer of this key, so coercing the present term back to `InstanceState` is sound.
@external(erlang, "twocore_rt_state_ffi", "read_cell")
fn read_cell(key: k) -> Result(InstanceState, Nil)

/// The process-dictionary key holding this process's whole instance cell. As a 0-field
/// Gleam constructor it compiles to the unique, namespace-hygienic atom `twocore_rt_state`,
/// so it cannot clash with `rt_meter`'s fuel key or any other library's pdict keys.
type StateKey {
  TwocoreRtState
}

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
///   constant init expression), in declaration order. Duplicate names keep the LAST pair
///   (`dict.from_list` semantics); validation guarantees unique global names upstream.
/// - `table`: a fresh table value built by `rt_table.new` (stored as-is).
pub type StateDecl {
  StateDecl(mem: Dynamic, globals: List(#(String, Int)), table: Dynamic)
}

/// Seed a FRESH per-instance cell for THIS process from `decl`, RESETTING any prior state
/// (one-instance-one-process). Called once by the generated `instantiate` entry before any
/// element/data segment is written or the start function runs.
///
/// - `decl`: the fresh mem/globals/table to install. `decl.globals` is materialised into a
///   `Dict` keyed by name.
/// - Returns `Nil`. The body installs the cell with a single `erlang:put/2`, so the reset
///   is atomic: the old record (if any) is discarded wholesale and becomes garbage. Total;
///   never raises. Routes through the shared `build` constructor so a `Cell` build (this
///   `seed`) and a `Threaded` build (`fresh`) materialise BYTE-IDENTICAL state (G7).
pub fn seed(decl: StateDecl) -> Nil {
  put_cell(build(decl))
}

/// Drop this process's cell (used between instances when a process is reused). After
/// `clear`, any state accessor is an un-seeded-cell invariant violation until the next
/// `seed`.
///
/// - Returns `Nil`. Side-effecting (process-local `erlang:erase/1`). Total; never raises
///   (erasing an absent key is a no-op).
pub fn clear() -> Nil {
  let _ = erlang_erase(TwocoreRtState)
  Nil
}

/// Read the opaque memory value out of this process's cell (for `rt_mem`).
///
/// - Returns the `Dynamic` memory value, unchanged (rt_state never inspects it). Fail-closed:
///   `panic`s (a node-safe internal error) on an un-seeded cell — never returns garbage.
pub fn mem_get() -> Dynamic {
  require_cell().mem
}

/// Write a new opaque memory value back into this process's cell (for `rt_mem`).
///
/// - `mem`: the updated memory value (rt_mem produces it; rt_state stores it opaquely).
/// - Returns `Nil`. Fail-closed: `panic`s on an un-seeded cell (the read-modify-write needs
///   a present cell). The other fields (globals/table) are preserved by reference.
pub fn mem_put(mem: Dynamic) -> Nil {
  put_cell(InstanceState(..require_cell(), mem: mem))
}

/// Read the opaque table value out of this process's cell (for `rt_table`).
///
/// - Returns the `Dynamic` table value, unchanged. Fail-closed: `panic`s on an un-seeded
///   cell — never returns garbage.
pub fn table_get() -> Dynamic {
  require_cell().table
}

/// Write a new opaque table value back into this process's cell (for `rt_table`).
///
/// - `table`: the updated table value (rt_table produces it; rt_state stores it opaquely).
/// - Returns `Nil`. Fail-closed: `panic`s on an un-seeded cell. The other fields are
///   preserved by reference.
pub fn table_put(table: Dynamic) -> Nil {
  put_cell(InstanceState(..require_cell(), table: table))
}

/// Read mutable global `name`'s current raw bit pattern from this process's cell.
///
/// - `name`: the global's name.
/// - Returns the global's value as a raw bit pattern (`Int`) — bit-exact, never coerced to
///   a BEAM double. Fail-closed: `panic`s (internal invariant violation, NOT a WASM trap)
///   on an un-seeded cell OR an undeclared `name`; both are unreachable under validation +
///   the harness contract, so they are defensive guards, never a normal path.
pub fn global_get(name: String) -> Int {
  case dict.get(require_cell().globals, name) {
    Ok(value) -> value
    Error(Nil) ->
      panic as "rt_state.global_get: undeclared global (internal invariant violation)"
  }
}

/// Write `value` (a raw bit pattern) into mutable global `name` in this process's cell.
///
/// - `name`: the global's name.
/// - `value`: the new raw bit pattern (stored verbatim; rt_state does no float math).
/// - Returns `Nil`. Side-effecting (read-cell → `dict.insert` → put-cell). Fail-closed:
///   `panic`s on an un-seeded cell. `value` overwrites only `name`; other globals are
///   preserved by reference. Immutability of `const` globals is enforced at validation
///   (unit 08), not here — this is a mechanical write.
pub fn global_set(name: String, value: Int) -> Nil {
  let state = require_cell()
  put_cell(
    InstanceState(..state, globals: dict.insert(state.globals, name, value)),
  )
}

// ── tier-P: the threaded instance-state surface (unit 03; NO process dictionary) ──
//
// The purely-functional twin of the cell surface above. Under `state_strategy: Threaded`
// (Phase-4 keystone §A), generated code threads the SAME `InstanceState` record as an
// ordinary value — every state-reaching function takes it as a leading parameter and returns
// the (possibly updated) record. There is NO ambient location the state lives in: it is a
// Gleam value on the stack. This surface reaches NONE of the module's three pdict externals
// (`erlang_put`/`erlang_erase`/`read_cell`) — it is pure `dict.*` + record construction, so
// it links no process dictionary, no OTP-native state (atomics/ets/persistent_term), and no
// NIF (the "runs-anywhere" posture, G6). The cell surface above stays untouched and parallel.

/// Build the initial threaded instance-state record from the SAME `StateDecl` the cell
/// strategy passes to `seed` — but RETURN it as a value (no pdict write). Called once by the
/// threaded `instantiate/0` (unit 02) before any element/data segment is written or the start
/// function runs.
///
/// - `decl`: the fresh per-layer values to install. `decl.globals` is materialised into the
///   `globals` `Dict` (keyed by name; duplicate names keep the LAST, per `dict.from_list`);
///   `mem`/`table` are stored opaquely as-is (already built by `rt_mem.fresh`/`rt_table.new`,
///   never inspected here).
/// - Returns the fresh `InstanceState`. Total; never raises; touches NO process dictionary.
///   Shares the `build` constructor with `seed`, so a `Threaded` build and a `Cell` build
///   start from BYTE-IDENTICAL state (G7).
pub fn fresh(decl: StateDecl) -> InstanceState {
  build(decl)
}

/// Read mutable global `name`'s raw bit pattern from the threaded record. READ-ONLY: `st` is
/// unchanged (the caller keeps threading the same record forward).
///
/// - `st`: the threaded instance-state record.
/// - `name`: the global's name.
/// - Returns the global's value as a raw bit pattern (`Int`) — bit-exact, never coerced to a
///   BEAM double (D5). Fail-closed: an undeclared `name` `panic`s a distinct internal error
///   (a node-safe internal-invariant violation, NOT a WASM `TrapReason`); it is unreachable
///   post-validation (global existence is a validation property, unit P2-08), so this is a
///   defensive guard, never a normal path — it never fabricates a value.
///   (<https://webassembly.github.io/spec/core/exec/instructions.html#variable-instructions>)
pub fn t_global_get(st: InstanceState, name: String) -> Int {
  case dict.get(st.globals, name) {
    Ok(value) -> value
    Error(Nil) ->
      panic as "rt_state.t_global_get: undeclared global (internal invariant violation)"
  }
}

/// Rebind mutable global `name` to `value`, RETURNING the updated record.
///
/// - `st`: the threaded instance-state record.
/// - `name`: the global's name.
/// - `value`: the new raw bit pattern (stored verbatim; `rt_state` does no float math, so a
///   NaN payload / signalling bit / `-0.0` round-trips exactly — D5).
/// - Returns a NEW `InstanceState` whose `globals` is `dict.insert`ed (only the named global
///   changes) and whose `mem`/`table` fields are shared by reference — NOT a deep copy (the
///   §10 uniform-threading rule for a mutating op). Total; never raises; touches NO process
///   dictionary. Immutability of `const` globals is a validation property (unit P2-08), not
///   enforced here — this is a mechanical write.
///   (<https://webassembly.github.io/spec/core/exec/instructions.html#variable-instructions>)
pub fn t_global_set(
  st: InstanceState,
  name: String,
  value: Int,
) -> InstanceState {
  InstanceState(..st, globals: dict.insert(st.globals, name, value))
}

/// Project the opaque memory value out of the threaded record (the field seam `rt_mem`'s
/// tier-P wrappers, unit 04, project → drive the pure core → re-inject). READ-ONLY.
///
/// - `st`: the threaded instance-state record.
/// - Returns the `mem` field unchanged — a `Dynamic` `rt_state` never inspects (`rt_mem` owns
///   its shape). Total; never raises.
pub fn mem(st: InstanceState) -> Dynamic {
  st.mem
}

/// Rebind the memory field, RETURNING the updated record (for `rt_mem`'s `t_store`/`t_grow`/
/// `t_init_data`, which inject a new opaque `mem` after driving the pure core).
///
/// - `st`: the threaded instance-state record.
/// - `mem`: the new opaque memory value (`rt_mem` produces it; `rt_state` stores it as-is).
/// - Returns a NEW `InstanceState` sharing `globals`/`table` by reference — NOT a copy. Total;
///   never raises; touches NO process dictionary.
pub fn with_mem(st: InstanceState, mem: Dynamic) -> InstanceState {
  InstanceState(..st, mem: mem)
}

/// Project the opaque table value out of the threaded record (the field seam `rt_table`'s
/// tier-P wrappers, unit 06, project). READ-ONLY.
///
/// - `st`: the threaded instance-state record.
/// - Returns the `table` field unchanged — a `Dynamic` `rt_state` never inspects (`rt_table`
///   owns its shape). Total; never raises.
pub fn table(st: InstanceState) -> Dynamic {
  st.table
}

/// Rebind the table field, RETURNING the updated record (for `rt_table`'s `t_init_elem`/
/// `t_call_indirect`, which inject a new opaque `table`).
///
/// - `st`: the threaded instance-state record.
/// - `table`: the new opaque table value (`rt_table` produces it; `rt_state` stores it as-is).
/// - Returns a NEW `InstanceState` sharing `mem`/`globals` by reference — NOT a copy. Total;
///   never raises; touches NO process dictionary.
pub fn with_table(st: InstanceState, table: Dynamic) -> InstanceState {
  InstanceState(..st, table: table)
}

// ── internal helpers ──────────────────────────────────────────────────────────

/// The single record builder shared by `seed` (cell path — installs it in the pdict) and
/// `fresh` (threaded path — returns it). Sharing ONE constructor guarantees the two strategies
/// materialise BYTE-IDENTICAL state (G7 — a `Threaded` build and a `Cell` build compute
/// identical results). `decl.globals` becomes the `globals` `Dict`; `mem`/`table` are stored
/// opaquely. Total; never raises; touches NO process dictionary (the pdict write, if any, is
/// the caller's — only `seed` does it). (Private: the shared materialisation seam.)
fn build(decl: StateDecl) -> InstanceState {
  InstanceState(
    mem: decl.mem,
    globals: dict.from_list(decl.globals),
    table: decl.table,
  )
}

/// Install `state` as this process's cell under the fixed key. The superseded record (if
/// any) becomes garbage. Total; never raises. (Private: the seam between rt_state's public
/// ops and the raw pdict BIF.)
fn put_cell(state: InstanceState) -> Nil {
  let _ = erlang_put(TwocoreRtState, state)
  Nil
}

/// Read this process's cell, FAILING CLOSED on an un-seeded cell. `panic`s a distinct
/// internal error (node-safe) rather than fabricating a zeroed cell — reading garbage out
/// of an empty pdict is the bug the guard prevents. A present cell coerces in O(1) (the
/// term is shared by reference; no deep copy). Private: the single read chokepoint every
/// fail-closed accessor goes through.
fn require_cell() -> InstanceState {
  case read_cell(TwocoreRtState) {
    Ok(state) -> state
    Error(Nil) ->
      panic as "rt_state: operation on an un-seeded instance cell (one-instance-one-process contract violated)"
  }
}
