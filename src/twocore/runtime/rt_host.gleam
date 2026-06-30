//// `rt_host` — the Safe-mode capability boundary: **deny-all**. Fail-closed (D4/D9).
////
//// `CallHost` is the single IR node for every call that leaves the module's own values
//// (host imports and `own` stdlib alike). Unit 11's `ir_lower` rewrites a *resolved*
//// `own`-stdlib call into a direct `rt_stdlib` call; a *genuine host import* is left as a
//// `call 'twocore@runtime@rt_host':'call_host'(Cap, Name, Args)` (the calling convention
//// in `runtime/instance.gleam`). Under the Safe profile that lands here — and this module
//// **always rejects**.
////
//// ## Fail-closed by construction (a tested property — D4)
////
//// There is no capability string, name, argument, or configuration that makes
//// `call_host` return: it unconditionally raises. Phase 1 ships **only** this deny-all
//// variant — there is no `whitelist`/`open` module to swap in — so the Safe profile
//// cannot be reconfigured into an open posture (deferred to Phase 2, D9). This is the
//// negative path of the capability boundary; unit 11/07 prove a host import is rejected
//// end-to-end through it.
////
//// ## The rejection term shape
////
//// Every call raises the catchable error-class reason `{capability_denied, Cap, Name}`,
//// echoing which capability/name was rejected so the harness can confirm the denial
//// identifies what was denied. Error class (not `throw`/`exit`) so it is catchable the
//// same way traps are.

/// `erlang:error/1` — raises an error-class exception with the given reason and never
/// returns (catchable via `try … catch error:Reason`). Direct BIF reference (tier-P;
/// raises, does not crash the node).
@external(erlang, "erlang", "error")
fn erlang_error(reason: a) -> b

/// The fixed tag of the deny-all rejection reason. As a 0-field Gleam constructor it
/// compiles to the Erlang atom `capability_denied`.
type Tag {
  CapabilityDenied
}

/// The deny-all host dispatcher — **rejects every call**.
///
/// - `capability`: the import's capability group (e.g. the deny-all policy would, in a
///   permissive profile, consult this — here it is only echoed in the rejection).
/// - `name`: the imported function name within the capability (echoed in the rejection).
/// - `_args`: the call arguments. **Ignored** — deny-all inspects nothing; the leading
///   underscore documents that no argument can influence the (always-reject) outcome.
/// - Return: **never returns** — it diverges by raising `{capability_denied, Capability,
///   Name}` (error class). Typed `-> a` (bottom) so the emitter can place the call in any
///   value position.
/// - Failure mode: *always* raises. This is the fail-closed contract, not an error path.
pub fn call_host(capability: String, name: String, _args: List(x)) -> a {
  erlang_error(#(CapabilityDenied, capability, name))
}
