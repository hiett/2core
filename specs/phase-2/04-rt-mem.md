# Unit 04 — `rt_mem`: paged linear memory + the rebuild oracle

> **One owner · Wave A · the biggest runtime unit.** Freeze deps: `«CELL-STATE-ABI-FROZEN»`
> (P2-01 publishes the `rt_mem` stub signatures + the `mem_module` Binding field on day 1).
> Coordinates with **unit 03** (`rt_state`) for the opaque `mem` field of the per-instance
> cell. Read [`00-overview.md`](00-overview.md) (E1–E8) and
> [`01-interface-freeze.md`](01-interface-freeze.md) (the cell ABI + the frozen `rt_mem`
> heads) first. Phase-1 D1–D10 still hold.

---

## Context

Phase 1 generated **pure** code — no mutable instance state. Linear memory is the first and
largest piece of mutable state Phase 2 introduces (E1). `rt_mem` is **the** canonical
memory layer: a mutable, growable, byte-addressable WASM linear memory realised on the BEAM
as an **immutable, sparse, paged binary structure**. It is **tier-O/P**: it cannot crash the
node, cannot be coerced into an out-of-bounds *host* read (a BEAM binary is bounds-safe by
construction), and a bounds-check bug's worst case is a wrong/missing trap or a node-safe
process crash — never a host escape (E3). It is reached only through the binding chokepoint
(`mem_module`), so D3a (no ambient authority) holds.

The memory value itself is **immutable**; mutation is "swap the current immutable `Mem` in a
per-instance cell" (E1, the `cell` strategy). `rt_mem` owns the *page-map value shape*; that
shape is **opaque** to `rt_state`, which owns the cell. The two stay parallel.

## Goal

Implement, against the spec, every linear-memory primitive: little-endian width-matrix
`load`/`store`, `memory.size`/`memory.grow`, instantiation-time active-data writes — all
**no-wrap bounds-checked → trap**, all-or-nothing on multi-byte stores, with a hard
max-pages cap so untrusted code cannot allocate unboundedly (E3). Ship a second, trivially-
correct **flat-binary rebuild oracle** as the differential reference (E4), and hold **both**
the paged impl *and* the oracle to explicit spec-corner tests so a shared bug cannot hide.

## Files owned

- `src/twocore/runtime/rt_mem.gleam` — **NEW.** P2-01 publishes it day-1 as a stub (the 5
  frozen public heads, `todo` bodies). Unit 04 fills the bodies, adds the pure paged core,
  the oracle, and `fresh`.
- `test/twocore/runtime/rt_mem_test.gleam` — **NEW.** The differential suite + the spec-corner
  tests on both impls.

## Depends on

- `«CELL-STATE-ABI-FROZEN»` (P2-01): the frozen `rt_mem` public signatures and the
  `mem_module` field on `Binding`/`safe_default`. **Stub against the heads in
  [`01-interface-freeze.md`](01-interface-freeze.md) §B** until 01 lands.
- **Unit 03 (`rt_state`)** for the *cell seam*: per E1 the per-instance state is one fixed
  namespaced pdict key holding an opaque `{mem, globals, table}`. `rt_mem`'s public ops must
  read/write the `mem` slot of that single cell. **Coordinate two thin accessors** (see
  "Grounded facts → cell seam"); until 03 publishes them, develop the **pure paged core**
  (which threads an explicit `Mem`) and the oracle — neither touches the cell, so you are not
  blocked. The pdict wrappers are a thin shell added last.

## Scope — in / out for Phase 2

**In:** one funcref-free linear memory (MVP allows exactly one memory, index 0); the full
load/store width matrix; `memory.size`/`memory.grow` with the Safe max-pages cap + the
65536-page i32 cap + proportional fuel; active-data-segment init (`init_data`); the rebuild
oracle; the differential + spec-corner suites; reserving the memory `.wast` files as this
unit's spec anchor.

**Out (cite the E-decisions):** atomics / NIF page-map tiers — **Phase 3** (E8; Safe forbids
tier N anyway). Bulk memory `memory.fill`/`copy`/`init` + `data.drop` + passive segments
(data form `0x01`) + the `DataCount` section — **Phase 3** (E7/E8); decode-reject, do not
half-implement. Multi-memory — **Phase 3**. The tier-P `threaded` state build — **Phase 3**
(E1); `rt_mem`'s op *signatures* honour the uniform-threading rule so the future switch is an
`emit_core` change, not an `rt_mem` rewrite. Decoding the memory section / opcodes (unit 07),
typing + memarg-alignment validation (unit 08), lowering (unit 09), the `MemLoad`/`MemStore`/
`MemSize`/`MemGrow` emit arms + the `instantiate` entry (unit 10), and the run-ABI/harness
(unit 11) are **not** yours.

