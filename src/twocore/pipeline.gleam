//// Top-level driver glue. Per-stage errors (D4) compose **here**, at the driver
//// boundary; there is **no single shared `StageError`**.
////
//// Each pipeline stage owns its own error type (`DecodeError` in the decoder,
//// `ValidateError` in the validator, …) so stages evolve independently. Unit 11 maps
//// each stage's own error into a `PipelineError` variant at the seam, and completes
//// the stage driver. This stub keeps the variants loose (`detail: String`) until the
//// real stage types exist — that looseness is the point of D4.
////
//// See `specs/phase-1/00-overview.md` D4.

/// The union of every stage's error, assembled at the driver boundary.
///
/// Each variant marks *which* stage failed; the `detail` placeholder is replaced by
/// the stage's own error type as that stage lands (e.g. `DecodeFailed` will wrap
/// `frontend/wasm/decode.DecodeError`). The semantics: a `Result(_, PipelineError)`
/// returned by the driver is `Error(variant)` iff the named stage rejected the input
/// (fail-closed, D4) — never a panic.
///
/// Variants (in pipeline order):
/// - `DecodeFailed`: the WASM binary decoder rejected the input (unit 05 refines).
/// - `ValidateFailed`: the `full` validator rejected the module (unit 10 refines).
/// - `LowerFailed`: WASM→IR lowering or the IR→IR middle-end failed (units 10/11).
/// - `EmitFailed`: `emit_core` could not produce Core Erlang (unit 08).
/// - `BuildFailed`: the Core Erlang → `.beam` build/load step failed (unit 04).
pub type PipelineError {
  DecodeFailed(detail: String)
  ValidateFailed(detail: String)
  LowerFailed(detail: String)
  EmitFailed(detail: String)
  BuildFailed(detail: String)
}
