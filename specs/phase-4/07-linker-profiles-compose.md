# Unit 07 — The Linker: Compose the Tier Axes + `portable`/`ceiling` + Safe-forbids-nif (G3/G6)

> **One owner (`runtime/profiles.gleam`, extend). Wave B.** Read [`00-overview.md`](00-overview.md)
> (G1–G8) first, then the keystone [`01-interface-freeze.md`](01-interface-freeze.md) —
> this unit **binds to** its frozen axes (`StateStrategy`, `MemTier`, `TableTier` in
> `instance.gleam`), the tier→module table (§B.1), and the frozen `validate_binding` gate shape
> (§B.4). Phase-1's D1–D10, Phase-2's E1–E8, and Phase-3's F1–F8 all still hold. This unit is the
> **linker**: it composes the three orthogonal build axes (`state_strategy × mem_tier × policy`)
> into the two headline deployment profiles — **`portable()`** (the runs-anywhere, tier-P
> everything, no-OTP/no-NIF headline) and **`ceiling()`** (the perf posture) — resolves each
> tier to its runtime module (keeping `emit_core` tier-agnostic, G5), and enforces the one hard
> composition constraint fail-closed: **Safe permits tier P or O, never N** (G6).

This is a **linker/profile** unit. It owns **only `profiles.gleam` + its tests**; `instance.gleam`
(the `Binding` record, the three tier enums) is **keystone(01)-owned** and this unit merely imports
it (D1, unchanged since Phase 1). It builds no `rt_mem` backend, no threaded seam, no `atomics`
body — those are units 02–06. It **assembles** the vetted pieces into two named postures, **maps
tier → module** so the codegen seam stays tier-agnostic (G5), and **proves the fail-closed
composition property** the phase claims. Conformance-neutral (G7): the default `safe()`/`unsafe()`
paths are byte-identical to Phase 3.

---

## Deliverables & freeze milestones

**Consumes (frozen upstream):**
- `«STATE-STRATEGY-FROZEN»` / `«MEM-TIER-FROZEN»` (unit 01): `instance.StateStrategy { Cell
  Threaded }`, `instance.MemTier { Paged Atomics Nif }`, `instance.TableTier { TablePaged
  TableEts TableAtomics }`, and the `Binding` fields `state_strategy`/`mem_tier`/`table_tier`
  (landed green with `safe_default()` = `Cell`/`Paged`/`TablePaged`, the byte-identical Phase-2/3
  posture).
- The keystone tier→module table (§B.1) and the frozen **Safe-forbids-nif** gate shape (§B.4):
  `validate_binding(b: Binding) -> Result(Binding, LinkError)` with `Error(SafeForbidsNif)` iff
  `mode == Safe && mem_tier == Nif`. The keystone froze the **rule and the gate's shape**; this
  unit implements the body + the `LinkError` type + the tests.
