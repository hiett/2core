# Unit 04 — `rt_mem_atomics`: tier-O `atomics` linear memory (the O(1) lever)

> **One owner · Wave A · the shipped performance lever (G2).** Freeze deps:
> `«MEM-TIER-FROZEN»` (unit 01) publishes `MemTier { Paged Atomics Nif }`, the
> `Atomics → "twocore@runtime@rt_mem_atomics"` module mapping, and the **uniform `rt_mem`
> backend interface** (§B.2) + the **differential-oracle** contract (§B.3) every tier binds to.
> Read [`00-overview.md`](00-overview.md) (G1–G8) and [`01-interface-freeze.md`](01-interface-freeze.md)
> (§B) first, then the Phase-2 analog [`../phase-2/04-rt-mem.md`](../phase-2/04-rt-mem.md).
> Phase-1 D1–D10 / Phase-2 E1–E8 / Phase-3 F1–F8 all still hold.

---

## Context

Phase 3's honest benchmark measured the tier-P **`paged`** memory model — an immutable, sparse
binary rebuilt on every store — as the dominant cost: a memory-heavy kernel ran **~76× slower**
than hand-written Erlang (overview §0). This unit builds the **tier-O `atomics`** backend that
closes that gap: **O(1)** `load`/`store`/`grow` over a fixed array of 64-bit Erlang `atomics`
words backing a byte-addressable linear memory. `atomics` is **ERTS-native** (no custom C, tier-O)
so it **cannot crash the node** and Safe permits it (G6: tier P or O, never N). It is
**process-local, never shared** — the atomic barrier is the only cost and cross-process sharing is
never enabled (G8, the threads/shared-memory hard non-goal, high-level §12).

Correctness is non-negotiable and identical to `paged`: **little-endian**, **no-wrap effective
address → trap** on every access (E3), all-or-nothing multi-byte stores, the Safe max-pages cap —
held **byte-for-byte to the `rebuild` oracle** (§B.3), so a bounds bug's worst case is a
wrong/missing trap or a node-safe process crash, **never a host escape** (G6).

### Reconciliation of two grounding notes (read before building)

- **The mandate's "existing `o_*` tier-O scaffolding" is a mischaracterisation** — correcting it
  exactly as keystone §B.3 does. `rt_mem`'s `o_fresh`/`o_load`/`o_store`/`o_grow`/`o_init_data`/
  `o_size`/`o_flat` family (over `OMem`) is the **flat-binary `rebuild` ORACLE** (E4), *not* a
  tier-O backend. **No `atomics` code exists yet.** This unit builds it from scratch, and reuses
  the `o_*` oracle as its differential reference.
- **Separate module for the `atomics` backend; owner-additive wrappers in `rt_mem`** (keystone
  §B.1, superseding the overview §4 "`rt_mem.gleam (extend)`" shorthand). A link-time module swap
  (B2) needs a distinct atom, so the tier-O `atomics` backend is a **NEW** file
  `src/twocore/runtime/rt_mem_atomics.gleam` (Erlang module `twocore@runtime@rt_mem_atomics`), the
  atom the `Atomics` tier resolves to; it **imports** `rt_mem` only to reuse the frozen LE codec
  constants (`page_bytes`/`hard_max_pages`) and never edits the pure paged core. Separately — and
  consistent with D1 (one owner per file, resolved additively) — this unit is the **owner-additive**
  author of the **paged threaded wrappers** in the existing `rt_mem.gleam` (`t_load`/`t_store`/
  `t_size`/`t_grow`/`t_init_data` + `to_flat(mem: Dynamic)` + the public `Dynamic → Mem` coercion):
  P2-04 owns the frozen pure `mem_*`/`o_*` core, unit 04 owns these new threaded functions.

## Files owned

- `src/twocore/runtime/rt_mem_atomics.gleam` — **NEW.** The tier-O backend: the opaque `Atomics`
  handle, the pure `a_*` core, the frozen cell-backed + threaded wrappers, `to_flat`.
