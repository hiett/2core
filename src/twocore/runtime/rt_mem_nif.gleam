//// `rt_mem_nif` — the tier-N (`nif`) linear-memory backend: the raw-`O(1)` NATIVE ceiling
//// (G2). **Unsafe-only; forbidden in Safe** (G6) — the linker rejects a `Safe + Nif` binding
//// fail-closed (unit 07 §B.4). Selected when `binding.mem_tier == Nif`, which unit 07 maps to
//// the module name `"twocore@runtime@rt_mem_nif"`; `emit_core` stays tier-agnostic (it reads
//// only `mem_module`, never the tier).
////
//// **Honest status (G8) — the C NIF is DEFERRED; this is a NODE-SAFE REFERENCE SKELETON.**
//// A production tier-N memory is a C NIF (a raw pointer into `enif_alloc`'d bytes, the
//// bounds-check enforced *in C*, a bug there a genuine host escape / node crash) and needs a
//// native build toolchain this project does not ship (verified: no `c_src/`, no native config
//// in `gleam.toml`, no per-platform `.so`). Rather than half-ship an untested `.so`, Phase 4
//// **documents the C NIF as deferred** (the drop-in seam is fixed in the unit doc §B.3) and the
//// BODIES here **delegate to the already-proven paged core** (`twocore/runtime/rt_mem`). So this
//// module is spec-correct **by construction** — it *is* the paged algebra, which unit P2-04
//// differentially proved against the flat-binary oracle — but it carries the paged **rebuild**
//// cost, **NOT the raw-`O(1)` native ceiling**. Being pure BEAM it also **cannot crash the node**
//// (unlike the real NIF) and needs zero FFI.
////
//// **The tier's CLASSIFICATION is a property of its intended PRODUCTION impl, not of this body.**
//// tier-N is Unsafe-only / Safe-forbidden because the *native* code that will replace this
//// skeleton can escape the host on a bounds bug (§C, keystone §B.4). The Safe-forbidden gate
//// exists to contain that native impl the day the `.so` drops in — behind these **byte-identical**
//// heads, with zero call-site change (units 07/08/09 and the `emit_core` seam are untouched).
//// This module does NOT itself construct a `Safe + Nif` binding; the enforcing gate is unit 07's
//// `validate_binding` (Safe + Nif → `Error(SafeForbidsNif)`, fail-closed).
////
//// **Behaviour is frozen, not just shape** (the §11 security invariant, G6): little-endian,
//// no-wrap effective address (`ea = addr + offset` as a bignum, never masked), trap-before-write
//// (all-or-nothing multi-byte stores), a bounds-check on every access, the Safe max-pages cap,
//// and f32/f64 as raw-byte moves over the IEEE bit pattern (D5). All inherited unchanged from the
//// delegated paged core, so tier-N is byte-identical to the spec via the shared oracle (§D).
////
//// **Coercion soundness.** Under `mem_tier == Nif` the cell / threaded `mem` slot is produced
//// SOLELY by this module's `fresh` (which calls `rt_mem.fresh`), so the opaque `Dynamic` there is
//// always a paged `Mem`; delegating to `rt_mem`'s own cell / threaded / `to_flat` entry points
//// (each of which coerces via `gleam_stdlib:identity/1`, a no-op) is therefore sound.

import gleam/dynamic.{type Dynamic}
import gleam/option.{type Option}
import twocore/ir.{type TrapReason}
import twocore/runtime/rt_mem
import twocore/runtime/rt_state.{type InstanceState}

// ───────────────────────────── the cell-backed family (state_strategy: Cell) ─────────────────────────────
//
// Same frozen heads as paged/atomics, operating on the `mem` slot of THIS process's cell. Each
// body re-exports the corresponding `rt_mem` cell entry point — the node-safe skeleton (§B.2):
// spec-correct, NOT the native ceiling. `rt_mem_nif` never calls `rt_trap`; the `emit_core` seam
// does the `{ok,_}`/`{error,R}` case + raise (keystone §A.3).

