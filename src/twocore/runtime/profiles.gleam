//// Unit 11b — named runtime **profiles** + the thin `rt_instance` linker (high-level
//// §6/§13). The **Safe** profile is the fail-closed default; Phase 3 adds the **Unsafe**
//// profile (`unsafe()`) as an EXPLICIT, TESTED opt-in (F4). There is no path to an Unsafe
//// posture by omission (D4/D9): `safe()`/`safe_capped()`/`safe_default()`/`safe_instance()`
//// all stay Safe, and only `unsafe()` yields `mode: Unsafe` (the aggressive optimizer, no
//// metering, open BIF gate, passthrough stdlib, open host).
////
//// A *profile* is a build-time `Binding` (the calling convention, `runtime/instance.gleam`)
//// carrying the vetted `twocore@runtime@rt_*` impl module names. A *linker* assembles a
//// runnable `Instance` from a profile. Phase 1 is thin: a Phase-1 instance carries only its
//// binding because generated functions are pure and thread no mutable state (D3d); Phase 2
//// adds memory/table/global handles here, a clean extension because the binding chokepoint
//// already exists.
////
//// ## Single-owner rule (D1)
////
//// This module **imports** `instance.gleam` and never edits it. The vetted impl module
//// names live in exactly one place — `instance.safe_default()` — so the `twocore@runtime@*`
//// strings are never re-spelled here.
////
//// ## Honest scope (D9)
////
//// `instantiate` records the chosen binding; it is the *seam* a Phase-2 linker will grow
//// into (loading/resolving the runtime modules, allocating memory/tables). Phase 1 does not
//// claim a full sandbox — it wires and exercises the Safe-mode seams end-to-end.

import gleam/int
import twocore/middle/ir_opt.{Aggressive}
import twocore/runtime/instance.{
  type Binding, type Mode, Atomics, BifOpen, Binding, Cell, HostOpen, MeterOff,
  Nif, Paged, Safe, StdlibPassthrough, Threaded, Unsafe, safe_default,
}

/// The Safe-profile **hard cap** on linear-memory pages (E3) — the single source of the
/// Safe max-pages policy. A FINITE value that applies even when a module declares
/// `max_pages: None`, so untrusted code cannot allocate unboundedly: `memory.grow` past the
/// effective max returns `-1` and allocates nothing, and `grow` charges fuel proportional to
/// the bytes allocated. The effective memory max baked at seed time is
/// `min(declared_max ?? safe_max_pages(), safe_max_pages(), 65536)`.
///
/// Returns `65536` (= 2¹⁶ pages = the i32 4 GiB address-space cap). At this value the
/// module's DECLARED max governs for the spec suite (so conformance `memory.grow` semantics
/// match the spec); `profiles.safe()` uses exactly this. The acceptance `grow`-cap proof
/// uses `safe_capped` to LOWER it (never above this hard cap — fail-closed). Total.
pub fn safe_max_pages() -> Int {
  65_536
}

/// The named **Safe** profile: the build-time `Binding` carrying the vetted
/// `twocore@runtime@rt_*` impl module names (units 09/10) — memory/table/state layers wired
/// + the Safe max-pages cap (`safe_max_pages()`). This is the fail-closed default (deny-all
/// host, allowlisted BIFs, metering, bounds-checked memory). Total — never fails. There is
/// deliberately no `unsafe()` here: a caller cannot obtain an unsafe posture from this
/// module (D4/D9), and `safe_capped` can only LOWER the page cap, never lift it.
pub fn safe() -> Binding {
  safe_default()
}

/// A Safe `Binding` whose linear-memory cap is LOWERED to `max_pages` pages — used to prove
/// the resource bound fires (a module declaring no max that grows past `max_pages` gets `-1`
/// from `memory.grow` and allocates nothing, E3).
///
/// - `max_pages`: the desired cap in 64 KiB pages. **Fail-closed:** it is clamped to
///   `[0, safe_max_pages()]`, so a value above the 65536-page hard cap cannot LIFT the cap —
///   `profiles` exposes no way to exceed `safe_max_pages()`. A value `≤ 0` clamps to `0` (no
///   growth at all).
/// - Returns a `Safe`-mode `Binding` identical to `safe()` except for the lower
///   `safe_max_pages` field (which `emit_core` bakes into the `rt_mem:fresh` seed). Total.
pub fn safe_capped(max_pages: Int) -> Binding {
  let capped = int.max(0, int.min(max_pages, safe_max_pages()))
  Binding(..safe_default(), safe_max_pages: capped)
}

