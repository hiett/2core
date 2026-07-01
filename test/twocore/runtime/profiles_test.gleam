//// Unit 11b tests — the Safe profile + thin linker, asserted FAIL-CLOSED (D4/D9): the only
//// profile is Safe, it carries exactly the vetted `twocore@runtime@rt_*` modules, and there
//// is no API here that yields an unsafe posture.

import gleam/list
import twocore/middle/ir_opt.{Aggressive, Baseline}
import twocore/runtime/instance.{
  BifAllowlist, BifOpen, Binding, HostDenyAll, HostOpen, MeterFuel, MeterOff,
  Safe, StdlibOwn, StdlibPassthrough, Unsafe,
}
import twocore/runtime/profiles

/// The Safe profile is in `Safe` mode — the fail-closed posture (D9).
pub fn safe_profile_is_safe_mode_test() {
  assert profiles.safe().mode == Safe
}

/// The Safe profile carries EXACTLY the vetted `twocore@runtime@rt_*` impl module names
/// (the single source of truth is `instance.safe_default()`; this profile must not re-spell
/// or diverge from it — D1).
pub fn safe_profile_modules_are_vetted_test() {
  assert profiles.safe() == instance.safe_default()
}

/// The Safe profile's chokepoint module names are the pinned `twocore@runtime@*` set (the
/// Gleam→Erlang-mangled names generated code calls — D2). Asserted explicitly so a typo in
/// `safe_default` would be caught here too.
pub fn safe_profile_module_names_test() {
  let b = profiles.safe()
  assert b.num_module == "twocore@runtime@rt_num"
  assert b.trap_module == "twocore@runtime@rt_trap"
  assert b.host_module == "twocore@runtime@rt_host"
  assert b.meter_module == "twocore@runtime@rt_meter"
  assert b.stdlib_module == "twocore@runtime@rt_stdlib"
}

/// The linker assembles a runnable instance from the Safe profile, and that instance is in
/// the Safe posture (`is_safe`/`mode`). Phase-1 instances are thin — they carry only the
/// binding (no mutable state, D3d).
pub fn instantiate_links_safe_instance_test() {
  let inst = profiles.instantiate(profiles.safe())
  assert inst.binding == instance.safe_default()
  assert profiles.is_safe(inst)
  assert profiles.mode(inst) == Safe
}

/// `safe_instance()` is the one-call linker path and is equivalent to
/// `instantiate(safe())`.
pub fn safe_instance_convenience_test() {
  assert profiles.safe_instance() == profiles.instantiate(profiles.safe())
}

/// Fail-closed (the negative property): the linker cannot be coaxed into an unsafe posture
/// through this module's API — every instance it produces is Safe. (The Unsafe profile is
/// Phase 2; there is deliberately no constructor for it here.)
pub fn linker_cannot_produce_unsafe_test() {
  // The only profile constructor is `safe()`, and the only linker entry is `instantiate`.
  assert profiles.is_safe(profiles.instantiate(profiles.safe()))
  assert profiles.is_safe(profiles.safe_instance())
}

/// The Safe max-pages cap is FINITE and never exceeds the 65536-page (4 GiB) i32 hard cap
/// (E3): untrusted code cannot allocate unboundedly. `profiles.safe()` bakes exactly this
/// value into its `Binding`, so the module's declared max governs for the spec suite.
pub fn safe_max_pages_is_finite_test() {
  assert profiles.safe_max_pages() > 0
  assert profiles.safe_max_pages() <= 65_536
  assert profiles.safe().safe_max_pages == profiles.safe_max_pages()
}

/// `safe_capped` can only LOWER the cap (fail-closed): a request ABOVE the hard cap is
/// clamped DOWN to `safe_max_pages()` — there is no way to lift the cap above the hard
/// limit. A negative request clamps to 0 (no growth). The posture stays Safe.
pub fn safe_capped_cannot_lift_cap_test() {
  // A low request is honoured verbatim (the resource-bound use).
  assert profiles.safe_capped(1).safe_max_pages == 1
  // An over-cap request is clamped to the hard cap — never lifted above it.
  assert profiles.safe_capped(1_000_000).safe_max_pages
    == profiles.safe_max_pages()
  // A negative request clamps to 0.
  assert profiles.safe_capped(-5).safe_max_pages == 0
  // Every capped Binding remains Safe (fail-closed) and otherwise identical to `safe()`.
  assert profiles.safe_capped(1).mode == Safe
  assert profiles.safe_capped(1).num_module == profiles.safe().num_module
}

// ───────────────────────────── Phase-3 fail-closed opt-in (F4/§B.4) ─────────────────────────────

/// Every Safe-family constructor (`safe`, `safe_capped`, `safe_default`, `safe_instance`) is
/// the FULL fail-closed Safe posture across the Phase-3 policy fields (D4/D9): mode `Safe`,
/// `Baseline` optimizer, `MeterFuel`, `BifAllowlist`, `StdlibOwn`, `HostDenyAll`. There is no
/// path to an Unsafe field by omission.
pub fn safe_family_is_full_safe_posture_test() {
  let bindings = [
    profiles.safe(),
    profiles.safe_capped(3),
    profiles.safe_metered(1000),
    instance.safe_default(),
    profiles.safe_instance().binding,
  ]
  list.each(bindings, fn(b) {
    assert b.mode == Safe
    assert b.opt_level == Baseline
    assert b.meter == MeterFuel
    assert b.bif_gate == BifAllowlist
    assert b.stdlib == StdlibOwn
    assert b.host_policy == HostDenyAll
  })
}

