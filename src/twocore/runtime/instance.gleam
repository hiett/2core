//// The runtime binding — the second keystone (the calling convention, D3).
////
//// This file defines **how generated code reaches the runtime**. It is a BUILD-TIME
//// descriptor consumed by `emit_core`'s binding chokepoint (D3b): it carries the
//// Erlang MODULE NAME implementing each runtime layer. The `Binding` is **never
//// embedded in generated code** (D3d) — Phase-1 generated functions are pure and
//// thread no runtime record. See `specs/phase-1/00-overview.md` D2/D3.
////
//// ## The Phase-1 binding strategy: link-time-fixed binding (B2)
////
//// `emit_core` resolves each runtime op at codegen time into a **direct**
//// `call '<impl-module>':'<fn>'/<arity>(...)`, where `<impl-module>` is read from the
//// `Binding` chosen by the build profile. This is the fast path (no per-call
//// indirection, no runtime closure on hot numeric ops) and the simplest correct thing.
////
//// Two security invariants hold (and are tested in unit 08):
//// - **D3a — no ambient authority.** Generated code never performs a data-driven
////   `apply(Mod, F, Args)` where `Mod` comes from program/attacker data. Every runtime
////   reference resolves to a fixed, build-controlled `twocore@runtime@*` module.
//// - **D3b — one binding chokepoint.** Every runtime reference (numerics, traps,
////   host, charge — and later memory/tables/stdlib) is routed through this one table,
////   so switching later to per-instance dynamic dispatch (B1) or whole-program
////   monomorphisation (B3) is a localised change here, never scattered through the
////   emitter.
////
//// ## The Phase-1 calling convention (so units 08 and 09 agree exactly)
////
//// Module names below are the Gleam→Erlang-mangled names: a Gleam module path
//// `twocore/runtime/rt_num` maps to the Erlang module `twocore@runtime@rt_num`
//// (path `/` → `@`); public function names are emitted verbatim with arity = the
//// parameter count (D2).
////
//// | IR construct                | Emitted Core Erlang (schematic)                                                            |
//// |-----------------------------|--------------------------------------------------------------------------------------------|
//// | `Num(IAdd(W32), [a, b])`    | `call '<num_module>':'i32_add'(A, B)`                                                       |
//// | `Num(IDivS(W32), [a, b])`   | `call '<num_module>':'i32_div_s'(A, B)` → `{ok,X}`/`{error,R}`; emitter `case`s, raises on error |
//// | `Trap(IntDivByZero)`        | `call '<trap_module>':'raise'('int_div_by_zero')`                                           |
//// | `CallHost(cap, name, args)` | `call '<host_module>':'call_host'(Cap, Name, [Args…])` (the deny-all host raises)           |
//// | `Charge(cost, body)`        | `call '<meter_module>':'charge'(Cost)` then `body`                                          |
////
//// The mapping `NumOp → rt_num function name` is owned by unit 08 (the chokepoint) but
//// **must match the frozen `rt_num` signatures** — that is the whole point of freezing
//// them in `rt_num.gleam`.
////
//// ## The two fates of `CallHost` (resolved post-review)
////
//// `ir_lower` (unit 11) runs *before* `emit_core` and decides what each `CallHost`
//// becomes:
//// - a `CallHost` that resolves to an **`own` stdlib** function is rewritten by
////   `ir_lower` into a direct runtime call — `emit_core` emits
////   `call '<stdlib_module>':'<fn>'(Args…)`. A vetted stdlib call does **not** go
////   through the deny-all host.
//// - a `CallHost` to a **genuine host import** is left as-is — `emit_core` emits
////   `call '<host_module>':'call_host'(Cap, Name, [Args…])`, which under the Safe
////   profile's `deny_all` host raises (fail-closed).
////
//// ## `rt_bif` is a build-time gate, not a runtime layer
////
//// `rt_bif` (the BEAM-function allowlist) is consulted by `ir_lower` (unit 11) at
//// **build time** when resolving `CallHost`/BIF targets; it is **not** in the
//// `Binding` record and **not** called by generated code. Its gate shape is therefore
//// frozen with unit 11, not here — which is why `Binding` carries `stdlib_module` but
//// no `bif_module`.

/// The global execution mode (high-level §6). Phase 1 ships `Safe` only; `Unsafe` is
/// present for lock-now completeness and is deferred to Phase 2.
///
/// - `Safe`: the fail-closed profile (deny-all host, full validation, allowlisted
///   BIFs, metering). Permits trust tiers P or O, never N.
/// - `Unsafe`: the aggressive/passthrough profile (Phase 2).
pub type Mode {
  Safe
  Unsafe
}

/// Which compiled runtime module implements each runtime layer.
///
/// Each field holds a Gleam→Erlang-mangled module name (e.g.
/// `"twocore@runtime@rt_num"`). `emit_core` emits `call '<field>':'<fn>'(...)` against
/// these. This record is a **build-time input** to the emitter, never embedded in or
/// threaded through generated code (D3d).
///
/// Fields:
/// - `mode`: the global execution mode this binding realises.
/// - `num_module`: implements the numeric ops (`rt_num`).
/// - `trap_module`: implements trap raising (`rt_trap`).
/// - `host_module`: implements the host/capability boundary (`rt_host`).
/// - `meter_module`: implements metering / fuel (`rt_meter`).
/// - `stdlib_module`: implements the `own` standard library (`rt_stdlib`).
/// - `mem_module`: implements linear memory — load/store/size/grow/init_data (`rt_mem`).
/// - `table_module`: implements funcref tables + `call_indirect` dispatch (`rt_table`).
/// - `state_module`: implements the per-instance cell holder + mutable globals
///   (`rt_state`). `GlobalGet`/`GlobalSet` route here; the cell ABI is
///   `«CELL-STATE-ABI-FROZEN»` (the tier-O process-dictionary convention).
///
/// Phase-2 adds the memory/table/instance-state module fields below; because binding lives
/// in this one record, that is a clean extension, not a retrofit. The cell↔threaded
/// *state* tier is a codegen-shape sub-axis (`emit_core`'s state-access seam), NOT a
/// module swap through this record (overview E1).
pub type Binding {
  Binding(
    mode: Mode,
    num_module: String,
    trap_module: String,
    host_module: String,
    meter_module: String,
    stdlib_module: String,
    mem_module: String,
    table_module: String,
    state_module: String,
  )
}

/// The Phase-1 Safe profile binding: deny-all host, `bif` numerics, fuel metering, and
/// the `own` stdlib, all wired to the default `twocore@runtime@rt_*` modules.
///
/// This is the **fail-closed default** (D4/D9): the default profile IS the safe one —
/// there is no way to obtain an unsafe binding by omission. Unit 11 may later move
/// profile construction to `runtime/profiles.gleam`; this gives `emit_core` a target
/// now.
///
/// Returns a fully-populated `Binding` with `mode: Safe`. Total — never fails.
pub fn safe_default() -> Binding {
  Binding(
    mode: Safe,
    num_module: "twocore@runtime@rt_num",
    trap_module: "twocore@runtime@rt_trap",
    host_module: "twocore@runtime@rt_host",
    meter_module: "twocore@runtime@rt_meter",
    stdlib_module: "twocore@runtime@rt_stdlib",
    mem_module: "twocore@runtime@rt_mem",
    table_module: "twocore@runtime@rt_table",
    state_module: "twocore@runtime@rt_state",
  )
}