/// A Safe profile with a LOWERED per-instance CPU-fuel budget (F5) — the CPU analogue of
/// `safe_capped(max_pages)`. `instantiate/0` bakes `seed_fuel(binding.fuel_budget)` (unit 09
/// §A.4), so a smaller `budget` traps a runaway loop sooner with `FuelExhausted`. This is the
/// single per-instance channel for the CPU bound (unit 11's runaway-loop trap proof passes a
/// SMALL budget through here).
///
/// - `budget`: the per-instance CPU-fuel seed, in `charge` units. Any `Int`; a smaller value
///   exhausts sooner. Passed VERBATIM (no clamping) — it is a resource bound the caller
///   chooses, never a way to WIDEN the posture. A non-positive budget seeds an already-
///   exhausted instance (it traps on the first `charge`); that is a caller choice, not a
///   posture change.
/// - Returns a `Safe`-mode `Binding` identical to `safe()` except for the lowered
///   `fuel_budget` field — `mode: Safe` and all five Safe policy fields
///   (`Baseline`/`MeterFuel`/`BifAllowlist`/`StdlibOwn`/`HostDenyAll`) are unchanged.
///
/// Fail-closed (D4/D9): it can only set the budget on a Safe posture. There is deliberately no
/// `unsafe_metered` — `MeterOff` seeds no budget, so there is nothing to lower. Total — never
/// fails.
pub fn safe_metered(budget: Int) -> Binding {
  Binding(..safe(), fuel_budget: budget)
}

/// The named **Unsafe** profile (F4) — the platform's second named mode, the aggressive
/// posture in one value: the aggressive optimizer, no CPU metering, the open BIF gate,
/// passthrough stdlib, and the open host, while keeping the **identical**
/// `twocore@runtime@rt_*` runtime module names as `safe()` (the runtime CODE is shared; the two
/// profiles are distinct B3 builds and the instance is the unit of policy).
///
/// Posture, field by field (asserted against F4, not against this body):
/// - `mode: Unsafe` — the ONLY constructor here that yields it.
/// - `opt_level: Aggressive` — baseline + Unsafe-only passes (unit 04).
/// - `meter: MeterOff` — `ir_lower` inserts NO `Charge` nodes (F5 zero-overhead), so
///   `FuelExhausted` is unreachable in an Unsafe instance.
/// - `bif_gate: BifOpen` — admits the resolver's build-controlled targets (never arbitrary
///   ambient BIFs, D3a).
/// - `stdlib: StdlibPassthrough` — routes shared functions to BEAM stdlib where trusted;
///   observably identical to `own` (unit 06).
/// - `host_policy: HostOpen` — all host imports permitted (still no data-driven `apply`, D3a).
///
/// The `Aggressive ⟹ MeterOff` coupling holds (only `Baseline`/`OptNone` may pair with
/// `MeterFuel`), so the Unsafe-only passes run over a provably metering-free module.
///
/// **Inherited unchanged from `safe_default()` (the spread carries them):**
/// - `safe_max_pages: 65536` — the i32 4 GiB address-space bound (2¹⁶ pages) is a **WASM
///   invariant** (spec §2.5.4 / §4.2.8), NOT a sandbox lever. Unsafe keeps it: there is
///   deliberately no `unsafe_capped`, and `memory.grow` past 2¹⁶ pages still returns `-1`.
///   Unsafe does not grant unbounded memory (that is the deferred Phase-4 `rt_mem` tier).
/// - `fuel_budget` — harmless under `MeterOff` (no `Charge`, no `seed_fuel` emitted).
///
/// **Fail-closed (D4/D9):** this is the ONLY constructor in `profiles` yielding `mode: Unsafe`.
/// `safe()`/`safe_capped(_)`/`safe_metered(_)`/`safe_default()`/`safe_instance()` are all fully
/// Safe; Gleam has no default field values, so an Unsafe posture requires NAMING this
/// constructor. Total — never fails.
pub fn unsafe() -> Binding {
  Binding(
    ..safe_default(),
    mode: Unsafe,
    opt_level: Aggressive,
    meter: MeterOff,
    bif_gate: BifOpen,
    stdlib: StdlibPassthrough,
    host_policy: HostOpen,
  )
}

/// A runnable instance assembled by the linker (`rt_instance`, high-level §13).
///
/// Phase 1 is intentionally thin: it carries only the `binding` (the resolved runtime
/// layer module names). There is **no mutable instance state** in Phase 1 — no memory,
/// tables, or mutable globals in the op set — so generated functions are pure and thread
/// nothing (D3d). Phase 2 grows this record with memory/table/global handles.
///
/// - `binding`: the build-time `Binding` this instance runs against.
pub type Instance {
  Instance(binding: Binding)
}

