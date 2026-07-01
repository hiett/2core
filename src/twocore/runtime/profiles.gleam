//// Unit 11b — named runtime **profiles** + the thin `rt_instance` linker (high-level
//// §6/§13). Phase 1 ships exactly ONE profile, **Safe**, and it is fail-closed: there is
//// no constructor in this file that yields an `Unsafe` binding or relaxes the host/BIF
//// posture (the Unsafe profile — aggressive optimizer, passthrough stdlib, open BIFs — is
//// Phase 2, D9).
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
import twocore/runtime/instance.{
  type Binding, type Mode, Binding, Safe, safe_default,
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
