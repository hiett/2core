//// Security tests for `rt_host` (unit 09) — the deny-all capability boundary.
////
//// The asserted property is **fail-closed** (D4/D9): for any `(capability, name, args)`,
//// `call_host` rejects — it never returns a value and never silently succeeds. We catch
//// the error-class `{capability_denied, Cap, Name}` via the namespace-hygienic
//// `twocore_rt_test_ffi` helper and confirm the denial echoes which capability/name was
//// rejected. These are *negative* tests: success means rejection.

import gleeunit/should
import twocore/runtime/rt_host

/// Run `action`; returns `Ok(#(capability, name))` only when it raises the error-class
/// `{capability_denied, Cap, Name}`, else `Error(description)` (e.g. if it returned).
@external(erlang, "twocore_rt_test_ffi", "host_denial")
fn host_denial(action: fn() -> a) -> Result(#(String, String), String)

pub fn denies_empty_args_test() {
  host_denial(fn() { rt_host.call_host("fs", "open", []) })
  |> should.equal(Ok(#("fs", "open")))
}

pub fn denies_with_args_test() {
  host_denial(fn() { rt_host.call_host("net", "connect", [1, 2, 3]) })
  |> should.equal(Ok(#("net", "connect")))
}

/// A different capability/name is *also* denied — there is no privileged string.
pub fn denies_arbitrary_capability_test() {
  host_denial(fn() { rt_host.call_host("anything", "at_all", ["payload"]) })
  |> should.equal(Ok(#("anything", "at_all")))
}

/// The empty capability and empty name are denied too (no "blank = allowed" hole).
pub fn denies_empty_strings_test() {
  host_denial(fn() { rt_host.call_host("", "", []) })
  |> should.equal(Ok(#("", "")))
}

/// Cross-check: a spread of inputs all reject (never returns an `Error` from the helper,
/// which would mean `call_host` returned or raised the wrong class/shape).
pub fn always_denies_spread_test() {
  let denied = fn(cap: String, name: String) -> Bool {
    case host_denial(fn() { rt_host.call_host(cap, name, []) }) {
      Ok(_) -> True
      Error(_) -> False
    }
  }
  { denied("clock", "now") && denied("rand", "bytes") && denied("env", "get") }
  |> should.equal(True)
}
