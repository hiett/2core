//// `rt_stdlib` — the minimal Safe `own` standard library. Tiny + auditable by design (D9).
////
//// The positive path of the capability boundary: unit 11's `ir_lower` recognises a
//// `CallHost(capability, name)` that maps to an `own`-stdlib entry, gates the resolved
//// BEAM target through `rt_bif.check`, and rewrites it into a direct call into this
//// module — `call 'twocore@runtime@rt_stdlib':'<fn>'(Args…)`. A vetted stdlib call does
//// **not** go through the deny-all host.
////
//// Phase 1 ships a single vetted function (`gcd`) to exercise that positive path
//// end-to-end. Breadth (and the `passthrough` Unsafe stdlib) is deferred to Phase 2 (D9).
//// Everything here must be **tier-P**: pure, total, no host access, cannot crash the node.
////
//// ## Coordination (the `(capability, name)` → fn map)
////
//// The mapping from an IR `CallHost(capability, name)` to this module's functions is
//// owned by unit 11's `ir_lower` (the rewrite) and unit 08 (the emit). The suggested
//// Phase-1 entry is `(capability: "std", name: "gcd")` → `rt_stdlib:gcd/2`, whose BEAM
//// target `("twocore@runtime@rt_stdlib", "gcd", 2)` is on the `rt_bif` allowlist.

import gleam/int

/// The greatest common divisor of `a` and `b`, by the Euclidean algorithm.
///
/// Spec/definition (mathematics, not the implementation): `gcd` is the largest
/// non-negative integer dividing both arguments, with the conventions `gcd(n, 0) = |n|`,
/// `gcd(0, n) = |n|`, and `gcd(0, 0) = 0`.
///
/// - `a`, `b`: any integers (BEAM bignums; negatives are handled — the result is the
///   non-negative gcd of their magnitudes).
/// - Return: the gcd as a non-negative `Int`. Total — never traps, never raises, no host
///   access. Tail-recursive, so it runs in constant stack space.
pub fn gcd(a: Int, b: Int) -> Int {
  case b {
    0 -> int.absolute_value(a)
    _ -> gcd(b, a % b)
  }
}