- The existing `profiles.gleam` surface (Phases 1–3, this file's own prior units): `safe()`,
  `safe_capped(max_pages)`, `safe_metered(budget)`, `unsafe()`, `Instance`, `instantiate/1`,
  `safe_instance()`, `unsafe_instance()`, `mode/1`, `is_safe/1`, `coexist_name/2`,
  `safe_max_pages()`. All continue to compile unchanged (they are record-spreads over
  `safe_default()`/`safe()` that absorb the three new tier fields, keystone reach-row 2).

**Produces (this unit):**
- `mem_module_for/1` + `table_module_for/1` (§A.1) — the tier→module map; **sole home** of the
  two new tier-module atoms (`rt_mem_atomics`/`rt_mem_nif`, `rt_table_ets`/`rt_table_atomics`),
  tier-P arms **referencing** `safe_default()`'s strings (D1: never re-spell a vetted atom).
- `resolve_tiers/1` (§A.2) — the **single source** that couples the declared tiers to the linked
  modules: `mem_module := mem_module_for(mem_tier)`, `table_module := table_module_for(table_tier)`
  (P5). Every binding that reaches `emit_core` passes through it (via `compose`/`link`), so a
  declared tier can never diverge from the atom the seam actually links.
- `compose/4` (§A.2) — the axis constructor: sets the tier fields and applies `resolve_tiers` so
  the matching resolved `mem_module`/`table_module` follow, and `emit_core` (reads only the module
  fields, G5) links the backend.
- `portable()` (§B) — **tier-P everything**: `Threaded` + `Paged` + `TablePaged` + `bif` + Safe.
  The runs-anywhere headline: no OTP-native state, no NIF, cannot crash the node (G3/G6).
- `ceiling()` (§C) — the perf posture: `Unsafe` + `Atomics` + `Cell` + `TableAtomics` + aggressive
  optimizer. The fastest build that ships today; the tier-N `Nif` ceiling is one Unsafe composition away.
- `LinkError` + `validate_binding/1` (§D) — the fail-closed gate: rejects Safe+Nif (G6) **and** any
  binding whose `mem_module` disagrees with `mem_module_for(mem_tier)` (P5 — guard the load-bearing
  field `emit_core` actually links); plus `link/1` (`validate_binding` ∘ `resolve_tiers` ∘
  `instantiate`), the **sole** `Binding → Instance` seam. `instantiate/1` keeps its total
  `Binding -> Instance` signature but is **self-validating** (fail-closed on the unconstructible
  Safe+Nif), so no path can fail open (P5).
- Tests (§Verification): `portable()` tier-P everything; `ceiling()` the perf posture; **Safe+Nif
  unconstructible** + rejected; every P/O composition admitted; `safe()`/`unsafe()` still valid.

**Freeze:** this unit produces no new milestone; it consumes `«MEM-TIER-FROZEN»` and is a
prerequisite (with 04/06/08) for the capstone's (unit 11) every-`(strategy × tier)` conformance
proof and the runs-anywhere grep proof.

---

## A. Composition: the tier→module map + the `compose` constructor

### A.1 `mem_module_for` / `table_module_for` — the tier → runtime-module map (G5, keystone §B.1)

A trust tier is a **link-time module swap** (B2, unchanged): the codegen seam emits
`call '<mem_module>':'<store|t_store>'(...)` against a fixed `binding.mem_module` atom and
**never reads `mem_tier`** (G5 — the tier is confined behind `rt_mem`). So the linker's job is to
turn the declared *tier* into the *module atom* the seam links. That map lives here — the linker
is the composer (overview §4) — and is the **single home** of the two genuinely-new tier atoms;
the tier-P arm **reuses `safe_default()`'s existing string** rather than re-spelling it (D1: the
vetted `twocore@runtime@rt_mem`/`rt_table` atoms have exactly one home, `instance.safe_default()`).

```gleam
import twocore/runtime/instance.{
  type Binding, type MemTier, type StateStrategy, type TableTier, Atomics, Binding,
  Nif, Paged, Safe, TableAtomics, TableEts, TablePaged, safe_default,
}
// `LinkError` (§D) is defined in THIS module — unit 07 owns it (keystone §B.4).

/// Resolve a linear-memory trust tier (`MemTier`, keystone §B.1) to the `rt_mem` backend module
/// `emit_core` links for it. Keeping this map here — not in the codegen seam — is what makes the
/// tier a build-time module swap the emitter never sees (G5): `emit_core` reads only
/// `binding.mem_module`.
///
/// - `tier`: the declared memory tier.
/// - Returns the Gleam→Erlang-mangled module name. `Paged` returns `safe_default().mem_module`
///   (D1 — the existing vetted atom keeps its single home, never re-spelled); `Atomics`/`Nif`
///   name the new tier modules (units 04/05), which have their single home here. Total.
pub fn mem_module_for(tier: MemTier) -> String {
  case tier {
    Paged -> safe_default().mem_module
    Atomics -> "twocore@runtime@rt_mem_atomics"
    Nif -> "twocore@runtime@rt_mem_nif"
  }
}

/// Resolve a funcref-table trust tier (`TableTier`) to its `rt_table` backend module (keystone
/// §B.1). There is no `nif` table tier, so no `table_module_for` result can violate
/// Safe-forbids-nif. `TablePaged` reuses `safe_default().table_module` (D1). Total.
pub fn table_module_for(tier: TableTier) -> String {
  case tier {
    TablePaged -> safe_default().table_module
    TableEts -> "twocore@runtime@rt_table_ets"
    TableAtomics -> "twocore@runtime@rt_table_atomics"
  }
}
```

### A.2 `resolve_tiers` + `compose` — coherent tier→module coupling + the axis constructor

