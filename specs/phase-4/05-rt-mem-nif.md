# Unit 05 — `rt_mem_nif`: the tier-N native-memory interface (Safe-forbidden) + a node-safe reference skeleton

> **One owner · Wave A · gated on `«MEM-TIER-FROZEN»`.** Read [`00-overview.md`](00-overview.md)
> (G2/G6/G8) and the keystone [`01-interface-freeze.md`](01-interface-freeze.md) (§B — the
> uniform `rt_mem` backend interface, the tier→module map, the Safe-forbids-nif rule) first;
> Phase-1/2/3 D/E/F decisions still hold. This unit defines the **tier-N `nif`** memory tier:
> the raw-`O(1)` native ceiling, **Unsafe-only and forbidden in Safe** (G6). Per **G8 (honest
> scope)** a production C NIF needs a native build toolchain the pure-Gleam build does not have —
> so Phase 4 **documents the C NIF as deferred** and ships (a) the frozen tier-N interface, (b)
> the Safe-forbidden classification, and (c) a **node-safe reference skeleton** that satisfies the
> interface-conformance + differential suites, **clearly labelled as NOT the native ceiling**.

---

## Context

The Phase-4 memory trust-tier ladder is `paged` (tier-P, Phase-2) → `atomics` (tier-O, unit 04)
→ **`nif` (tier-N, this unit)** (G2). Tiers P and O are **memory-safe by construction** — a BEAM
binary and an Erlang `atomics` array are bounds-safe host objects, so a bounds-check bug's worst
case is a *wrong/missing trap or a node-safe process crash, never a host escape* (§11, G6).
**Tier-N is the exception: it is the one place custom native code runs.** A real C NIF gets a raw
pointer into `enif_alloc`'d memory; the bounds-check is enforced *in C*, and a bug there can read
or write outside the buffer — a genuine **host escape / node crash** (`erl_nif` executes on the
scheduler thread with no VM sandbox). That danger is exactly the raw-`O(1)` performance it buys,
and it is why tier-N is **Unsafe-only, forbidden in Safe fail-closed** (G6/§B.4): the maximally
node-safe posture (`portable`, tier-P) and the default (`safe_default` = `Paged`) never reach it.

Honest scope (G8, verified against the repo): `gleam build` / `gleam test` / CI have **no native
build step** — there is no `c_src/`, no `rebar3` port-compiler, no per-platform `.so` in the tree
(confirmed). Shipping a real NIF would require a build-system change *and* a native artifact per
target *and* an `erlang:load_nif` seam that **can crash the node**. Rather than half-ship that,
Phase 4 **defers the C NIF (documented)** and unit 05 proves the *interface* and the *Safe-forbidden
gate* with a pure-BEAM skeleton — so a future maintainer with a toolchain drops the real `.so` in
**behind the identical interface, zero call-site change**.

---

## Deliverables & freeze milestones

**Binds to** `«MEM-TIER-FROZEN»` (keystone §B): the frozen uniform `rt_mem` backend interface
(§B.2), the `Nif → "twocore@runtime@rt_mem_nif"` tier→module map (§B.1), the differential-oracle
contract (§B.3/§11), and the **Safe-forbids-nif** linker rule (§B.4). Unit 05 does **not** freeze
new contracts — it *implements* the frozen tier-N slot.

1. **`src/twocore/runtime/rt_mem_nif.gleam`** — **NEW (owner: unit 05).** The tier-N module
   exposing the frozen uniform interface (§A): `fresh` + the cell-backed family
   (`load`/`store`/`size`/`grow`/`init_data`) + the threaded family
   (`t_load`/`t_store`/`t_size`/`t_grow`/`t_init_data`) + the differential hook `to_flat`. Bodies
   are the **node-safe reference skeleton** (§B.2 — paged-core delegation), labelled NOT-the-ceiling.
2. **`test/twocore/runtime/rt_mem_nif_test.gleam`** — **NEW.** The interface-conformance suite +
   the §D differential against the `rebuild` oracle + the structural Safe-forbidden assertion.
