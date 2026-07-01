//// `ir/effect` — the shared purity/effect classifier (F3, owner: unit 02).
////
//// Conservative: anything not *proven* pure is `Effectful`. The optimizer's soundness rests
//// on this classifier (E6): it must never rewrite across an effect barrier — no CSE of a load
//// past a store, no reorder past a `MemGrow`/`GlobalSet`/`CallIndirect`/`CallHost`/`Charge`/
//// `Trap`, no DCE of an effect.
////
//// ## Freeze posture (this unit) — sound by construction
////
//// This unit freezes only the classifier's **signature**, with **maximally conservative**
//// bodies: `classify → Effectful`, `is_pure → False`, `is_effectful_node → True`,
//// `function_is_pure → False`. Under these bodies the freeze optimizer legally rewrites
//// *nothing* — it is a strict, provably-sound identity. Unit 02 replaces the bodies with the
//// real purity analysis, which may only ever **narrow** `Effectful → Pure` *with proof*;
//// misclassifying an effectful node as pure is a memory-corruption bug, so the never-narrow
//// direction (e.g. `MemStore` is effectful forever) is pinned by test.
////
//// ## Spec anchor
////
//// WASM has a defined store/evaluation model (WebAssembly spec §4.2 Runtime Structure and
//// §4.4 Instructions): memory and global operations read/write the store in program order.
//// E6/F3 make that order the optimizer's hard barrier.

import twocore/ir.{type Expr, type Function}

/// Whether an expression is observably pure or side-effecting (F3).
///
/// - `Pure`: evaluation reads/writes no mutable instance state and cannot trap or diverge —
///   safe to fold, CSE, reorder, or eliminate.
/// - `Effectful`: evaluation may read/write memory/globals/tables, call the host, charge fuel,
///   or trap — an optimizer barrier.
pub type Effect {
  Pure
  Effectful
}

/// DEEP classification: `Pure` iff `e` AND every sub-expression are pure. The optimizer uses
/// this to decide whether a whole subtree may be folded / CSE'd / eliminated.
///
/// - `_e`: the expression to classify (its whole subtree). Ignored at the freeze.
/// - Return: the `Effect` of the subtree. FREEZE body: `Effectful` (the sound conservative
///   default — treat everything as effectful so nothing is rewritten). Total. Unit 02 refines.
pub fn classify(_e: Expr) -> Effect {
  Effectful
}

/// `True` iff `classify(e) == Pure` — the guard a pass consults before folding/CSE-ing/
/// eliminating a whole subtree.
///
/// - `_e`: the expression to test. Ignored at the freeze.
/// - Return: FREEZE body: always `False` (safe — no subtree is treated as pure, so no rewrite
///   is licensed). Total. Unit 02 refines. Never a lock-in of the stub's output: the SOUND
///   direction (an effectful node is never `True`) holds at the freeze and forever.
pub fn is_pure(_e: Expr) -> Bool {
  False
}

/// SHALLOW barrier test: is THIS node an effect barrier, ignoring its children? Used to test
/// whether two effectful nodes may swap. `MemLoad`/`MemStore`/`MemGrow`/`MemSize`/`GlobalGet`/
/// `GlobalSet`/`CallDirect`/`CallIndirect`/`CallHost`/`Charge`/`Trap` are barriers;
/// `Num`/`Convert`/`Values` and the structured-control *shells* are not (their children may
/// still be effectful).
///
/// - `_e`: the node to test (its own effect, not its children's). Ignored at the freeze.
/// - Return: FREEZE body: always `True` (treat every node as a barrier → the freeze optimizer
///   moves nothing). Total. Unit 02 refines.
pub fn is_effectful_node(_e: Expr) -> Bool {
  True
}

/// `True` iff `f`'s whole body is pure — enables pure-callee reasoning for inlining (unit 04)
/// and pure-call CSE.
///
/// - `_f`: the function to test. Ignored at the freeze.
/// - Return: FREEZE body: always `False` (sound — no callee is treated as pure). Total.
///   Unit 02 refines.
pub fn function_is_pure(_f: Function) -> Bool {
  False
}
