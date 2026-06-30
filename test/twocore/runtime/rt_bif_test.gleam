//// Fail-closed tests for `rt_bif` (unit 09) — the build-time BEAM-function allowlist gate.
////
//// The asserted property (D4/D9): an allowlisted target passes (`Ok(Nil)`); **everything
//// else fails closed** (`Error(NotAllowlisted(_))`), including a known module/function at
//// the wrong arity. There is no Safe path to `open` — the type/profile simply offers
//// none — so we also assert the allowlist is the small vetted set and nothing dangerous
//// is on it.

import gleam/list
import gleeunit/should
import twocore/runtime/rt_bif.{BifTarget, NotAllowlisted}

/// The resolved `own`-stdlib target `rt_stdlib:gcd/2` is permitted.
pub fn allowlisted_target_passes_test() {
  rt_bif.check(BifTarget("twocore@runtime@rt_stdlib", "gcd", 2))
  |> should.equal(Ok(Nil))
}

/// A non-allowlisted module/function fails closed.
pub fn unknown_target_fails_closed_test() {
  let target = BifTarget("erlang", "halt", 0)
  rt_bif.check(target)
  |> should.equal(Error(NotAllowlisted(target)))
}

/// A dangerous BEAM target (shelling out) is rejected — it is simply absent.
pub fn dangerous_target_fails_closed_test() {
  let target = BifTarget("os", "cmd", 1)
  rt_bif.check(target)
  |> should.equal(Error(NotAllowlisted(target)))
}

/// Right module+function, WRONG arity ⇒ rejected (the triple must match exactly).
pub fn wrong_arity_fails_closed_test() {
  let target = BifTarget("twocore@runtime@rt_stdlib", "gcd", 3)
  rt_bif.check(target)
  |> should.equal(Error(NotAllowlisted(target)))
}

/// `is_allowed` agrees with `check` (allowed) …
pub fn is_allowed_true_test() {
  rt_bif.is_allowed(BifTarget("twocore@runtime@rt_stdlib", "gcd", 2))
  |> should.equal(True)
}

/// … and (denied).
pub fn is_allowed_false_test() {
  rt_bif.is_allowed(BifTarget("erlang", "halt", 0))
  |> should.equal(False)
}

/// The allowlist exposes the vetted set for audit, and it contains the gcd target.
pub fn allowlist_contains_gcd_test() {
  rt_bif.allowlist()
  |> list.contains(BifTarget("twocore@runtime@rt_stdlib", "gcd", 2))
  |> should.equal(True)
}

/// Every entry on the allowlist is itself permitted by `check` (internal consistency).
pub fn allowlist_entries_all_pass_test() {
  rt_bif.allowlist()
  |> list.all(fn(t) { rt_bif.check(t) == Ok(Nil) })
  |> should.equal(True)
}