3. **A documented C-NIF reference design (§B.3)** — the `erl_nif` resource + `on_load` loader + the
   six operations + the FFI-shim shape (mirroring the `twocore_*_ffi.erl` pattern), given as prose
   so the deferred native impl has an exact drop-in seam. **No native artifact is built or loaded.**

**Out of scope for this unit:** the `Nif → module` mapping + the `validate_binding` Safe-forbids-nif
**gate body** (unit 07 owns `profiles.gleam`); the `ceiling` profile that *opts into* `Nif` (unit
07); the pipeline/CLI tier selection (unit 08); the cross-tier differential run over the corpus
(unit 09); the benchmark that measures the ceiling gap (unit 10). Unit 05 owns the tier-N **module**
and its tests, and references those seams without editing their files (D1).

---

## A. The tier-N interface (frozen heads — identical to `paged`/`atomics`)

Every `rt_mem` tier module exposes the **same public heads** so `emit_core`'s state-access seam
(G5) calls any of them identically — the seam is keyed on the `mem_module` name (unit 07 maps
`Nif → "twocore@runtime@rt_mem_nif"`), never on the tier (§B.1). Behaviour is frozen, not just
shape: **little-endian, no-wrap effective address, trap-before-write, bounds-check in every tier**
(the §11 security invariant, G6), matching the WASM memory semantics the paged core already
implements ([spec exec/memory instructions](https://webassembly.github.io/spec/core/exec/instructions.html#memory-instructions):
`ea = i + memarg.offset`, trap iff `ea + N/8 > |mem|`; page = 65536 B).

### A.1 The module + the tier→module map

```gleam
//// `rt_mem_nif` — the tier-N (`nif`) linear-memory backend: the raw-`O(1)` NATIVE ceiling
//// (G2). **Unsafe-only; forbidden in Safe** (G6) — the linker rejects a `Safe + Nif` binding
//// fail-closed (unit 07 §B.4). Selected when `binding.mem_tier == Nif`, which unit 07 maps to
//// the module name `"twocore@runtime@rt_mem_nif"`; `emit_core` stays tier-agnostic (it reads
//// only `mem_module`).
////
//// **Honest status (G8).** A production C NIF (raw pointer, bounds-check in C, can crash the
//// node) needs a native build toolchain this project does not ship. So the BODIES here are a
//// NODE-SAFE REFERENCE SKELETON (§B.2) that reuses the proven paged core — spec-correct by
//// construction, but with PAGED (rebuild) cost, NOT the native ceiling. The real C NIF is
//// documented-deferred (§B.3) and drops in behind THESE heads with no call-site change.
```

| `mem_tier` | `mem_module` (unit 07 maps) | Owner |
|---|---|---|
| `Nif` | `"twocore@runtime@rt_mem_nif"` | **unit 05** |

### A.2 The cell-backed family (for `state_strategy: Cell`) — the frozen Phase-2 heads

Same signatures as the paged `rt_mem` (verified in code), operating on the `mem` slot of this
process's cell (via `rt_state.mem_get`/`mem_put`). `rt_mem_nif` **never calls `rt_trap`** — the
seam does the `{ok,_}`/`{error,R}` `case` + raise (keystone §A.3).

```gleam
/// Build a FRESH tier-N memory of `min_pages` zero pages, baking the effective max
/// `min(declared_max ?? safe_cap, safe_cap, 65536)`. Returns the opaque handle as `Dynamic`
/// (ready for `rt_state.seed`). Total.
pub fn fresh(min_pages: Int, max_pages: Option(Int), safe_cap: Int) -> Dynamic

/// Load `bytes` (1/2/4/8) little-endian at `ea = addr(unsigned i32) + offset`, normalised to
/// `result_width` bits (`signed` ⇒ sign-extend). `Ok(bits)` | `Error(MemoryOutOfBounds)` iff
/// `ea + bytes > byte_len`. Reads the handle from the cell.
pub fn load(bytes: Int, signed: Bool, result_width: Int, addr: Int, offset: Int)
  -> Result(Int, TrapReason)
/// Store `value`'s low `bytes` little-endian at `ea`. Traps BEFORE any byte is written (§11).
pub fn store(bytes: Int, addr: Int, value: Int, offset: Int) -> Result(Nil, TrapReason)
pub fn size() -> Int                                   // current pages (memory.size)
pub fn grow(delta: Int) -> Int                         // OLD pages | -1 past the cap; charges fuel
pub fn init_data(offset: Int, bytes: BitArray) -> Result(Nil, TrapReason)  // active segment
```

### A.3 The threaded family (for `state_strategy: Threaded`) — the §A.2 keystone heads

Thin adapters that project `st.mem` (opaque `Dynamic`), run the tier's core, and inject the
result back into the record (the uniform-threading rule §10). Reads leave `st` untouched;
mutators return the rebound record.

```gleam
pub fn t_load(st: InstanceState, bytes: Int, signed: Bool, result_width: Int,
              addr: Int, offset: Int) -> Result(Int, TrapReason)          // read-only
pub fn t_store(st: InstanceState, bytes: Int, addr: Int, value: Int,
               offset: Int) -> Result(InstanceState, TrapReason)          // rebound record
pub fn t_size(st: InstanceState) -> Int                                   // read-only
pub fn t_grow(st: InstanceState, delta: Int) -> #(Int, InstanceState)     // prev pages + record
pub fn t_init_data(st: InstanceState, offset: Int,
                   bytes: BitArray) -> Result(InstanceState, TrapReason)  // at instantiate
```

> **The uniform signature serves both backends (§10).** Under a *real* NIF the handle is a
> mutable native resource, so `t_store` mutates in place and returns the **same** handle; under
> the shipped skeleton the handle is the immutable paged `Mem`, so `t_store` returns a **new**
> handle. The signature is identical either way — which is precisely why the deferred native
> impl needs no seam change.

### A.4 The differential hook (for §D/§11)

```gleam
/// The tier's whole in-bounds byte image (absent regions rendered as zero), so the oracle can
/// compare byte-for-byte after each op. Coerces the opaque `Dynamic` handle to the tier's own
/// shape. O(byte_len); tests only.
pub fn to_flat(mem: Dynamic) -> BitArray
```

---

## B. Honest status — the C NIF is deferred; unit 05 ships a node-safe reference skeleton (G8)

### B.1 Why the production C NIF is deferred (documented reason)

A real tier-N memory is a C NIF, which the pure-Gleam toolchain cannot build or ship:

- **No native build step.** `gleam build`/`gleam test`/CI compile Gleam → Core Erlang → `.beam`
  only. A NIF needs a C compiler, `erl_nif.h`, and a per-platform shared object
  (`.so`/`.dll`/`.dylib`) built at package-build time (`rebar3` port-compiler / a Makefile) and a
  binary artifact committed or built per target — none present (verified: no `c_src/`, no native
  config in `gleam.toml`).
- **It can crash the node.** `erlang:load_nif` loads code that runs on the scheduler thread with a
  raw pointer and no VM sandbox; a bounds bug is a host escape (G6). Shipping that under the
  guise of "tested" without the toolchain to build, sign, and CI-exercise the `.so` would be
  dishonest and a maintenance/security burden.

So Phase 4 **defers the native impl (documented, not dropped)** and unit 05 proves the *interface*
and the *Safe-forbidden gate* — the two things that must exist for the tier to be real and safe —
with a pure-BEAM skeleton. **Do not claim a shipped C NIF** (G8): the benchmark (unit 10) measures
the *ceiling gap* against real hand-written-Erlang/native numbers and reports the skeleton as a
stand-in, not the ceiling.

### B.2 The shipped skeleton — paged-core delegation (spec-correct; NOT the ceiling)

The `rt_mem_nif` bodies **delegate to the already-proven paged core** (`twocore/runtime/rt_mem`'s
public pure core `fresh_mem`/`mem_load`/`mem_store`/`mem_grow`/`mem_init_data` + `to_flat`, and the
cell-backed `load`/`store`/`size`/`grow`/`init_data`), re-exported behind the tier-N heads (§A).
Coercion of the cell's opaque `Dynamic` to the paged `Mem` is a `gleam_stdlib:identity/1` no-op
(sound: under `mem_tier == Nif` the `mem` slot is produced solely by `rt_mem_nif → rt_mem`).

- **What it IS:** byte-for-byte spec-correct — it *is* the paged algebra, which unit P2-04
  differentially proved against the oracle (so the tier-N module passes §D by construction). It is
  **pure BEAM**, so — unlike the real NIF — it **cannot crash the node**, is unbounded-max-friendly
  (sparse; no eager allocation of a `Nif`-under-`Unsafe` 4 GiB buffer), and lands green with **zero
  FFI** and **no dependency on unit 04's landing order** (Wave-A independent).
- **What it is NOT:** the raw-`O(1)` native ceiling. It carries the paged **rebuild** cost (a store
  copies one chunk; there is no in-place native write). The tier's *classification* (tier-N,
  Safe-forbidden) is a property of its **intended production impl**, not of this node-safe body —
  the Safe-forbidden gate (§C) exists to contain the *native* impl that will replace it.

