//// Unit 11b tests — the Safe profile + thin linker, asserted FAIL-CLOSED (D4/D9): the only
//// profile is Safe, it carries exactly the vetted `twocore@runtime@rt_*` modules, and there
//// is no API here that yields an unsafe posture.

import twocore/runtime/instance.{Safe}
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