---

## Deliverables

### The `Mem` value (immutable, sparse, paged)

```gleam
/// Immutable paged linear memory. Mutation = build a new `Mem`; the cell holds the latest.
pub opaque type Mem {
  Mem(
    pages: Int,                  // current size in 64KiB WASM pages (the memory.size source)
    max: Int,                    // EFFECTIVE max in pages: min(declared_max | safe_cap, 65536)
    chunk: Int,                  // physical chunk size in bytes (perf knob; default 4096; >64)
    data: dict.Dict(Int, BitArray),  // SPARSE: chunk_idx -> chunk-sized binary; ABSENT = all-zero
  )
}
```

- `byte_len = pages * 65536`. The WASM **page** (65536 B) is the grow/size unit; the physical
  **chunk** is the binary-granularity knob, **decoupled** from the page. An *absent* chunk
  means all-zero and costs nothing — so a freshly-grown, never-written region reads as 0 with
  no allocation, and `grow` is O(1) in allocation.
- Keep `chunk > 64` so chunks are **off-heap REFC binaries** (shared by reference across `Mem`
  versions / GC); a `<= 64`-byte chunk is a heap binary copied on every GC and message send,
  defeating structural sharing. Default `chunk = 4096` (4–8 KiB is the sweet spot).

### Public API (the frozen `«CELL-STATE-ABI-FROZEN»` heads — cell-backed)

Each is a thin wrapper: fetch the `Mem` from the cell, call the pure core, write back. They
return a `Result`/bare value; **`rt_mem` never calls `rt_trap`** — `emit_core` does the
`{ok,_}`/`{error,R}` `case` + raise (the seam in 01 §B).

```gleam
/// Load `bytes` (1/2/4/8) little-endian at ea = addr(unsigned i32) + offset.
/// `signed`: sign-extend (loadN_s) vs zero-extend (loadN_u / plain / f32 / f64).
/// `result_width`: the operand width in bits (32 or 64) the result is normalised to.
/// Ok(bit_pattern) | Error(MemoryOutOfBounds) iff ea + bytes > byte_len.
pub fn load(bytes: Int, signed: Bool, result_width: Int, addr: Int, offset: Int)
  -> Result(Int, TrapReason)
/// Store the low `bytes` of `value`, little-endian, at ea. Traps BEFORE any byte is written.
pub fn store(bytes: Int, addr: Int, value: Int, offset: Int) -> Result(Nil, TrapReason)
pub fn size() -> Int                       // current pages
pub fn grow(delta: Int) -> Int             // OLD pages on success, or -1 (no allocation) past a cap
pub fn init_data(offset: Int, bytes: BitArray) -> Result(Nil, TrapReason)  // active segment, at instantiate
```

### The pure paged core (the testable algebra — develop this first)

Mirror each public op as a pure function threading an explicit `Mem` (no cell, no fuel). The
public wrappers are a thin shell over these; the **differential + spec tests drive these
directly**, so correctness is provable without the pdict.

```gleam
pub fn fresh(decl: MemoryDecl, safe_cap: Int) -> Mem  // pages=decl.min_pages, max=effective cap, zeroed
fn mem_load(m, bytes, signed, result_width, addr, offset) -> Result(Int, TrapReason)
fn mem_store(m, bytes, addr, value, offset) -> Result(Mem, TrapReason)
fn mem_size(m) -> Int
fn mem_grow(m, delta) -> #(Int, Mem)        // #(old_pages | -1, new_mem) — pure; NO fuel charge here
fn mem_init_data(m, offset, bytes) -> Result(Mem, TrapReason)
```

`fresh` is what `rt_state.seed` (unit 03) calls to seed the `mem` slot; it stores the
**effective** max = `min(declared_max | safe_cap, 65536)`. (`safe_cap` is the Safe profile's
finite default-when-`None` — unit 11 owns the *number*; `rt_mem` enforces whatever it is seeded
with plus the absolute 65536. `rt_mem` may also expose a conservative `default_max_pages`
constant.)

### The rebuild oracle (E4 — the differential reference)

A second, trivially-correct impl used **only in tests**: memory is **one flat binary** of
length `pages*65536`, store rebuilds the whole binary copy-on-write.