> **Freeze decision — paged delegation over an `atomics` stand-in.** The overview's `e.g.`
> suggested an `atomics`-backed stand-in; unit 05 chooses paged delegation because (1) it is
> independent of unit 04, (2) it has no `atomics` fixed-size/pre-allocation cliff — decisive since
> tier-N is *Unsafe*, where the declared max can be the full 2¹⁶-page address space — and (3) the
> skeleton's job is to prove the *interface + gate + differential harness*, not native speed (which
> is unattainable without native code). An `atomics`-backed variant (reusing unit 04's core) is a
> valid *faithful-semantics* upgrade if a mutable-in-place code path is later wanted for §D; it is
> **not** the shipped choice. Flagged to the EM.

### B.3 The deferred C-NIF reference design (the drop-in seam)

So the native impl is a mechanical swap, not a redesign, the reference shape is fixed here
(mirroring the hand-written `twocore_*_ffi.erl` shim pattern — a `twocore_`-namespaced Erlang
module called from Gleam via `@external`, exactly like `twocore_rt_state_ffi`):

- **`c_src/rt_mem_nif.c`** — `ERL_NIF_INIT(twocore_rt_mem_nif, funcs, load, NULL, upgrade, unload)`
  with a resource type wrapping `{uint8_t* base; size_t byte_len; size_t max_bytes;}` allocated via
  `enif_alloc_resource` (byte buffer `enif_alloc`'d, or `mmap`'d to `max_bytes`). Six NIFs mirror
  §A: `fresh`/`load`/`store`/`size`/`grow`/`init_data`. **Each op does the no-wrap bounds-check in
  C *before* the `memcpy`** (`ea + n > byte_len → return the trap tuple`), little-endian byte moves,
  `grow` bumps `byte_len` within `max_bytes` (else `-1`). This bounds-check IS the security boundary
  — a bug is a host escape, which is why the tier is Unsafe-only. The resource is process-local (no
  cross-process sharing — the threads non-goal, §12).
- **`twocore_rt_mem_nif.erl`** — the hand-written loader FFI: `-on_load(init/0). init() ->
  erlang:load_nif(<priv>/rt_mem_nif, 0).` with each exported op a stub raising
  `erlang:nif_error(not_loaded)` until the `.so` loads. `twocore_`-prefixed for namespace hygiene
  (overview §5), so it can never collide with an OTP module.
- **`src/twocore/runtime/rt_mem_nif.gleam`** — in the native build, each head becomes
  `@external(erlang, "twocore_rt_mem_nif", "<op>")`; **the public heads (§A) are byte-identical to
  the skeleton**, so units 07/08/09 and the seam are untouched.

Swapping the skeleton for the native impl therefore adds three files + a native build step and
edits only the `rt_mem_nif.gleam` *bodies* — the interface, the tier→module map, and the
Safe-forbidden gate all stay put.

---

## C. Safe-forbids-nif — fail-closed, Unsafe-only (G6, keystone §B.4)

**Safe permits tier P or O, never N.** Unit 05 owns the tier-N *module*; the enforcing *gate* is
unit 07's (`profiles.gleam`, D1). Two layers hold, both fail-closed (D4):

1. **Structural — no constructor yields `Safe + Nif`.** Gleam has no default field values, so every
   Safe profile constructor NAMES its tier: `safe()`/`safe_capped(_)`/`safe_metered(_)`/
   `safe_default()` set `mem_tier: Paged`, **never** `Nif`; only the Unsafe `ceiling()` profile
   (unit 07) sets `Nif`. A `Safe + Nif` binding is **unconstructible through the profile API** — a
   property of the type, not a runtime check. Unit 05's test asserts this (§D) over the enumerated
   Safe constructors.
2. **Defensive — the linker rejects a hand-built `Safe + Nif` binding.** Unit 07's
   `validate_binding(b) -> Result(Binding, LinkError)` returns `Error(SafeForbidsNif)` iff
   `b.mode == Safe && b.mem_tier == Nif`, wired into `instantiate`. Unit 05 does **not** implement
   the gate; it references it and MUST NOT introduce any path that constructs a Safe binding naming
   `Nif`.

The `portable` (tier-P, Safe) and `safe_default` (Paged) postures never reach `rt_mem_nif`; only an
Unsafe, explicitly-`ceiling` build links it (G3/G6).

---

## D. Differential vs the `rebuild` oracle (whatever impl ships) (§B.3/§11)

Every tier is **held to the spec by the flat-binary `rebuild` oracle** (`rt_mem`'s `o_*` family +
`o_flat` — the trivially-correct reference, E4). Unit 05 runs the same harness the keystone froze:
drive one shared operation trace (`fresh`; a sequence of in-bounds / out-of-bounds
`load`/`store`/`grow`/`init_data`, aligned + unaligned + boundary-crossing, sub-word signed +
unsigned, `addr = 0xFFFFFFFF` + large offset, exact-length off-by-one) through the tier-N handle
**and** the oracle, asserting after **each** op:

- identical returned value,
- identical trap (`Ok` / `Error(reason)`),
- identical byte image: `rt_mem_nif.to_flat(handle) == rt_mem.o_flat(oracle)`.

For the **shipped skeleton** this re-establishes `tier-N ≡ oracle` (the skeleton *is* the paged
algebra, so it holds by construction) **and** proves the tier-N *module wiring* + `to_flat`
coercion + the Safe-forbidden classification introduce no corruption. When the **real NIF** lands,
the *identical* harness holds the native code to the spec — the byte-image comparison is the exact
check that catches a C bounds/endianness bug before it can escape. This is the G7 bar: **every tier
is byte-identical to the spec.**

---

## Effect / soundness / security note

- **Tier-N is the one native seam, gated (G6).** A real C NIF can crash the node / read out of the
  host buffer on a bounds bug — a true host escape, unlike tiers P/O. Hence Unsafe-only,
  Safe-forbidden fail-closed (§C). The **shipped skeleton is pure BEAM and cannot crash the node**;
  the classification and the gate are on the *tier's intended native impl*, and exist so the gate
  is already in force the day the `.so` drops in.
- **No ambient authority (D3a).** The seam still emits a fixed `call
  'twocore@runtime@rt_mem_nif':'<op>'(...)` — a build-controlled module atom + literal op name;
  the tier is a link-time module swap, never a data-driven `apply`. The deferred loader's
  `load_nif` path is `on_load`-only and build-fixed.
- **Fail-closed defaults (D4).** `safe_default` = `Paged` (never `Nif`); reaching tier-N requires
  NAMING the Unsafe `ceiling` profile *and* passing the Safe-forbids-nif gate — two explicit
  opt-ins, no posture change by omission.
- **Floats-as-bits (D5) unchanged.** Memory is raw bytes over the IEEE bit pattern in every tier —
  the skeleton inherits the paged core's no-double-round-trip codec; the native design likewise
  `memcpy`s bytes, never decodes a float.
- **Threads / shared memory stay a hard non-goal (§12).** The skeleton handle is process-local (in
  the cell / threaded through one process); the native resource is process-local, never shared. No
  tier is ever cross-process.

---

## Verification (Definition of Done)

Tests assert **spec behaviour** and the **oracle**, never "whatever the skeleton emits" (D8) —
cite spec sections. **Done = the suite passes**, not "it compiles."

1. **Interface conformance.** `rt_mem_nif` exposes every frozen head (§A) with the exact
   signatures — a compile-time freeze plus behavioural checks: LE multi-byte layout (store
   `0x04030201` as i32 → bytes `01 02 03 04`; `load8_u@+0 = 0x01`), sign-vs-zero-extend × width
   (byte `0xFF` → `load8_s` `0xFFFFFFFF`(i32)/`…FF`(i64), `load8_u` `0xFF`), zero-fill of
   never-written + freshly-grown pages, `init_data` OOB → instantiation trap, `grow` returns OLD
   pages then `-1` past the cap (allocating nothing).
   [spec exec/memory](https://webassembly.github.io/spec/core/exec/instructions.html#memory-instructions).
2. **§D differential vs the oracle** over the shared op trace (aligned/unaligned/boundary-crossing,
   in/out-of-bounds), asserting identical value + trap + byte image after each op. Includes the
   no-wrap corner (`addr = 0xFFFFFFFF` + large `offset` traps, does **not** wrap in-bounds) and
   trap-before-write (a store straddling `byte_len` traps with **zero** mutation).
3. **Safe-forbids-nif (structural, G6/§C).** Assert that no `profiles.safe*` constructor yields
   `mem_tier == Nif` (enumerated over `safe()`/`safe_capped(_)`/`safe_metered(_)`/`safe_default()`)
   — pinning that `Safe + Nif` is unconstructible through the profile API. (Unit 07 adds the
   defensive `validate_binding` tests.)
4. **Both state families exercised.** The cell-backed family (seed → op → observe persistence; two
   seeds never bleed state) and the threaded family (`t_store`/`t_grow` return the rebound record;
   reads leave `st` untouched) both pass — proving the tier serves `Cell` and `Threaded` builds.
5. `gleam format --check src test` clean; `gleam build` with **zero warnings** (no `todo`/`panic`/
   `let assert` on untrusted paths — every public fn total; the skeleton is pure Gleam, no FFI);
   `gleam test` stays green (≥ current count); **conformance `fail=0` under both profiles**
   (Phase-4 is conformance-neutral, G7 — adding an unlinked tier module changes no default-path
   behaviour); every public fn/type carries a `///` contract doc (what / params+ranges / `Result`
   semantics / failure modes / the NOT-the-ceiling caveat).

**Proof of goal:** the tier-N interface is real and uniform (§A); it is differentially byte-identical
to the spec via the oracle (§D); `Safe + Nif` is unconstructible (§C); and the honest status —
skeleton shipped, native C NIF documented-deferred with a drop-in seam (§B) — is recorded, not
overstated (G8).

---

## What this unit leaves

- **Unit 07** adds the `Nif → "twocore@runtime@rt_mem_nif"` map, implements the `validate_binding`
  **Safe-forbids-nif** gate body + its spec-cited tests, and composes the Unsafe **`ceiling`**
  profile that opts into `Nif` (the sole path that links this module).
- **Unit 08** selects `mem_tier` per profile in the pipeline + CLI (a `ceiling`/`--nif` opt-in),
  and threads the record through the run-ABI for a `Threaded + Nif` build.
- **Unit 09** runs the cross-tier differential over the corpus for every shipped
  `(state_strategy, mem_tier)` combination — the tier-N skeleton included — against the oracle.
- **Unit 10** re-measures the honest benchmark and reports the **ceiling gap**: the skeleton carries
  paged cost, so the raw-`O(1)` native ceiling stays the *documented target*, not a shipped number.
- **A future maintainer** with a native toolchain drops in `c_src/rt_mem_nif.c` +
  `twocore_rt_mem_nif.erl` + the `@external` bodies (§B.3) behind the identical §A interface — the
  gate, the map, and the differential harness already hold the native code to the spec.