/// Assemble a runnable `Instance` from a `binding` (the linker step).
///
/// - `binding`: the build-time profile (e.g. `safe()`). Its `*_module` fields name the
///   `twocore@runtime@*` modules generated code will call; they are loaded into the build
///   VM as ordinary BEAM modules (overview D10), so no per-instance resolution is needed in
///   Phase 1.
///
/// Returns an `Instance` wrapping `binding`. Total — never fails; Phase-1 instantiation has
/// no failure mode because there is no mutable state to allocate. (Phase 2's memory/table
/// allocation introduces the first `Result` failure mode here — a clean extension.)
pub fn instantiate(binding: Binding) -> Instance {
  Instance(binding: binding)
}

/// Convenience: the runnable Safe instance — `instantiate(safe())`. The one-call path the
/// CLI/acceptance use to link the default profile. Total.
pub fn safe_instance() -> Instance {
  instantiate(safe())
}

/// Convenience: the runnable Unsafe instance — `instantiate(unsafe())`. The one-call path a
/// caller uses to link the Unsafe profile, mirroring `safe_instance()`.
///
/// Being the SOLE Unsafe convenience keeps the fail-closed guarantee legible: an author must
/// NAME `unsafe`/`unsafe_instance` to leave Safe (`is_safe(unsafe_instance()) == False`,
/// `mode(unsafe_instance()) == Unsafe`). `instantiate/1`/`mode/1`/`is_safe/1` are unchanged —
/// they read the binding, so they carry the Unsafe posture through with no edit. Total — never
/// fails.
pub fn unsafe_instance() -> Instance {
  instantiate(unsafe())
}

/// The execution `Mode` an instance realises (`Safe` for every Phase-1 instance).
///
/// - `inst`: the instance to inspect.
/// - Return: `inst.binding.mode`. Provided so a fail-closed test can assert an instance is
///   Safe without reaching into the binding record. Total.
pub fn mode(inst: Instance) -> Mode {
  inst.binding.mode
}

/// Whether `inst` is in the fail-closed Safe posture.
///
/// - `inst`: the instance to inspect.
/// - Return: `True` iff `inst.binding.mode == Safe`. Phase 1 always returns `True` (the
///   only profile is Safe); the predicate exists so the Phase-2 Unsafe profile is an
///   explicit, tested opt-out rather than an accident. Total.
pub fn is_safe(inst: Instance) -> Bool {
  inst.binding.mode == Safe
}

/// Derive a DISTINCT output module name for a coexisting build of the same source module
/// (§B.5/B3), so any two `.beam`s of ONE source that differ in build identity can load together
/// on one node without an atom clash. Two `.beam`s cannot load under the same module atom, and a
/// name collision hot-replaces (clobbers) the earlier module; the generated atom is
/// `ir.Module.name`, so the linker gives the builds distinct names before `emit_core`.
///
/// A build's identity is the triple `(mode, state_strategy, mem_tier)` — two builds that differ
/// in ANY of these are different `.beam`s (the calling convention and the linked `rt_*` module
/// differ, G1/B3), so `safe()` (cell) and `portable()` (threaded) — **both `Safe`** — must NOT
/// collide. The atom keys on all three, appending suffixes in a FIXED order:
///
/// - `mode`: `Unsafe` appends `_unsafe`; `Safe` appends nothing.
/// - `state_strategy`: `Threaded` appends `_threaded`; `Cell` appends nothing.
/// - `mem_tier`: `Atomics` appends `_atomics`, `Nif` appends `_nif`; `Paged` appends nothing.
///
/// The default posture (`Safe`/`Cell`/`Paged`) appends NOTHING — the atom is the canonical
/// `base`, byte-identical to Phase-2/3 (conformance-neutral, G7), so every existing coexistence
/// assertion still holds. Any two distinct-identity builds derive distinct atoms.
///
/// - `base`: the source module's canonical name (its `ir.Module.name`).
/// - `binding`: the build's `Binding`; only `mode`/`state_strategy`/`mem_tier` are read.
/// - Returns the derived module-name string. PURE string derivation — introduces no policy.
///   Total — never fails.
pub fn coexist_name(base: String, binding: Binding) -> String {
  let mode_suffix = case binding.mode {
    Safe -> ""
    Unsafe -> "_unsafe"
  }
  let state_suffix = case binding.state_strategy {
    Cell -> ""
    Threaded -> "_threaded"
  }
  let tier_suffix = case binding.mem_tier {
    Paged -> ""
    Atomics -> "_atomics"
    Nif -> "_nif"
  }
  base <> mode_suffix <> state_suffix <> tier_suffix
}