```gleam
pub opaque type OMem { OMem(pages: Int, max: Int, data: BitArray) }
pub fn o_fresh(decl, safe_cap) -> OMem            // data = <<0:(min_pages*65536*8)>>
pub fn o_load(o, bytes, signed, result_width, addr, offset) -> Result(Int, TrapReason)
pub fn o_store(o, bytes, addr, value, offset) -> Result(OMem, TrapReason)   // rebuild whole binary
pub fn o_grow(o, delta) -> #(Int, OMem)           // append delta*65536 zero bytes
pub fn o_init_data(o, offset, bytes) -> Result(OMem, TrapReason)
pub fn o_size(o) -> Int
```

`o_store`: bounds-check, then `<<Pre:ea/binary, _:bytes/binary, Post/binary>> = data`;
`data2 = <<Pre/binary, NewBytes/binary, Post/binary>>` — O(total) per store, slow but
unmistakable. Provide `to_flat(m: Mem) -> BitArray` (canonicalise the paged `Mem` to a single
`byte_len`-length binary) so the differential test can compare final byte images.

---

## Grounded facts you MUST honor

> Verified against the WebAssembly spec (binary/exec instructions, exec/modules) and the BEAM
> binary-handling docs. Transcribe these exactly.

**Page size & caps.** Page = **65536** bytes, fixed. `memory.size` = `floor(byte_len/65536)` =
`pages`. A 32-bit-indexed memory cannot exceed **2¹⁶ = 65536 pages = 4 GiB** — the hard
address cap regardless of declared max. Validation requires `min <= max <= 65536`.

**No-wrap effective address (the classic OOB-corruption escape — E3).**
`ea = addr + offset`, where `addr` is the i32 operand treated **unsigned** (0..2³²−1) and
`offset` is the static u32. `ea` is a **33-bit value computed as a BEAM bignum and NEVER
reduced mod 2³²**. Trap condition: **`ea + bytes > byte_len`** (strictly greater; `byte_len =
pages*65536`, the *current*/possibly-grown length). An access that ends *exactly* at
`byte_len` is in-bounds. **PITFALL: do NOT `band` ea to 32 bits** — wrapping turns an OOB
access into an in-bounds one and bypasses the check (phantom page / corruption). The
bounds-check is the security boundary and **must precede any chunk read/write**.

**Little-endian codec (bit-syntax one-liners).**
- Encode `bytes`-byte LE (also wraps to N bits — handles `store8/16/32`):
  `<<value:(bytes*8)/little>>`.
- Decode unsigned (zero-extend / plain / f32 / f64): `<<u:(bytes*8)/little-unsigned>> = b`,
  return `u` (already the correct bit pattern; zero-extension is identity).
- Decode signed (`loadN_s`): `<<s:(bytes*8)/little-signed>> = b` → a possibly-negative Int →
  re-normalise to the operand width's **unsigned two's-complement bit pattern**:
  `s` if `s >= 0` else `s + pow2(result_width)`, i.e. `band(s, pow2(result_width)-1)`. A raw
  negative Int must **never** escape into the value layer (the value layer stores unsigned bit
  patterns — see `rt_num`). Example: `i32.load8_s` of byte `0xFF` → s = −1 → `0xFFFFFFFF`;
  `i64.load8_s` of `0xFF` → `0xFFFFFFFFFFFFFFFF`. This is exactly why the load carries
  `result_width` (E2): `i32.load8_s` and `i64.load8_s` have the same bytes+sign but different
  result bits.

**f32/f64 are raw-byte moves — NO float decode.** `rt_num` stores floats as their raw IEEE
bit pattern in an Int, so `f32.load`/`f64.load` use the **unsigned** path (the loaded integer
*is* the bit pattern); `f32.store`/`f64.store` write the value's low 4/8 bytes LE. **PITFALL:**
never round-trip through a BEAM double — it destroys NaN payloads / signaling bits and can
raise `badarith`. Memory is oblivious to float-ness; it just moves bytes.

**Width handling.** `storeN` writes only the low N bits (the `/little` encode wraps for free);
`loadN_s` sign-extends and `loadN_u` zero-extends to the full operand width. Access widths:
`bytes ∈ {1,2,4,8}`; the matrix is i32/i64.load{,8_s,8_u,16_s,16_u}, i64.load32_{s,u},
f32/f64.load, and the matching stores (store8/16/32).

**`memory.grow(delta)`** (return OLD size, or −1; zero-fill; bounded):
```
old = pages ;  new = pages + delta
ok  = delta >= 0  andalso  new =< max  andalso  new =< 65536
if ok  -> #(old,  Mem{ pages: new })        // O(1): absent chunks already read as zero
else   -> #(-1,   Mem unchanged)            // -1 = 0xFFFFFFFF as i32; allocate NOTHING
```
**PITFALLS:** return the **old** size (not 0/1) on success; return **−1** (not 0) on failure
and leave memory **unchanged**; enforce **both** the declared/effective `max` **and** the
65536 absolute cap; grown pages must read as **zero** (the sparse default-zero map gives this
free — do **not** eagerly allocate zero chunks). The public `grow` wrapper charges fuel
**proportional to allocated bytes** — `rt_meter.charge(delta * 65536)` on the success path
only (E3: a big grow cannot be O(1)-cheap, else it is a resource-exhaustion escape). Keep the
pure `mem_grow` free of the charge so it stays testable.