/// `unsafe()` is the ONLY constructor that yields `mode: Unsafe`, and it is the full aggressive
/// posture (`Aggressive`/`MeterOff`/`BifOpen`/`StdlibPassthrough`/`HostOpen`). Unsafe-by-
/// accident is impossible — it is an explicit, tested opt-in (F4).
pub fn unsafe_is_the_only_unsafe_opt_in_test() {
  // The Safe family is never Unsafe.
  assert profiles.safe().mode != Unsafe
  assert profiles.safe_capped(3).mode != Unsafe
  assert profiles.safe_instance().binding.mode != Unsafe
  // `unsafe()` is Unsafe with the full aggressive posture.
  let u = profiles.unsafe()
  assert u.mode == Unsafe
  assert u.opt_level == Aggressive
  assert u.meter == MeterOff
  assert u.bif_gate == BifOpen
  assert u.stdlib == StdlibPassthrough
  assert u.host_policy == HostOpen
}

/// The `Aggressive ⟹ MeterOff` coupling (§B.5): no shipped constructor pairs `Aggressive`
/// with `MeterFuel` — the illegal pairing is unrepresentable in a profile.
pub fn no_constructor_pairs_aggressive_with_meter_fuel_test() {
  let shipped = [
    profiles.safe(),
    profiles.safe_capped(3),
    profiles.safe_metered(1000),
    instance.safe_default(),
    profiles.safe_instance().binding,
    profiles.unsafe(),
  ]
  list.each(shipped, fn(b) {
    assert !{ b.opt_level == Aggressive && b.meter == MeterFuel }
  })
}

// ───────────────────────────── Unit 10: first-class Unsafe + coexistence seams ─────────────────────────────

/// `unsafe()` has the EXACT aggressive posture asserted field-by-field against F4 (the spec,
/// not the constructor body), AND its shared/inherited fields are IDENTICAL to `safe()`: the
/// `twocore@runtime@rt_*` module names (the runtime code is shared), `safe_max_pages` (the i32
/// hard cap is a WASM invariant, not a sandbox lever — Unsafe keeps it), and `fuel_budget`
/// (inherited but unused under `MeterOff`). Only the six policy fields differ — the instance is
/// the unit of policy.
pub fn unsafe_posture_and_inherited_fields_test() {
  let u = profiles.unsafe()
  let s = profiles.safe()
  // The aggressive posture (F4), field by field.
  assert u.mode == Unsafe
  assert u.opt_level == Aggressive
  assert u.meter == MeterOff
  assert u.bif_gate == BifOpen
  assert u.stdlib == StdlibPassthrough
  assert u.host_policy == HostOpen
  // Inherited-from-safe fields are BYTE-IDENTICAL to `safe()` (shared runtime + WASM caps).
  assert u.num_module == s.num_module
  assert u.trap_module == s.trap_module
  assert u.host_module == s.host_module
  assert u.meter_module == s.meter_module
  assert u.stdlib_module == s.stdlib_module
  assert u.mem_module == s.mem_module
  assert u.table_module == s.table_module
  assert u.state_module == s.state_module
  assert u.safe_max_pages == s.safe_max_pages
  assert u.fuel_budget == s.fuel_budget
}

/// `safe_metered(budget)` lowers ONLY the `fuel_budget` on a Safe posture (F5, the CPU analogue
/// of `safe_capped`): the result equals `safe()` with just `fuel_budget` replaced, so `mode`
/// stays `Safe`, every policy field stays the fail-closed Safe choice, and `safe_max_pages` is
/// unchanged. There is no `unsafe_metered` — the budget can only be set on a Safe posture.
pub fn safe_metered_lowers_only_the_budget_test() {
  // The budget is threaded verbatim.
  assert profiles.safe_metered(1000).fuel_budget == 1000
  assert profiles.safe_metered(0).fuel_budget == 0
  // ONLY the budget changes: equal to `safe()` with `fuel_budget` replaced.
  assert profiles.safe_metered(1000)
    == Binding(..profiles.safe(), fuel_budget: 1000)
  // And it stays fully Safe (posture + page cap unchanged).
  assert profiles.safe_metered(1000).mode == Safe
  assert profiles.safe_metered(1000).meter == MeterFuel
  assert profiles.safe_metered(1000).safe_max_pages
    == profiles.safe().safe_max_pages
}

/// `is_safe` distinguishes at the instance level (§B): `safe_instance()` is Safe,
/// `unsafe_instance()` is not, and `unsafe_instance()` is `Unsafe`. `unsafe_instance()` is
/// equivalent to `instantiate(unsafe())` and is the SOLE Unsafe convenience path.
pub fn is_safe_distinguishes_instances_test() {
  assert profiles.is_safe(profiles.safe_instance())
  assert !profiles.is_safe(profiles.unsafe_instance())
  assert profiles.mode(profiles.unsafe_instance()) == Unsafe
  assert profiles.unsafe_instance() == profiles.instantiate(profiles.unsafe())
  // The instance carries the full Unsafe binding through the linker unchanged.
  assert profiles.unsafe_instance().binding == profiles.unsafe()
}

/// `coexist_name` derives DISTINCT output atoms for builds of one source that differ in build
/// identity (§B.5): the default `safe()` (Safe/Cell/Paged) keeps the canonical `base`, while
/// `unsafe()` appends `_unsafe` — always distinct, the load-time precondition for coexistence
/// (two `.beam`s cannot load under one atom). Pure derivation; no policy.
pub fn coexist_name_gives_distinct_output_atoms_test() {
  assert profiles.coexist_name("m", profiles.safe()) == "m"
  assert profiles.coexist_name("m", profiles.unsafe()) == "m_unsafe"
  // Always distinct for any base.
  assert profiles.coexist_name("m", profiles.safe())
    != profiles.coexist_name("m", profiles.unsafe())
  assert profiles.coexist_name("twocore@x@mod", profiles.safe())
    != profiles.coexist_name("twocore@x@mod", profiles.unsafe())
}