- `src/twocore/runtime/rt_mem.gleam` — **EXTEND (owner-additive).** This unit owns — additive to
  P2-04's frozen file — the **paged threaded wrappers** `state_strategy: Threaded` calls:
  `t_load`/`t_store`/`t_size`/`t_grow`/`t_init_data`, plus `to_flat(mem: Dynamic) -> BitArray` and
  the public `Dynamic → rt_mem.Mem` coercion they need (the field seam is unit 03's `rt_state.mem`/
  `with_mem`). The paged `t_grow` **charges grow fuel on success** (§C Fuel). The frozen pure
  `mem_*`/`o_*` core and the LE codec stay P2-04's — untouched.
- `src/twocore_rt_mem_atomics_ffi.erl` — **NEW.** A thin `twocore_`-namespaced shim over the
  `atomics` BIFs (`new`/`get`/`put`), mirroring `twocore_rt_state_ffi`.
- `test/twocore/runtime/rt_mem_atomics_test.gleam` — **NEW.** The spec-corner suite + the
  differential (`atomics ≡ oracle ≡ paged`) over bounded memories that engage `AtomicsBacked`, plus
  the fail-closed link-time rejection of an over-cap / uncapped `max`.

## Depends on

- `«MEM-TIER-FROZEN»` (unit 01): `MemTier.Atomics`, the module mapping, and the uniform interface
  (§B.2). Stub against the frozen heads until 01 lands (it is landed/green per the keystone).
- Coordinates with **unit 02/03** on the threaded seam: the `t_*` heads (§A.2) thread
  `rt_state.InstanceState` via unit 03's `rt_state.mem`/`with_mem` field seam; this unit implements
  **both** the atomics `t_*` wrappers (in `rt_mem_atomics.gleam`) **and** the paged `t_*` wrappers
  (owner-additive in `rt_mem.gleam`), so their shapes match by construction. No behavioural
  dependency on unit 02's `emit_core` seam — the pure `a_*` core is self-contained.

---

## A. Representation & byte↔word addressing (the exact contract)

### A.1 The opaque `Atomics` handle

```gleam
/// Tier-O linear memory backed by a fixed array of Erlang `atomics` 64-bit words (the O(1)
/// mutable store). Opaque: callers go through the pure core / the cell + threaded wrappers. The
/// `atomics` ref is PROCESS-LOCAL and never shared (G8). There is **no paged fallback variant**:
/// when the effective max exceeds the node-safe reserve cap (§C), the build is FAIL-CLOSED
/// REJECTED at link time — never silently pre-allocated at 4 GiB and never silently degraded to
/// `paged` (keystone §B.2 single contract). So `a_fresh` only ever constructs `AtomicsBacked`.
///
/// - `AtomicsBacked`:
///   - `ref`: the opaque `atomics` array handle (from `atomics:new/2`, `{signed, false}` →
///     unsigned 64-bit words). MUTABLE, shared by reference; a store mutates it IN PLACE.
///   - `pages`: the current logical size in 64 KiB pages — the `memory.size` source and the
///     bounds-check length (`byte_len = pages * page_bytes`). A watermark, NOT the physical size.
///   - `max`: the effective max in pages (`min(declared_max ?? safe_cap, safe_cap, 65536)`);
///     `grow` never exceeds it. Engaging `atomics` requires `max =< atomics_reserve_cap_pages`
///     (else the build is rejected — §C).
///   - `reserve`: the physical reservation in pages (`max(min_pages, max)`); `ref` holds
///     `reserve * words_per_page` zero-initialised words. `grow` is a pure watermark move within
///     `[0, max]` — the words already exist (§C).
pub opaque type Atomics {
  AtomicsBacked(ref: Dynamic, pages: Int, max: Int, reserve: Int)
}
```

Constants are **single-sourced from `rt_mem`** (never re-spelled): `rt_mem.page_bytes` (65536),
`rt_mem.hard_max_pages` (65536). New tier-O constant:

```gleam
/// Words per 64 KiB page: `page_bytes / 8 = 8192`. The physical backing of `n` pages is
/// `n * words_per_page` unsigned 64-bit `atomics` words.
pub const words_per_page: Int = 8192

/// The tier-O node-safety ceiling: the MOST pages `fresh` will eagerly reserve as `atomics`
/// words. A module whose effective max exceeds this is **FAIL-CLOSED REJECTED at link time**
/// (§C) — `atomics` requires a bounded max/cap `=<` the reserve cap; it never silently degrades
/// to `paged` and never pre-allocates past this ceiling. Eager reservation of `p` pages costs
/// `p * 64 KiB` of `atomics` backing, so an UNBOUNDED reserve is a node-OOM (node-crash) vector —
/// forbidden for a tier that "cannot crash the node" (G6). FINITE and well below the 65536-page
/// (4 GiB) i32 ceiling; a tuning knob unit 07/10 may adjust. Default: a conservative few-thousand
/// pages.
pub const atomics_reserve_cap_pages: Int = 4096
```

### A.2 Byte↔word addressing — **little-endian, exact** (E3, WASM §exec/instructions)

Memory is byte-addressable; the backing is 64-bit words. The mapping is **little-endian
throughout** (WebAssembly stores integers little-endian —
<https://webassembly.github.io/spec/core/exec/instructions.html#memory-instructions>,
<https://webassembly.github.io/spec/core/exec/numerics.html#aux-bytes>):

- Byte address `a` (0-based) → **word number** `w = a / 8`; **`atomics` index** `ix = w + 1`
  (`atomics` is **1-indexed**). **Byte position** in the word `p = a mod 8`, where **`p = 0` is
  the least-significant byte** (little-endian): a word's value is
  `Σ_{k=0..7} byte[8w+k] · 256^k`, i.e. the byte at address `a` occupies bits `[8p, 8p+8)`.
- Reading a single byte: `(get(ix) bsr (8·p)) band 0xFF`.
- A **naturally-aligned** `i64.load` at `a = 8w` (`p = 0`) is exactly `get(ix)`; an aligned
  `i32.load` is `get(ix) band 0xFFFFFFFF`. This is the O(1) fast path.

**Multi-byte access spans at most 2 words** (for `bytes ∈ {1,2,4,8}` and word size 8): a run of
`n ≤ 8` bytes starting at position `p` touches word `w` and, iff `p + n > 8`, word `w+1`.
**Alignment is only a hint** — unaligned and word-boundary-crossing accesses **must** be supported
(same as the paged chunk-span rule).

**Load (`a_load`) — gather then decode with the frozen LE codec.** Assemble the raw `n`-byte
little-endian value and apply the **identical** codec `paged`/`oracle` use (transcribed, not
re-invented — this is what makes the tiers byte-identical):
- single word (`p + n ≤ 8`): `raw = (get(w+1) bsr (8·p)) band mask(8·n)`, `mask(b) = (1 bsl b)−1`.
- two words: `lo = get(w+1) bsr (8·p)` (low `8−p` bytes); `hi = get(w+2) band mask(8·(n−(8−p)))`;
  `raw = lo bor (hi bsl (8·(8−p)))`.
- decode: `Ok(raw)` for `loadN_u`/plain/`f32`/`f64` (zero-extension is identity on the bit
  pattern); for `loadN_s` sign-extend from `n·8` bits to `result_width` bits (the two's-complement
  fold `s + pow2(result_width)` when the top bit is set) — bit-for-bit the frozen `decode_signed`.
  `result_width` disambiguates `i32.load8_s`→`0xFFFFFF80` from `i64.load8_s`→`0xFF…FF80` (E2).

**Store (`a_store`) — bounds-check FIRST, then scatter.** Encode `value`'s low `n` bytes LE
(`<<value:size(n·8)-little>>`, the frozen encoder — wraps for `store8/16/32` for free; f32/f64
reuse it over the raw IEEE bits), then write into the ≤2 touched words by **read-modify-write**:
`new_word = (old_word band (bnot (mask(8·len) bsl (8·pos)))) bor (bytes_int bsl (8·pos))`, then
`put(ix, new_word)`. The read-modify-write is a plain `get`+`put` — **no `compare_exchange`
needed** because the memory is process-local (G8), never contended; the atomic barrier is the
sole cost. f32/f64 are **raw-byte moves** — never a BEAM-double round-trip (D5), so NaN payloads /
signalling bits survive.

---

## B. The pure `a_*` core (the value-threaded, effectful algebra)

Mirror each op as a pure-signature function threading an explicit `Atomics` handle — exactly like
`rt_mem`'s `mem_*` and the oracle's `o_*`, so the differential drives all three in lockstep.
**Caveat (G2/§10):** the atomics backend is **value-threaded but effectful** — `a_store`/`a_grow` on
an `AtomicsBacked` handle mutate the shared `ref` IN PLACE and return the **same** handle (mutation
visible through it), satisfying the uniform-threading signature. The differential drives strictly
forward and never retains an old atomics snapshot as an immutable prior state (unlike `paged`, whose
superseded `Mem` is a valid past value).

```gleam
/// Build a fresh tier-O memory of `min_pages` zero pages, pre-reserving `reserve =
/// max(min_pages, eff)` pages of `atomics` words. REQUIRES `reserve =< reserve_cap` — the linker
/// (unit 07, `validate_binding`) rejects an over-cap / uncapped `atomics` binding at LINK time
/// ("atomics requires a bounded max/cap =< the reserve cap"), so `a_fresh` only ever builds
/// `AtomicsBacked`; reached with an over-cap `reserve` it FAILS CLOSED (a node-safe `panic`,
/// unreachable post-validation) — it never silently pre-allocates 4 GiB and never degrades to
/// `paged` (§C, keystone §B.2). `eff = min(declared_max ?? safe_cap, safe_cap, hard_max_pages)` —
/// the frozen effective-max formula (re-derived here; the differential proves it agrees with
/// `rt_mem`'s baked `max`).
pub fn a_fresh(min_pages: Int, max_pages: Option(Int), safe_cap: Int, reserve_cap: Int) -> Atomics

/// Pure load (same contract as `rt_mem.mem_load`): `Ok(bits)` or `Error(MemoryOutOfBounds)` iff
/// `ea + bytes > byte_len`. Read-only. `ea = addr + offset` is a BIGNUM, never masked (§D no-wrap).
pub fn a_load(a, bytes, signed, result_width, addr, offset) -> Result(Int, TrapReason)

/// Pure store. Bounds-checks the WHOLE `[ea, ea+bytes)` range FIRST (trap-before-write,
/// all-or-nothing — zero mutation on trap), then scatters into ≤2 words. Returns `Ok(a')` where
/// `a'` is the SAME `AtomicsBacked` handle (mutated in place — the `ref` is shared by reference).
pub fn a_store(a, bytes, addr, value, offset) -> Result(Atomics, TrapReason)

pub fn a_size(a) -> Int                                     // a.pages (watermark)
pub fn a_grow(a, delta) -> #(Int, Atomics)                  // #(old_pages | -1, a')  (§C)
pub fn a_init_data(a, offset, bytes) -> Result(Atomics, TrapReason)  // whole-range check, at instantiate

/// The whole in-bounds byte image (`pages * page_bytes` bytes, LE) — the differential reference
/// mirrored on `rt_mem.to_flat`/`o_flat`. Gathers the `AtomicsBacked` words word-by-word.
/// O(byte_len); tests only.
pub fn a_flat(a) -> BitArray
```

**Zero-fill invariant.** A never-written in-bounds byte reads `0` (reserved words are 0-init and
`atomics:new` zeroes them); every byte of a freshly `grow`-n page reads `0` (the words for pages
`[pages, max)` were reserved and never written — a store into them was OOB and trapped). No eager
per-page allocation is needed beyond the one-time reservation.

---

## C. `grow` — the sharp edge (pre-allocate to the effective max, or fail-closed reject)

`atomics` arrays are **fixed size at creation** — there is no resize. The frozen contract
(overview §10 / G2, keystone §B.2) is a **single** rule: pre-allocate to the effective max, or —
when that would exceed the node-safe reserve cap — **reject the build fail-closed at link time**.
There is **no silent paged fallback** and **no silent 4 GiB pre-allocation**.

1. **Pre-allocate to the effective max (the O(1) path).** `a_fresh` reserves
   `reserve = max(min_pages, eff)` pages of words up front. `a_grow(delta)` is then a pure
   watermark move:
   ```
   old = pages ; new = pages + delta
   ok  = delta >= 0  andalso  new =< max  andalso  new =< hard_max_pages
   ok  -> #(old,  AtomicsBacked(..a, pages: new))   // O(1): words already reserved & zero
   else -> #(-1,  a)                                 // unchanged; allocate NOTHING
   ```
   Return **old** pages on success, **−1** (= `0xFFFFFFFF` as i32) past `max`/`hard_max`, leaving
   memory unchanged — identical to `mem_grow`. No re-allocation, no copy: `grow` is O(1).

2. **Fail-closed link-time rejection (the node-safety gate).** If `reserve >
   atomics_reserve_cap_pages`, the `atomics` tier **cannot** node-safely pre-reserve the words, so
   the build is **rejected at link time** — unit 07's `validate_binding` fails closed with an
   explicit, reported error ("atomics requires a bounded max/cap `=<` the reserve cap"). It does
   **not** silently degrade to `paged` (that would make an `atomics` request quietly behave like a
   different, slower tier — a silent-strategy swap the reconciled contract forbids) and does **not**
   pre-allocate 4 GiB. `a_fresh` itself is a defensive fail-closed guard: reached with an over-cap
   `reserve` (unreachable post-validation) it `panic`s node-safe rather than reserving. The tradeoff
   is honest (G8): the `atomics` O(1) win engages only for **dense, bounded** memories; an
   unbounded/large-max module either lowers its cap (`safe_capped(small)` / a bounded declared max)
   or stays on the `paged` tier **explicitly** (a different `mem_tier`, chosen by the profile).

**The Safe max-pages cap interaction (E3).** `eff` folds in `safe_cap` (= `binding.safe_max_pages`,
baked by `emit_core` into the `fresh(min, max, safe_cap)` seed): a Safe `atomics` build engages the
O(1) path exactly when the memory is **bounded within the reserve ceiling** — via a bounded declared
max, or via `safe_capped(small)` lowering `safe_cap`. Under the generous default cap
(`safe_max_pages() = 65536`) a `max_pages: None` memory has `eff = 65536` (4 GiB) → it exceeds
`atomics_reserve_cap_pages` and the `atomics` build is **fail-closed rejected** (not degraded). The
`ceiling`/atomics profiles (unit 07) and the benchmark (unit 10) therefore **supply a bounded cap**
so `atomics` actually engages. `grow` past the cap still returns **−1**, so the Safe resource bound
holds within an engaged atomics memory.

**Rejected alternative — re-allocate on `grow`.** Growing by allocating a bigger `atomics` and
copying the old words is O(current) per grow → an O(n²) grow-loop, and it swaps the `ref` (churning
the threaded handle every store-adjacent grow). The frozen §10 names pre-allocate-or-reject, not
re-alloc; we follow it.

**Fuel.** Both the cell-backed `grow` wrapper **and** the threaded `t_grow` charge
`rt_meter.charge(delta * page_bytes)` on the **success** path (`result != -1`) — a big grow is not
O(1)-cheap for the *scheduler* (E3), and this is the ONE runtime-side dynamic fuel charge (grow fuel
is per-actual-delta, so it cannot be a static IR `Charge` node). Charging it on **both** strategies
keeps metered+threaded **byte-identical** to metered+cell (the G7 trap bar) and closes a
resource-bound hole (an untrusted portable module allocating to the page cap with zero CPU
accounting). The pure `a_grow` stays charge-free (testable); the charge lives in the wrapper.

---

## D. The frozen wrappers — cell-backed + threaded (bind to §B.2 / §A.2)

Every `rt_mem` tier exposes the **same public heads** so the `emit_core` seam calls any tier
identically (a module swap, G5); the `state_strategy` picks the *function family* (§A.3). The
wrappers are thin: fetch the handle, call the pure core, persist iff the handle **changed**.

**Cell-backed family** (for `state_strategy: Cell`; frozen Phase-2 heads, byte-identical to paged):

```gleam
pub fn fresh(min_pages: Int, max_pages: Option(Int), safe_cap: Int) -> Dynamic   // a_fresh(.., default reserve) → Dynamic
pub fn load(bytes, signed, result_width, addr, offset) -> Result(Int, TrapReason) // read-only; no write-back
pub fn store(bytes, addr, value, offset) -> Result(Nil, TrapReason)               // §note
pub fn size() -> Int
pub fn grow(delta: Int) -> Int                                                     // charges fuel; writes back the new watermark
pub fn init_data(offset: Int, bytes: BitArray) -> Result(Nil, TrapReason)
```

`store`/`grow`/`init_data` read the handle via `rt_state.mem_get` and **persist via
`rt_state.mem_put` iff the returned handle differs**. The **O(1) constant-factor win over paged**:
an `AtomicsBacked` `store` mutates the shared `ref` in place, so the handle value is unchanged and
**no `mem_put` is emitted** — the pdict write-back paged pays on *every* store is elided. Only
`grow` (which moves the `pages` watermark held in the Gleam record) writes back. Fail-closed (E3):
an un-seeded cell propagates `rt_state.mem_get`'s
`panic` — never a fabricated zero memory. `rt_mem_atomics` **never** calls `rt_trap`; `emit_core`
does the `{ok,_}`/`{error,R}` case + raise (the seam).

**Threaded family** (for `state_strategy: Threaded`; §A.2 heads — thread `rt_state.InstanceState`):

```gleam
pub fn t_load(st, bytes, signed, result_width, addr, offset) -> Result(Int, TrapReason)  // read-only: st unchanged
pub fn t_store(st, bytes, addr, value, offset) -> Result(InstanceState, TrapReason)       // same st (ref mutated in place)
pub fn t_size(st) -> Int
pub fn t_grow(st, delta) -> #(Int, InstanceState)                                          // prev pages + rebound record; charges grow fuel on success (§C)
pub fn t_init_data(st, offset, bytes) -> Result(InstanceState, TrapReason)
```

Each projects `st.mem` (coerce `Dynamic → Atomics`), calls the pure `a_*`, and injects the result
back. Per §A.2/§10 the mutable backend's `t_store` returns the **same** `st` (the `ref` mutated in
place — the mem `Dynamic` is unchanged); `t_grow` rebinds `st.mem` to the new watermark record **and
charges grow fuel on success** (§C — parity with the cell `grow`, so metered+threaded ==
metered+cell). One signature serves the immutable (`paged`) and mutable (`atomics`) backends alike.

**Differential hook** (§B.2): `to_flat(mem: Dynamic) -> BitArray` — coerce then `a_flat`, the
tier's whole in-bounds byte image for the oracle to compare byte-for-byte.

### FFI shim

```erlang
%% twocore_rt_mem_atomics_ffi — thin, twocore_-namespaced shim over the atomics BIFs (tier-O:
%% ERTS-native, no NIF, process-local, cannot crash the node). Mirrors twocore_rt_state_ffi.
-module(twocore_rt_mem_atomics_ffi).
-export([new/1, get/2, put/3]).
new(Arity) -> atomics:new(Arity, [{signed, false}]).  %% unsigned 64-bit words (0..2^64-1)
get(Ref, Ix) -> atomics:get(Ref, Ix).                 %% 1-indexed
put(Ref, Ix, Val) -> atomics:put(Ref, Ix, Val).
```

Bound via `@external(erlang, "twocore_rt_mem_atomics_ffi", "new"/"get"/"put")`. Using `{signed,
false}` gives clean 0..2⁶⁴−1 words for byte packing. An out-of-range index raises catchable
`badarg` (node-safe) — but we bounds-check `ea` before deriving any index, so a bad index is
unreachable on the happy path (defense-in-depth: even a bounds bug cannot read outside the array).

---

## E. Differential — held byte-for-byte to the `rebuild` oracle (§B.3, E4)

The `o_*` oracle (in `rt_mem`) is the trivially-correct reference (one flat binary, store rebuilds
the whole thing). This unit's `rt_mem_atomics_test.gleam` drives one shared op trace
(`a_fresh`; a randomized sequence of in-bounds/out-of-bounds `load`/`store`/`grow`/`init_data` with
random widths, signedness, addresses, **aligned and word-boundary-crossing**) through `a_*`, the
paged `mem_*`, **and** `o_*` in lockstep, asserting after each op: **identical returned value,
identical trap (`Ok`/`Error(reason)`), and identical byte image** (`a_flat(a) == rt_mem.to_flat(m)
== o_flat(o)`). It runs across **bounded** memories that **engage `AtomicsBacked`** (`eff ≤
reserve_cap`); a separate case asserts that an **over-cap / uncapped** memory (`eff > reserve_cap`,
e.g. `max_pages: None`) is **fail-closed rejected** at link time — never silently degraded (§C).
Unit 09 lifts the differential to every `(state_strategy, mem_tier)` combination; the oracle itself
is held to spec-corner tests (below), so a shared bug cannot hide.

---

## Effect / soundness / security note

- **Tier-O, cannot crash the node (G6).** `atomics` is ERTS-native (no custom C, unlike tier-N
  `nif`); memory-safe by construction. A bounds bug's worst case is a wrong/missing trap or a
  node-safe process crash (a stray `atomics:get` raises catchable `badarg`), **never** a host
  out-of-bounds read. Bounds-checks hold in every access (the §11 security invariant).
- **Node-safety of reservation.** Eager `atomics:new` is **bounded** by `atomics_reserve_cap_pages`
  (§C); above it, the build is **fail-closed rejected** at link time (never a silent `paged`
  degrade, never a 4 GiB pre-alloc). An unbounded reserve would be a node-OOM vector — the
  fail-closed rejection is a **security mechanism**, not just a perf nicety.
- **Process-local, never shared (G8, high-level §12).** The `ref` lives in one process's cell /
  threaded record and is never sent to another process; no cross-process sharing is enabled. The
  atomic barrier is the only cost. Threads / shared memory stay a hard non-goal.
- **No ambient authority (D3a).** The seam emits a fixed
  `call 'twocore@runtime@rt_mem_atomics':'store'(...)` — a build-controlled module atom, literal fn
  name. The tier is a link-time module swap the linker resolves (G5); `emit_core` reads only
  `binding.mem_module`. **Fail-closed (D4):** an un-seeded cell propagates `rt_state`'s panic;
  `atomics` is Safe-permitted (tier O), so no `Safe + atomics` rejection exists (tier-N-only, unit 07).
- **Floats-as-bits (D5).** f32/f64 store/load are raw-byte moves over the IEEE bit pattern — never a
  BEAM-double round-trip; NaN payloads survive. **Conformance-neutral (G7):** no IR node, no
  `TrapReason`, no grammar change; an `atomics` build is byte-identical to `paged`.

---

## Verification (Definition of Done)

Tests assert **WebAssembly semantics** (and the oracle), never "whatever the atomics impl emits" —
no change-detectors (D8). Spec-cited.

1. **Differential `atomics ≡ oracle ≡ paged`** over randomized op streams (E4, §E) on **bounded**
   memories that engage `AtomicsBacked`; identical values, traps, and final flat byte image. A
   separate case asserts an **over-cap / uncapped** binding (`eff > reserve_cap`) is **fail-closed
   rejected** at link time — no silent `paged` degrade, no 4 GiB pre-alloc (§C).
2. **Spec-corner tests on the `a_*` core** — the same anchors the paged unit owns
   (`memory_trap`/`address`/`endianness`/`float_memory`/`memory_size`/`memory_redundancy` `.wast`),
   at minimum:
   - **LE layout** — store `0x04030201` i32 → bytes `01 02 03 04` at +0..+3; `i32.load8_u`@+0 =
     `0x01`; aligned `i32.load`@0 = `0x04030201` (endianness/address).
   - **Word-boundary-crossing access** — an unaligned i64 store/load at `p ≠ 0` spanning two words
     round-trips identically to the aligned case (the atomics-specific risk).
   - **Sign vs zero extend × width** — byte `0x80`/`0xFF` → `load8_s`→`0xFFFFFF80`(i32)/`…80`(i64),
     `load8_u`→`0x80`; `result_width` disambiguates.
   - **Zero-fill** — a never-written in-bounds byte and every byte of a freshly `grow`-n page read
     `0`; **no-wrap ea** — `addr = 0xFFFFFFFF` + large `offset` traps (does **not** wrap to
     in-bounds) (memory/memory_trap/address).
   - **Exact-length off-by-one** — an access ending exactly at `byte_len` succeeds, one byte past
     traps; a multi-byte store straddling `byte_len` traps with **ZERO** mutation (re-read the
     in-bounds prefix — unchanged).
   - **`grow`** — returns OLD pages, then **−1** past the declared max **and** the 65536 cap,
     allocating nothing; `size` reflects only successful grows (memory_size).
   - **f32/f64 NaN round-trip** preserves NaN bits (no double round-trip — float_memory);
     **`init_data`** OOB traps (instantiation abort), writes exact bytes in-bounds; **redundant load
     after store** returns the stored value (memory_redundancy).
   - Spec refs: <https://webassembly.github.io/spec/core/exec/instructions.html>,
     <https://webassembly.github.io/spec/core/exec/modules.html>,
     <https://webassembly.github.io/spec/core/syntax/values.html>.
3. **Wrapper tests.** Cell-backed: seed → op → persistence; `AtomicsBacked` `store` mutates in place
   with **no `mem_put`**, `grow` writes back the watermark **+ charges fuel**; two seeds never
   bleed. Threaded: `t_store` returns the **same** `InstanceState` (in-place), `t_grow` a
   **rebound** record **and charges the same grow fuel as the cell `grow`** (assert a metered
   threaded grow and a metered cell grow debit an identical fuel amount — the P2 metered-parity
   bar). An over-cap / uncapped binding is rejected before any wrapper runs (§C).
4. **Constant-space store loop.** A ~100k-iteration store loop over the cell/threaded API holds
   bounded process memory (`atomics` mutation is in place; no per-store garbage).
5. `gleam format --check src test` clean; `gleam build` with **ZERO warnings** (every public fn
   total — no `todo`/`panic`/`let assert` on untrusted paths; the coercions are sole-producer-sound
   like `rt_mem`'s); `gleam test` green (≥ current count); conformance `fail=0` under an `atomics`
   binding (byte-identical to paged); every public fn/type carries a `///` contract doc.

**Done = the `rt_mem_atomics` suite passes** (the differential + every spec-corner on `a_*` + the
wrapper/constant-space tests), not "it compiles."

---

## What this unit leaves

- **Unit 05** builds `rt_mem_nif` (tier-N, Unsafe-only) against the same §B.2 interface — the
  ceiling; its `atomics`-vs-`nif` distinction is exactly tier-O (this unit) vs tier-N.
- **Unit 07** maps `Atomics → "twocore@runtime@rt_mem_atomics"`, composes the `ceiling` profile
  (Unsafe + `Atomics` + `Cell`), and owns the **link-time fail-closed rejection** of an over-cap /
  uncapped `atomics` binding (`validate_binding`: "atomics requires a bounded max/cap =< the reserve
  cap", §C); Safe-forbids-nif does **not** touch `atomics` (tier-O is Safe-permitted); it may tune
  `atomics_reserve_cap_pages`.
- **Unit 08** selects `mem_tier: Atomics` per profile / CLI and threads the record through the
  run-ABI (the `t_*` path). **Unit 09** runs the differential across every `(state_strategy ×
  mem_tier)` combination + the constant-space-under-threaded proof (G4). **Unit 10** re-measures the
  honest benchmark with `atomics` engaged (bounded memory) vs `paged` / hand-written / native — the
  G2 claim, **measured** not asserted.