**Chunked read/write (handle the boundary span — alignment is only a hint).** For range
`[ea, ea+bytes)` with `cs = chunk`: `first = ea/cs`, `last = (ea+bytes-1)/cs`.
- `first == last` (in one chunk): `o = ea rem cs`; `c = get_chunk(m, first)`.
  read: `<<_:o/binary, slice:bytes/binary, _/binary>> = c` (zero-copy sub-binary).
  write: `<<pre:o/binary, _:bytes/binary, post/binary>> = c`;
  `new_c = <<pre/binary, new_bytes/binary, post/binary>>` (one chunk-sized alloc);
  `dict.insert(data, first, new_c)` — other chunks stay shared.
- `first < last` (unaligned access crossing a boundary — **must be supported**, alignment is
  non-semantic): split the byte run at chunk boundaries and rebuild each touched chunk (at
  most 2 chunks when `bytes <= 8` and `cs >= 8`).
- `get_chunk`: `dict.get(data, idx)` → `Ok(c)` else the all-zero chunk `<<0:(cs*8)>>`. For a
  **load** from an absent in-bounds chunk, short-circuit to zero-bytes — **never materialize**;
  materialize a zero chunk only on a **store**. **PITFALL:** mis-handling the boundary span or
  the absent-chunk case silently corrupts/duplicates bytes or returns garbage.