/// Build a FRESH tier-N memory of `min_pages` zero-filled 64 KiB pages, returning the opaque
/// handle as `Dynamic` (ready for `rt_state.seed`).
///
/// - `min_pages`: the initial page count (the module's declared memory minimum).
/// - `max_pages`: the declared maximum in pages, or `None` for "unbounded" (still subject to
///   `safe_cap`). tier-N is Unsafe-only, so `None` can leave the effective max at the full
///   2¹⁶-page address space; the paged skeleton is sparse, so no eager allocation results.
/// - `safe_cap`: the finite Safe max-pages cap, baked into the returned value so `grow` enforces
///   it without a profile parameter. The baked effective max is
///   `min(declared_max ?? safe_cap, safe_cap, 65536)`.
/// - Returns the fresh memory value as `Dynamic` (opaque). Total — never fails.
///
/// **NOT the native ceiling:** delegates to `rt_mem.fresh`, so the handle is a paged `Mem`, not a
/// native resource. The real C NIF (deferred, §B.3) drops in behind this identical head.
pub fn fresh(min_pages: Int, max_pages: Option(Int), safe_cap: Int) -> Dynamic {
  rt_mem.fresh(min_pages, max_pages, safe_cap)
}

/// Load `bytes` bytes (1/2/4/8) little-endian at `ea = addr(unsigned i32) + offset`, normalised
/// to `result_width` bits (`signed` ⇒ sign-extend, else zero-extend). Reads the handle from the
/// cell.
///
/// - `bytes`: the access width in bytes (1/2/4/8).
/// - `signed`: whether a sub-word load is sign-extended to `result_width` (else zero-extended);
///   irrelevant when `bytes * 8 == result_width`.
/// - `result_width`: the result's width in bits (32 or 64) — disambiguates `i32.load8_s` from
///   `i64.load8_s`.
/// - `addr`/`offset`: the unsigned i32 base and static offset (added as a bignum — no wrap).
/// - Returns `Ok(bits)` (the loaded value as a raw bit pattern), or `Error(MemoryOutOfBounds)`
///   iff `ea + bytes > byte_len`. Read-only.
///
/// **NOT the native ceiling:** delegates to `rt_mem.load` (paged rebuild cost).
pub fn load(
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Result(Int, TrapReason) {
  rt_mem.load(bytes, signed, result_width, addr, offset)
}

/// Store `value`'s low `bytes` bytes (1/2/4/8) little-endian at `ea`. Traps BEFORE any byte is
/// written if out of bounds (§11, all-or-nothing — zero corruption).
///
/// - `bytes`: the store width in bytes (1/2/4/8); the value's sign is irrelevant.
/// - `addr`/`offset`: the unsigned i32 base and static offset (bignum — no wrap).
/// - `value`: the raw bit pattern whose low `bytes` bytes are written.
/// - Returns `Ok(Nil)` on success (writing the new handle back to the cell), or
///   `Error(MemoryOutOfBounds)` with ZERO mutation.
///
/// **NOT the native ceiling:** delegates to `rt_mem.store`; the paged store copies one chunk into
/// a new `Mem` (rebuild cost). The real NIF would mutate in place (raw `O(1)`).
pub fn store(
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> Result(Nil, TrapReason) {
  rt_mem.store(bytes, addr, value, offset)
}

/// The current size of this process's memory, in 64 KiB pages (`memory.size`).
///
/// - Returns the page count. Total. Reads the handle from the cell.
///
/// **NOT the native ceiling:** delegates to `rt_mem.size`.
pub fn size() -> Int {
  rt_mem.size()
}

/// Grow this process's memory by `delta` pages (`memory.grow`).
///
/// - `delta`: the number of pages to add (≥ 0).
/// - Returns the PREVIOUS size in pages on success, or `-1` if the growth would exceed the
///   declared max, the Safe cap, OR the 65536-page hard cap (in which case NOTHING is allocated
///   and no fuel is charged). Newly-added pages are zero-filled. On success it charges
///   `delta * page_bytes` fuel (proportional to the bytes made addressable, P2) and writes the
///   new handle back.
///
/// **NOT the native ceiling:** delegates to `rt_mem.grow` (paged watermark move + fuel charge).
pub fn grow(delta: Int) -> Int {
  rt_mem.grow(delta)
}

/// Write an active DATA segment's `bytes` into this process's memory at `offset`, at
/// instantiation. Bounds-checked (no-wrap), whole range up front.
///
/// - `offset`: the destination byte offset.
/// - `bytes`: the raw bytes to write.
/// - Returns `Ok(Nil)` (writing the new handle back), or `Error(MemoryOutOfBounds)` if the
///   segment does not fit (an instantiation-time trap; nothing is written).
///
/// **NOT the native ceiling:** delegates to `rt_mem.init_data`.
pub fn init_data(offset: Int, bytes: BitArray) -> Result(Nil, TrapReason) {
  rt_mem.init_data(offset, bytes)
}

// ───────────────────────────── the threaded family (state_strategy: Threaded) ─────────────────────────────
//
// The purely-functional twin of the cell-backed family: generated code under `state_strategy:
// Threaded` threads the `rt_state.InstanceState` record as a value. These heads are identical to
// paged/atomics; each body re-exports `rt_mem`'s threaded wrapper. Reads leave `st` untouched;
// mutators return the rebound record (§10). Under the shipped skeleton the handle is the immutable
// paged `Mem`, so `t_store` returns a NEW handle; under the deferred native NIF the handle is a
// mutable resource, so `t_store` mutates in place and returns the SAME handle — the SIGNATURE is
// identical either way, which is exactly why the native impl needs no seam change.

/// Threaded load (read-only): projects `st.mem`, drives the load, leaves `st` UNCHANGED. Returns
/// `Ok(bits)` or `Error(MemoryOutOfBounds)`. See `load` for the codec / bounds contract.
///
/// **NOT the native ceiling:** delegates to `rt_mem.t_load`.
pub fn t_load(
  st: InstanceState,
  bytes: Int,
  signed: Bool,
  result_width: Int,
  addr: Int,
  offset: Int,
) -> Result(Int, TrapReason) {
  rt_mem.t_load(st, bytes, signed, result_width, addr, offset)
}

/// Threaded store. Bounds-checks first (trap-before-write), then returns `Ok(st')` — the §10
/// rebound record whose `mem` is the new handle — or `Error(MemoryOutOfBounds)` with `st`
/// untouched (zero mutation). See `store`.
///
/// **NOT the native ceiling:** delegates to `rt_mem.t_store`; the skeleton's paged `Mem` is
/// immutable, so the returned `mem` differs (a NEW handle). The real NIF mutates in place and
/// returns the SAME handle — same signature.
pub fn t_store(
  st: InstanceState,
  bytes: Int,
  addr: Int,
  value: Int,
  offset: Int,
) -> Result(InstanceState, TrapReason) {
  rt_mem.t_store(st, bytes, addr, value, offset)
}

/// Threaded `memory.size` (read-only): the page count of `st.mem`; `st` unchanged.
///
/// **NOT the native ceiling:** delegates to `rt_mem.t_size`.
pub fn t_size(st: InstanceState) -> Int {
  rt_mem.t_size(st)
}

/// Threaded `memory.grow`. Returns `#(prev_pages, st')` where `st'` rebinds `st.mem` to the grown
/// handle, or `#(-1, st)` past the max / cap (unchanged, nothing allocated). Charges
/// `delta * page_bytes` grow fuel on the SUCCESS path (P2 — parity with paged/atomics, so
/// metered+threaded is byte-identical to metered+cell and an untrusted module cannot allocate to
/// the page cap with zero CPU accounting). See `grow`.
///
/// **NOT the native ceiling:** delegates to `rt_mem.t_grow` (the fuel charge is inherited from the
/// delegated paged wrapper).
pub fn t_grow(st: InstanceState, delta: Int) -> #(Int, InstanceState) {
  rt_mem.t_grow(st, delta)
}

/// Threaded active-data-segment write at instantiation. Bounds-checks the whole range up front,
/// then returns `Ok(st')` (rebinding `st.mem`), or `Error(MemoryOutOfBounds)` (nothing written,
/// `st` untouched). See `init_data`.
///
/// **NOT the native ceiling:** delegates to `rt_mem.t_init_data`.
pub fn t_init_data(
  st: InstanceState,
  offset: Int,
  bytes: BitArray,
) -> Result(InstanceState, TrapReason) {
  rt_mem.t_init_data(st, offset, bytes)
}

// ───────────────────────────── the differential hook (§D/§11) ─────────────────────────────

/// The tier's whole in-bounds byte image (absent regions rendered as zero) — the differential
/// reference the oracle compares byte-for-byte after each op, mirrored on `rt_mem.to_flat` /
/// `o_flat`.
///
/// - `mem`: the opaque cell / threaded-record memory handle (a `Dynamic`).
/// - Returns the flat `byte_len`-length byte image. O(byte_len); tests only.
///
/// **NOT the native ceiling:** delegates to `rt_mem.to_flat`, which coerces the `Dynamic` to a
/// paged `Mem`. The identical byte-image comparison is the exact check that would catch a C
/// bounds / endianness bug in the deferred native impl before it could escape (§D).
pub fn to_flat(mem: Dynamic) -> BitArray {
  rt_mem.to_flat(mem)
}