The three build axes are **orthogonal** (G3): `state_strategy` is a codegen-shape sub-axis
(`Cell` vs `Threaded`, resolved in `emit_core`'s seam, G1/G5), `mem_tier`/`table_tier` are
link-time module swaps (§A.1), and both are orthogonal to the Safe/Unsafe **policy** axis
(Phase 3). The coupling of a declared tier to its resolved module lives in **one** function,
`resolve_tiers` (P5): it is the **single source** that sets `mem_module`/`table_module` from the
`*_tier` fields, and both `compose` (below) and `link` (§D.3) funnel through it, so the declared
tier and the linked module `emit_core` reads can never silently diverge — `mem_tier` is never a
merely-advisory field the seam ignores:

```gleam
/// Couple a binding's declared tiers to the runtime modules `emit_core` links (P5, G5). Sets
/// `mem_module := mem_module_for(mem_tier)` and `table_module := table_module_for(table_tier)` —
/// nothing else. This is the **single source** of that coupling: `compose` applies it and `link`
/// re-applies it (§D.3), so the atom `emit_core` reads is always derived from the declared tier,
/// never a stale hand-set string.
///
/// - `binding`: any binding (its `*_tier` fields are authoritative; the `*_module` fields are
///   (re)derived from them).
/// - Returns the binding with `mem_module`/`table_module` made coherent with the tiers. Idempotent
///   and total; touches no policy field.
pub fn resolve_tiers(binding: Binding) -> Binding {
  Binding(
    ..binding,
    mem_module: mem_module_for(binding.mem_tier),
    table_module: table_module_for(binding.table_tier),
  )
}

/// Compose the three build axes over a policy `base` (keystone §B.1, G3). Overrides
/// `state_strategy`/`mem_tier`/`table_tier` and — via `resolve_tiers` (the single coupler) — the
/// matching `mem_module`/`table_module`, so the declared tier and the linked module never diverge
/// (`compose` is the sanctioned path; a hand-build setting only `mem_tier` and skipping
/// `resolve_tiers` leaves `mem_module` stale and is caught by `validate_binding`, §D). Every POLICY
/// field (`mode`, the five enums, `fuel_budget`, `safe_max_pages`, the non-tier `*_module` names)
/// is inherited from `base` unchanged — composition never mutates policy.
///
/// - `base`: the policy binding (`safe()`/`unsafe()`) whose posture is inherited.
/// - `state_strategy`/`mem_tier`/`table_tier`: the tier choices.
/// - Returns the composed `Binding`. Total; policy COHERENCE (Safe-forbids-nif) is checked
///   separately by `validate_binding/1` (§D), so `compose` can express a hand-built incoherent
///   point for the gate to reject.
pub fn compose(
  base: Binding,
  state_strategy: StateStrategy,
  mem_tier: MemTier,
  table_tier: TableTier,
) -> Binding {
  resolve_tiers(
    Binding(
      ..base,
      state_strategy: state_strategy,
      mem_tier: mem_tier,
      table_tier: table_tier,
    ),
  )
}
```

`compose` is deliberately **policy-preserving**: it never touches `mode` or the five policy
enums. So the fail-closed constraint (§D) is a property of the `base` × `mem_tier` pair, and the
two shipped profiles below are just two calls to `compose` over `safe()` and `unsafe()`.

---

## B. `portable()` — the runs-anywhere headline (tier-P everything, G3)

> **The maximally-safe posture (G6): no OTP-native state, no NIF, cannot crash the node, runs on
> a bare BEAM.** This is the high-level pitch's *"no OTP, no NIF, runs-anywhere"* build made real
> — the platform property Phase 3 left unbuilt.

`portable()` is **tier-P on every axis**, composed over the Safe policy `base`:

```gleam
import twocore/runtime/instance.{Cell, Threaded}

/// The **`portable`** profile (G3) — the runs-anywhere headline: tier-P on every axis over the
/// fail-closed Safe policy. `Threaded` instance-state (a purely-functional record threaded
/// through generated code, G1 — no process-dictionary **instance-state** cell, no OTP-native
/// state), `Paged` linear memory (immutable-binary, no native code), `TablePaged` table, and the
/// Safe posture's `bif` numerics (`num_module` inherited from `safe()` — `rt_num`, tier-P). No
/// `atomics`, no `ets`, no `persistent_term`, no NIF, and no pdict **instance-state** cell
/// (`rt_state` `seed`/`get`/`put`) — the Safe CPU-fuel counter and host-policy cell (`MeterFuel` +
/// `HostDenyAll`) are node-safe, process-local **tier-O policy overlays** (BEAM builtins on every
/// BEAM, not instance state; Safe permits tier P or O, never N — P4), not the instance-state cell.
/// So a `portable` build links **zero** OTP-native or native-code state, is provably unable to
/// crash the node (G6), and loads on a bare BEAM.
///
/// Field posture (asserted against G3, not this body): `mode == Safe` with all five Safe policy
/// fields (`Baseline`/`MeterFuel`/`BifAllowlist`/`StdlibOwn`/`HostDenyAll`) inherited from
/// `safe()`; `state_strategy == Threaded`; `mem_tier == Paged` / `mem_module ==
/// safe().mem_module`; `table_tier == TablePaged`. `validate_binding(portable())` is `Ok` (Safe +
/// tier-P is coherent). Total — never fails.
pub fn portable() -> Binding {
  compose(safe(), Threaded, Paged, TablePaged)
}
```

The only difference from `safe()` is `state_strategy: Cell → Threaded` (the codegen-shape switch
unit 02 realises) — the memory/table modules are **byte-identical** to `safe()` because
`Paged`/`TablePaged` resolve to `safe_default()`'s own atoms (§A.1). So `portable` inherits the
full Safe sandbox (deny-all host, allowlisted BIFs, enforcing metering, the finite `safe_max_pages`
cap — the i32 2¹⁶-page invariant,
[spec §4.2.8](https://webassembly.github.io/spec/core/exec/runtime.html#memory-instances)) and adds
the tier-P *state* posture on top. Per G4 the `Threaded` build still runs constant-space loops and
stays preemptible (the instance-state record is a fixed-size box) — unit 09's tested acceptance
property, not asserted here; this unit only *names* the posture. The resource-bound channels stay
orthogonal to the tier axis: a capped/threaded build is `Binding(..portable(), safe_max_pages: p)`.

---

## C. `ceiling()` — the perf posture (G3)

> **The fastest build.** Unsafe policy (aggressive optimizer, no metering, open gates) composed
> with the tier-O `atomics` O(1) memory that closes most of the Phase-3 performance gap (G8).

```gleam
/// The **`ceiling`** profile (G3) — the performance posture: the `Unsafe` policy (aggressive
/// optimizer, `MeterOff`, open BIF/host gates, passthrough stdlib) composed with the tier-O
/// `Atomics` linear memory (O(1) process-local mutation, no custom native code, cannot crash the
/// node — the shipped performance lever, G8) over the `Cell` state strategy (the pdict cell — no
/// per-function record-threading overhead on the hot path) and a tier-O `TableAtomics` table.
///
/// Field posture (asserted against G3): `mode == Unsafe` with the full aggressive posture
/// inherited from `unsafe()` (`Aggressive`/`MeterOff`/`BifOpen`/`StdlibPassthrough`/`HostOpen`);
/// `state_strategy == Cell`; `mem_tier == Atomics` / `mem_module == mem_module_for(Atomics)`;
/// `table_tier == TableAtomics`. `validate_binding(ceiling())` is `Ok` (Unsafe admits tier-O).
/// Total — never fails.
pub fn ceiling() -> Binding {
  compose(unsafe(), Cell, Atomics, TableAtomics)
}
```

**Why `Atomics`, not `Nif`, is `ceiling()`'s default (G8 honesty).** `ceiling()` selects the
fastest tier that **actually ships and runs today** — `atomics` is a node-safe O(1) win with *no
custom native code* (unit 04). The absolute tier-N `Nif` ceiling (raw native memory, *can* crash
the node) is the documented ceiling whose production C impl may be **deferred** (G8); it is one
further composition over the *already-Unsafe* `ceiling` base — `compose(ceiling(), Cell, Nif,
TableAtomics)` — which `validate_binding` admits precisely because the base is Unsafe (§D).
Defaulting `ceiling()` to `Nif` would make it fail to link wherever the native toolchain is
unbuilt; defaulting to `Atomics` keeps `ceiling()` runnable — **provided a bounded cap** (P6).
`atomics` `fresh` pre-allocates to the effective max, so it engages **only when the effective max
≤ the reserve cap** (keystone §B.2): on an uncapped no-max module (effective max = 65536 pages =
4 GiB) the link is a **fail-closed rejection** (*"atomics requires a bounded max/cap ≤ the reserve
cap"*), **never** a silent 4 GiB pre-allocation and **never** a silent paged fallback (any degrade,
if permitted at all, must be explicit and reported). So `ceiling()` (and the benchmark, unit 10)
must supply a bounded cap — via `safe_max_pages` or the module's own `max` — for `atomics` to
actually engage; that keeps `ceiling()` a real, runnable artifact and leaves the Nif ceiling a
named, Unsafe-only opt-in. *(Flagged to the EM — the name "ceiling" could read as "Nif"; the
honest, ships-today reading is Atomics, and only over a bounded memory.)*

---

## D. The Safe-forbids-nif fail-closed rule (G6, keystone §B.4)

**Safe permits tier P or O, never N** (overview §6). Tier-N `nif` runs custom C that *can crash
the node*, so it is Unsafe-only. The guarantee is two layers, both fail-closed (D4):

### D.1 Structural — no constructor yields Safe+Nif

Gleam has no default field values, so every profile constructor **names** its tier. `safe()`,
`safe_capped(_)`, `safe_metered(_)`, `safe_default()`, and `portable()` all resolve `mem_tier` to
`Paged` (never `Nif`); the only constructor here that names `mem_tier: Atomics` is `ceiling()`
(Unsafe), and `Nif` is named only by the explicit Unsafe composition in §C. So a **`Safe + Nif`
binding is unconstructible through the profile API** — the fail-closed guarantee is a property of
the type surface, not a runtime check (this is the same argument that made `unsafe()` the *only*
Unsafe constructor in Phase 3, extended to the tier axis).

### D.2 Defensive — the linker rejects a hand-built Safe+Nif binding

Because a caller *could* hand-build `Binding(..safe(), mem_tier: Nif)` bypassing the constructors,
the linker adds a fail-closed validation gate (the keystone froze its shape; this unit implements
the body + the error type):

```gleam
/// The linker's fail-closed link errors (G6, P5). Two variants in Phase 4.
///
/// - `SafeForbidsNif`: a `Safe` binding named a tier-N (`Nif`) memory. Tier-N runs custom native
///   code that can crash the node, so it is Unsafe-only — the one hard constraint on the
///   otherwise-orthogonal `state_strategy × mem_tier × policy` space (G3/G6).
/// - `TierModuleMismatch`: the binding's `mem_module` disagrees with `mem_module_for(mem_tier)`
///   (P5) — the load-bearing field `emit_core` actually links was hand-set stale/incoherent with
///   the declared tier. Rejected fail-closed rather than silently linked, so a declared `mem_tier`
///   can never degrade to advisory-only while the seam links a different backend.
pub type LinkError {
  SafeForbidsNif
  TierModuleMismatch
}

/// Reject an incoherent binding fail-closed (G6/P5, keystone §B.4), guarding the **load-bearing**
/// field `emit_core` links. Two checks: (1) `Error(SafeForbidsNif)` iff the binding is `Safe` AND
/// names a tier-N memory (`b.mode == Safe && b.mem_tier == Nif`); (2) `Error(TierModuleMismatch)`
/// iff `b.mem_module != mem_module_for(b.mem_tier)` — a stale/hand-set module that would let the
/// declared tier be advisory-only while the seam links a different backend (P5). Every other
/// composition of `state_strategy × mem_tier × policy` is admitted `Ok(b)` unchanged —
/// Safe+`Paged`/`Atomics`, Unsafe+any tier, either state strategy, any table tier (there is no
/// `Nif` table tier). Pure predicate — no runtime dispatch, no ambient authority (D3a); reads only
/// build-time fields.
///
/// - `b`: the binding to validate (its `*_module` fields should be `resolve_tiers`-derived, §A.2).
/// - Return: `Ok(b)` for a coherent binding, `Error(SafeForbidsNif)` for `Safe + Nif`,
///   `Error(TierModuleMismatch)` for a `mem_module` that disagrees with its `mem_tier`. Total.
pub fn validate_binding(b: Binding) -> Result(Binding, LinkError) {
  case b.mode, b.mem_tier, b.mem_module == mem_module_for(b.mem_tier) {
    Safe, Nif, _ -> Error(SafeForbidsNif)
    _, _, False -> Error(TierModuleMismatch)
    _, _, True -> Ok(b)
  }
}
```

The gate is deliberately **narrow** (G6 mandates Safe-forbids-nif; P5 adds only the load-bearing
`mem_module`↔`mem_tier` coherence check — "every other composition is admitted", keystone §B.4). It
does **not** second-guess anything else about the tier↔module pairing beyond the one agreement
`emit_core` depends on: producing that coherence is `resolve_tiers`'s job (§A.2), enforcing it is
this gate's. A Safe hand-build that sets only `mem_tier: Nif` (leaving `mem_module` stale at
`rt_mem`) is caught by the Safe+Nif clause; a hand-build that sets `mem_tier: Atomics` without
re-resolving `mem_module` is caught by `TierModuleMismatch` — either way fail-closed on the
declared intent, before it can link.

### D.3 Wiring the gate — `link/1` is the sole seam; `instantiate/1` self-validates

The keystone asked unit 07 to "wire [the gate] into `instantiate`". Reconciled with P5:
**`link/1` is the sole `Binding → Instance` seam** — `validate_binding ∘ resolve_tiers ∘
instantiate` — and it is the *only* path unit 08's run-ABI/CLI and the profile constructors use to
turn a `Binding` into an `Instance`. `instantiate/1` keeps its total `Binding -> Instance`
signature (making it return `Result` would break **every** Phase-1/2/3 caller, a cross-file reach
D1 forbids), but it is no longer relied on *by convention* to be safe: it is made
**self-validating** — its body asserts the coherence invariant fail-closed, so the *unconstructible*
Safe+Nif (§D.1) can never silently yield a `rt_mem_nif`-linked `Instance` under Safe. The graceful
`Result` path is `link/1`; the assertion is defense-in-depth so even a direct `instantiate/1` call
cannot fail **open** (P5 — the ungated call is otherwise the path of least resistance):

```gleam
import gleam/result

/// The **sole** `Binding → Instance` seam (P5): validate `binding` fail-closed (§D.2), re-derive
/// its tier modules with `resolve_tiers` (§A.2 — the single coherent coupling, so `emit_core` links
/// the atom the declared tier names), then assemble the `Instance`. Every run-ABI/CLI/profile
/// caller routes through here; there is no other sanctioned path from a `Binding` to an `Instance`.
/// The profile constructors are already structurally valid (§D.1), so `link(portable())`/
/// `link(ceiling())`/`link(safe())` always succeed; only a hand-built `Safe + Nif` (or a
/// `mem_module` that disagrees with its `mem_tier`) yields an `Error`.
///
/// - `binding`: the build-time profile to link.
/// - Return: `Ok(Instance)` for a coherent binding, `Error(SafeForbidsNif)` for `Safe + Nif`,
///   `Error(TierModuleMismatch)` for a stale/incoherent `mem_module`. `instantiate/1` keeps its
///   total `Binding -> Instance` signature (Phase-1/2/3 contract, many callers) but is
///   self-validating, so even a direct call cannot fail open. Total in the `Result` sense.
pub fn link(binding: Binding) -> Result(Instance, LinkError) {
  binding
  |> validate_binding
  |> result.map(resolve_tiers)
  |> result.map(instantiate)
}
```

Unit 08 routes **every** `Binding → Instance` through `link/1` at the CLI/pipeline
profile-selection seam (where a `--portable`/`--ceiling` flag or a hand-built binding first
enters), surfacing the `LinkError` as a `PipelineError` — the rejection reaches the user before any
`.beam` is emitted — and proves `link/1` is the sole seam (no caller reaches `instantiate/1`
directly). *(Reconciled with the keystone: "wire into `instantiate`" is realised as the
self-validating `instantiate/1` **plus** `link/1` as the sole graceful seam, NOT a `Result`
signature change to `instantiate/1`, which would reach unit 08's files and break coexistence
callers.)*

---

## E. Fail-closed defaults preserved — no accidental Unsafe/Nif by omission (D4/D9)

The Phase-3 opt-in property extends cleanly to the tier axis. The full fail-closed enumeration
after this unit:

| Constructor | `mode` | `state_strategy` | `mem_tier` | Node-safe? |
|---|---|---|---|---|
| `safe()` / `safe_default()` | `Safe` | `Cell` | `Paged` | yes (tier-P/O) |
| `safe_capped(n)` / `safe_metered(n)` | `Safe` | `Cell` | `Paged` | yes |
| `portable()` | `Safe` | `Threaded` | `Paged` | yes (tier-P everything) |
| `unsafe()` | `Unsafe` | `Cell` | `Paged` | yes (posture, not tier) |
| `ceiling()` | `Unsafe` | `Cell` | `Atomics` | yes (tier-O, no native code) |

- **Leaving Safe requires naming `unsafe()`/`ceiling()`** (the only two `mode: Unsafe`
  constructors); **reaching tier-N `Nif` requires an explicit Unsafe composition** (§C). No
  accidental Unsafe or NIF by omission; `Safe + Nif` is unconstructible (§D.1) and rejected (§D.2).
- **The resource-bound channels (E3 `safe_capped`, F5 `safe_metered`) are orthogonal to the tier
  axis** and unchanged; a *capped, threaded, portable* build is just `Binding(..portable(),
  fuel_budget: b, safe_max_pages: p)`. The axes compose by record-spread — no
  `unsafe_capped`/`portable_capped` constructor-per-point proliferation.

---

## Effect / soundness / security note

- **Fail-closed default survives both tier axes (D4/D9, G6).** `safe_default()` is
  `Cell`/`Paged`/`TablePaged` — maximally node-safe. Every `safe*` constructor and `portable()`
  stay Safe + tier-P/O; `unsafe()`/`ceiling()` are the only Unsafe paths; `Nif` needs an explicit
  Unsafe composition. `Safe + Nif` is unconstructible (§D.1) and, if hand-built, rejected (§D.2) —
  no posture and no tier is acquired by omission.
- **No ambient authority (D3a).** The linker adds **no** data-driven dispatch: a tier is a
  build-controlled module atom resolved by a literal `case` (§A.1), `validate_binding` is a pure
  predicate over build-time fields (`mode`, `mem_tier`, `mem_module`), `resolve_tiers`/`compose`
  only rebind fields. Generated code still calls fixed
  `twocore@runtime@*` atoms (G5); a tier switch swaps the *module atom* the seam links, never an
  `apply(Mod, F, Args)` with `Mod` from program data.
- **Tier-N is the one native seam, gated to Unsafe (G6).** Bounds-checks hold in every tier;
  tiers P/O are memory-safe by construction; tier-N runs custom C and is Safe-forbidden.
  `portable()` links *zero* native or OTP-native state, so its worst case is a node-safe process
  crash, never a host escape. `ceiling()`'s `Atomics`/`TableAtomics` are used **process-locally,
  never shared** (one instance = one process, spec
  [§4.2](https://webassembly.github.io/spec/core/exec/runtime.html) — the store is per-instance) —
  threads / shared memory stay a hard non-goal.
- **Conformance-neutral (G7), floats-as-bits (D5) unchanged.** No IR node, no `TrapReason`, no
  grammar change, no codegen touched: `safe()`/`unsafe()` and the default `cell`/`paged` path are
  byte-identical to Phase 3. The new profiles are build-time descriptors; the behaviour they
  select is proven byte-identical by units 09/11's tier differential. Profiles select `bif`
  numerics (`num_module` inherited); none round-trips a float through a BEAM double.

---

## Verification (Definition of Done)

Spec-cited, behaviour-asserting tests (no change-detectors, D8) — assert against the **G-decisions
and the WASM spec**, not the constructor bodies. "Done" = **the suite passes**, not "it compiles".
Owned test file: `test/twocore/runtime/profiles_test.gleam` (extends the Phase-3 + keystone seed).

1. **`portable()` is tier-P everything (G3).** Assert `portable().state_strategy == Threaded`,
   `.mem_tier == Paged`, `.table_tier == TablePaged`, `.mode == Safe`, and that its
   `mem_module`/`table_module`/`num_module` and all five Safe policy fields
   (`Baseline`/`MeterFuel`/`BifAllowlist`/`StdlibOwn`/`HostDenyAll`) are **identical to `safe()`**
   (the tier-P memory modules are `safe_default()`'s own atoms; only the *state strategy* differs).
   `validate_binding(portable()) == Ok(portable())`.
2. **`ceiling()` is the perf posture (G3/G8).** Assert `ceiling().mode == Unsafe`,
   `.state_strategy == Cell`, `.mem_tier == Atomics`, `.mem_module == mem_module_for(Atomics)`
   (`"twocore@runtime@rt_mem_atomics"`), `.table_tier == TableAtomics`, and the full aggressive
   posture inherited from `unsafe()` (`Aggressive`/`MeterOff`/`BifOpen`/`StdlibPassthrough`/
   `HostOpen`). `validate_binding(ceiling()) == Ok(ceiling())` (Unsafe admits tier-O).
3. **Safe+Nif is unconstructible AND rejected (G6, §D).** Enumerate every Safe constructor —
   `safe()`, `safe_capped(n)` (any `n`), `safe_metered(n)` (any `n`), `safe_default()`,
   `portable()` — and assert **none** has `mem_tier == Nif`. Then assert
   `validate_binding(Binding(..safe(), mem_tier: Nif)) == Error(SafeForbidsNif)` (the hand-built
   defensive path fails closed), and that `link(Binding(..safe(), mem_tier: Nif))` is
   `Error(SafeForbidsNif)`.
4. **Every P/O composition is admitted; only Safe+Nif rejected (§D.2).** `validate_binding` is
   `Ok` for Safe+`Paged`, Safe+`Atomics` (tier-O in Safe — the node-safe O(1) win), Unsafe+`Paged`,
   Unsafe+`Atomics`, Unsafe+`Nif` (= `compose(ceiling(), Cell, Nif, TableAtomics)`, the tier-N
   ceiling). `mem_module_for`/`table_module_for` map each tier to the keystone §B.1 atom, with the
   tier-P arms equal to `safe_default()`'s strings (no re-spell).
5. **`resolve_tiers` is the single coherent coupler; the gate guards the load-bearing field (P5,
   §A.2/§D.2).** Assert `resolve_tiers(Binding(..unsafe(), mem_tier: Atomics)).mem_module ==
   mem_module_for(Atomics)` and that `resolve_tiers` is idempotent (`resolve_tiers(resolve_tiers(b))
   == resolve_tiers(b)`) and leaves every policy field of `b` untouched. Assert a *stale* hand-build
   — `Binding(..unsafe(), mem_tier: Atomics)` with `mem_module` left at `rt_mem` — is
   `Error(TierModuleMismatch)`, and that `resolve_tiers` of it then validates `Ok`. Assert
   `compose(base, …)` and `link(_)` funnel through `resolve_tiers` (a composed/linked binding's
   `mem_module` always `== mem_module_for(mem_tier)`), so `link` is `validate_binding ∘ resolve_tiers
   ∘ instantiate` and is the sole `Binding → Instance` seam.
6. **`safe()`/`unsafe()` valid + `compose` policy-preserving (D4/D9, §A.2).** Every `safe*`
   constructor is the full Safe posture with `Cell`/`Paged`/`TablePaged`; `unsafe()` is `Unsafe` +
   `Cell`/`Paged`/`TablePaged`; `unsafe()`/`ceiling()` are the **only** `mode == Unsafe`
   constructors (Phase-3 enumeration unperturbed). `compose(safe(), Threaded, Paged, TablePaged)
   == portable()`, and `compose(base, …)` leaves every policy field of `base` unchanged for
   `base ∈ {safe(), unsafe()}`.
7. **Doc comments on every public function**; `////` module doc updated to name the two profiles
   and the composition axis. `gleam format --check src test` clean; `gleam build` **zero
   warnings**; `gleam test` green with the full suite; **conformance `fail=0` under both profiles**
   (conformance-neutral, G7). When a bug is found, add the failing spec-cited test first, then fix.

---

## What this unit leaves

- **Unit 08 (pipeline + CLI)** selects `portable()`/`ceiling()` (and any `compose`d point) per a
  CLI `--profile` flag, runs `resolve_tiers` on the flag-composed binding so a `--tier atomics`
  build actually links `rt_mem_atomics`, and routes **every** `Binding → Instance` through `link/1`
  at the profile-selection seam (surfacing the `LinkError` as a `PipelineError`) — the sole seam
  where the fail-closed gate is enforced end-to-end.
- **Unit 11 (capstone)** runs the every-`(strategy × tier)` conformance proof (`fail=0`,
  byte-identical results) using these named profiles, proves the **runs-anywhere** property of
  `portable()` (grep the emitted `.beam` for zero `atomics`/`ets`/`persistent_term`/NIF **and zero
  `rt_state` `seed`/`get`/`put` — the instance-state cell — but *not* zero pdict, since the
  node-safe tier-O fuel/host policy overlays legitimately use it, P4), and re-measures the honest
  benchmark with `ceiling()`'s `atomics` memory (over a bounded cap, §C).
- **Open — coexistence of same-mode, different-strategy builds.** `coexist_name/2` (this file,
  Phase-3) keys the distinct output atom on `mode` only, so a `safe()` (cell) and a `portable()`
  (threaded) build of *one* source collide under the same atom (both `Safe`). A `Threaded` and a
  `Cell` build are different `.beam`s (the calling convention differs, G1/B3), so a capstone that
  wants both live on one node needs a strategy-aware suffix. Flagged to unit 08 / the keystone —
  not extended here (changing `coexist_name/2`'s frozen signature would reach the capstone's
  callers).
- **Deferred, stated (G8):** the tier-N `Nif` profile is Unsafe-composition-only and its C impl
  may be documented-deferred (unit 05); the single-`.beam` runtime-dispatch **B1** binding stays
  deferred — `state_strategy`/`mem_tier` are compile-time (B3), so a profile is a distinct `.beam`,
  exactly as Phase 3 established for Safe/Unsafe.