**Active data init (E5).** `init_data(offset, bytes)`: bounds-check `offset + len <= byte_len`
→ on overflow `Error(MemoryOutOfBounds)` (which aborts instantiation, spec message *"out of
bounds memory access"*); else write via the chunk writer. Per spec the **whole** range is
checked up front — no partial write. (The const offset is evaluated by lower/instantiate;
`rt_mem` receives the resolved `Int`.)

**Multi-byte store is all-or-nothing (E3).** Compute ea + bounds-check **first**; only then
build `new_bytes` and rebuild chunks. A store that traps must mutate **zero** bytes.

**BEAM rep facts.** Sub-binaries are zero-copy references; binaries `>64 B` are off-heap REFC,
shared by pointer across versions/GC. A per-chunk store copies only one chunk (≈O(1) in total
size); the `<<Bin/binary,...>>` append optimization helps only tail-appends and is voided by
matching/sending — **do not** lean on it for interior writes (a giant single binary copies
O(total) per store — unusable).

**The cell seam (coordinate with unit 03).** Per E1 the per-instance state is **one** fixed
pdict key holding the opaque `{mem, globals, table}`. `rt_mem`'s public ops read/write the
**`mem` slot** of that single cell. Required contract from `rt_state`:
`rt_state.mem_get() -> Result(Mem, _)` and `rt_state.mem_put(Mem) -> Nil`, treating `Mem` as
an opaque pass-through (so 03 never imports `rt_mem`'s constructor — they stay parallel).
**Fail-closed (E3):** an un-seeded cell must never yield a usable/garbage `Mem`; that path is
03's node-safe failure, and `rt_mem` must propagate it, never substitute a default zero `Mem`.
Test the cell wrappers separately (seed → op → observe persistence; two seeds never bleed
state); test the *algebra* via the pure core. **See the inconsistency note at the end** — the
01 `rt_state` stub does not yet publish `mem_get/mem_put`.

---

## Verification — Definition of Done (D8 / E4)

Tests assert **spec behavior** (and the oracle), never "whatever the paged impl emits" — no
change-detector tests. Cite spec sections.

1. **Differential `paged ≡ oracle`** over randomized op sequences (E4). Generate streams of
   `load`/`store`/`grow`/`init_data` with random widths, signedness, addresses spanning
   in-bounds/out-of-bounds, **aligned and unaligned**, and **chunk-boundary-crossing**; run the
   pure paged core and the oracle in lockstep; assert **identical loaded values, identical
   traps, and identical final flat byte image** (`to_flat(mem) == o.data`). Run it across
   **several chunk sizes** (e.g. 64-edge+1, 100, 4096) — correctness is chunk-size-independent,
   which is itself an assertion. This catches LE / sign-extension / sparse-zero / boundary bugs.
2. **Spec-corner tests on BOTH impls** (the oracle can share a bug → hold the oracle itself to
   spec — E4). At minimum:
   - **LE multi-byte layout:** store `0x04030201` as i32 → bytes at +0..+3 are `01 02 03 04`;
     `i32.load8_u`@+0 = `0x01`. (endianness.wast / address.wast)
   - **Sign vs zero extend × width:** byte `0xFF` → `load8_s`→ `0xFFFFFFFF`(i32)/`…FF`(i64),
     `load8_u`→ `0xFF`. `result_width` distinguishes i32 vs i64.
   - **Zero-fill:** a never-written in-bounds byte, and every byte of a freshly `grow`-n page,
     reads `0`. (memory.wast)
   - **No-wrap ea:** `addr = 0xFFFFFFFF`, `offset` large → traps (does **not** wrap to a small
     in-bounds ea). (memory_trap.wast / address.wast)
   - **Exact-length off-by-one:** an access ending exactly at `byte_len` succeeds; one byte past
     traps. **Partial store traps with ZERO mutation:** a 4-byte store straddling `byte_len`
     traps and leaves all bytes (incl. the in-bounds prefix) unchanged.
   - **`grow`:** returns OLD size on success then **−1** past the declared max **and** past the
     65536 cap, allocating nothing; `size` reflects only successful grows. (memory_size.wast)
   - **f32/f64 round-trip preserves NaN bits** (store/load a NaN-payload pattern, no double
     round-trip — float_memory.wast); **`init_data`** OOB traps (instantiation abort) and writes
     exact bytes in-bounds; **redundant load after store** returns the stored value
     (memory_redundancy.wast).
3. **Spec anchor = these `.wast`, owned here (E4).** Transcribe the assertions of
   `memory_trap.wast`, `address.wast`, `endianness.wast`, `float_memory.wast`,
   `memory_size.wast`, `memory_redundancy.wast` as `rt_mem`-level tests **now** (the semantics
   they assert *are* `rt_mem`'s contract) — do **not** defer the spec anchor to the capstone.
   Reserve those filenames in the allowlist (flag for unit 11) so unit 11 flips them to
   end-to-end pass; they must stay green there. Spec refs:
   <https://webassembly.github.io/spec/core/exec/instructions.html>,
   <https://webassembly.github.io/spec/core/binary/instructions.html>,
   <https://webassembly.github.io/spec/core/syntax/instructions.html>.
4. **Constant-space store loop (E1).** Confirm a `~100k`-iteration store-in-a-loop pattern (via
   the pure core threaded, or the cell API in a loop) holds bounded process memory — the
   superseded `Mem` is garbage, only the latest is live. (Full end-to-end is unit 11; assert
   the allocation profile at the `rt_mem` level here.)
5. `gleam format --check src test` clean; `gleam build` with **ZERO warnings** (no `todo`/
   `panic`/`let assert` on untrusted paths — every public fn total); `gleam test` stays green
   (≥ the current count); every public fn/type has a `///` contract doc (what / params+ranges /
   `Result` semantics / failure modes).

**Proof of goal:** `paged ≡ oracle` over randomized streams at multiple chunk sizes, **plus**
both impls green on every spec-corner test above, **plus** the six memory `.wast` reserved and
their assertions encoded here.

## Concurrency (sub-task splits)

Freeze first: the **`Mem` shape + pure paged core** — everything else binds to it. Then three
parallel strands: **(a)** paged core + oracle (the algebra + reference; the bulk); **(b)** the
differential + spec-corner suite (against the core signatures); **(c)** the cell wrappers +
fuel (thin shell; blocks on unit 03's `mem_get/mem_put` — stub them meanwhile; lowest risk).

## What this leaves for others

- **Unit 03** seeds/resets the `mem` slot via `fresh` and provides `mem_get/mem_put`
  (fail-closed); **unit 11** supplies the Safe `safe_cap` number and owns the max-pages
  policy wiring + drives the reserved `.wast` end-to-end.
- **Unit 10** emits the `MemLoad`/`MemStore`/`MemSize`/`MemGrow` calls through the seam
  (`{ok,_}`/`{error,R}` `case` + `rt_trap:raise` for load/store; bare i32 for size/grow;
  ordered `let _ = store in …` for the effect) and calls `init_data` from the `instantiate`
  entry. `rt_mem` returns `Result`/bare values and **never** calls `rt_trap` itself.
- The page-map tier stays `paged`; `atomics`/`nif` and bulk-memory ops are Phase 3 (E8). The
  uniform-threading-shaped pure core means the future tier-P `threaded` build is an `emit_core`
  change, not an `rt_mem` rewrite.
