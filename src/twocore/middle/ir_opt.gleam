//// `middle/ir_opt` — the shared IR→IR optimizer entry point (F1). Owns `optimize/2` +
//// `pipeline/1`; the `Pass` type, its combinators, and the fixpoint driver (`run_pipeline`)
//// live in the leaf module `middle/ir_opt/pass` (imports `ir` ONLY). The import chain stays
//// acyclic — `pass → ir`; `ir_opt → {ir, pass}`; `instance → ir_opt`; `ir_lower → instance`
//// — so nothing here depends on the runtime binding.
////
//// `ir_opt` is a new shared **middle-end** stage between `ir_lower` and `emit_core`. It
//// rewrites the language-neutral IR (frontend-agnostic), so every future frontend inherits it.
//// Its public surface is one entry point (`optimize/2`) plus the ordered pass list per level
//// (`pipeline/1`), the single point units 03/04 register real passes into.

import twocore/ir.{type Module}
import twocore/middle/ir_opt/pass.{type Pass, run_pipeline}

/// The optimization level a build profile selects (F1). `OptNone` is the identity (the
/// Phase-1/2 build path with the optimizer bypassed — the differential baseline of F2).
///
/// **Naming (settled decision).** F1's prose calls the identity level `None`; it is frozen
/// here as the constructor `OptNone` to avoid colliding with `gleam/option.None`, which the
/// files that thread the level (`instance`, `emit_core`, `pipeline`) all import. `Baseline`
/// and `Aggressive` are collision-free and importable unqualified.
///
/// - `OptNone`: run no passes — `optimize` is the exact identity.
/// - `Baseline`: the trust-neutral passes (unit 03).
/// - `Aggressive`: `baseline ++` the Unsafe-only passes (unit 04); a strict superset of
///   `Baseline`. Legal only over a metering-free module (`Aggressive ⟹ MeterOff`, see
///   `optimize`).
pub type OptLevel {
  OptNone
  Baseline
  Aggressive
}

/// Optimize `module` at `level` (F1) — the single public entry point of the stage.
///
/// - `module`: the IR module from `ir_lower`.
/// - `level`: `OptNone` (identity), `Baseline` (trust-neutral passes), or `Aggressive`
///   (baseline + Unsafe-only passes). Read from `binding.opt_level` by the driver (F7).
/// - Return: a **semantics-preserving** rewrite of `module` (F2 — identical returned values by
///   bit pattern per D7, and identical traps, over the whole acceptance corpus + spec suite).
///   Total; never fails and never introduces an unsound rewrite.
///
/// **Precondition (`Aggressive ⟹ MeterOff`).** Calling `optimize` with `Aggressive` over a
/// `Charge`-bearing module is illegal: `Aggressive` may only pair with `MeterOff`, the posture
/// under which `ir_lower` inserts no `Charge` nodes (F5). So a module reaching the `Aggressive`
/// pipeline is provably metering-free — which is what makes unit 04's `Charge`-elision /
/// inlining sound. No shipped profile constructor yields `Aggressive` + `MeterFuel`.
///
/// FREEZE BODY: `run_pipeline(module, pipeline(level))`. At the freeze `pipeline(level)` is
/// empty for every level, so `optimize` is the observable identity; units 03/04 register the
/// real passes (single-owner-additive on `pipeline/1`).
pub fn optimize(module: Module, level: OptLevel) -> Module {
  run_pipeline(module, pipeline(level))
}

/// The ordered pass list for `level` — the ONE registration point (units 03/04 append here).
///
/// FREEZE: every level is `[]` (identity). `OptNone` stays `[]` forever (F1); `Baseline` grows
/// the trust-neutral passes (unit 03); `Aggressive` grows `baseline ++` the Unsafe-only passes
/// (unit 04), so aggressive is a strict superset of baseline. Total.
fn pipeline(level: OptLevel) -> List(Pass) {
  case level {
    OptNone -> []
    Baseline -> []
    Aggressive -> []
  }
}
