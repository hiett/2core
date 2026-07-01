#!/usr/bin/env bash
# 2core Phase-3 benchmark (F8, capstone proof 6) — HONEST numbers, methodology + limitations in
# docs/phase-3-benchmark.md. Compiles the committed smoke wasm (CRC-32 / SHA-256 / DEFLATE real
# crates) to a .beam under EACH profile, times the emitted BEAM code with `exec -n N` (invocations
# ONLY — excludes compile/load/instantiate), and compares against a hand-written pure-Erlang
# CRC-32 baseline and the native NIF ceiling (crypto/zlib). No hero number.
#
# NOTE (honest limitation): the Aggressive/Unsafe inliner does not scale to the 80-function smoke
# module in practical compile time (code explosion — see the report), so the Unsafe compile is
# attempted under a timeout and reported "n/a" when it does not finish. Compile time is a one-time
# cost (excluded from the exec timing), so this is a compile-scalability limit, not a run cost.
#
# Usage: ./smoke/bench.sh [REPEAT] [UNSAFE_TIMEOUT_SECS]   (defaults: 100, 45)
set -uo pipefail
cd "$(dirname "$0")/.."                       # repo root
WASM=smoke/target/wasm32v1-none/release/twocore_smoke.wasm
REL=smoke/target/wasm32v1-none/release
REPEAT=${1:-100}
UNSAFE_TIMEOUT=${2:-45}
OUT=build/bench
mkdir -p "$OUT"

# Portable timeout (macOS lacks GNU `timeout`): run "$@" and kill it after $1 seconds.
run_to() {
  local secs=$1; shift
  "$@" & local pid=$!
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) & local w=$!
  wait "$pid" 2>/dev/null; local rc=$?
  kill -9 "$w" 2>/dev/null; wait "$w" 2>/dev/null
  return $rc
}

# ── 0. the wasm must be built + import-free ─────────────────────────────────────────────────
if [ ! -f "$WASM" ]; then
  echo "== building smoke wasm (cargo) =="
  ( cd smoke && cargo build --release --target wasm32v1-none ) || { echo "cargo build failed"; exit 1; }
fi
imp=$(wasm-tools print "$WASM" 2>/dev/null | grep -c '(import' || true)
[ "${imp:-1}" = 0 ] || { echo "FAIL: $imp imports (2core has no import support)"; exit 1; }
echo "== smoke wasm: $(wc -c <"$WASM") bytes, $(wasm-tools print "$WASM"|grep -c '(func ') funcs, 0 imports =="

# ── 1. profile-selecting compile to .beam (CLI verb `to-beam-wasm`) ─────────────────────────
echo "== compile to .beam under each profile =="
gleam build >/dev/null 2>&1
SBEAM="$OUT/smoke.safe.beam"; UBEAM="$OUT/smoke.unsafe.beam"; rm -f "$UBEAM"
gleam run -- to-beam-wasm "$WASM" "$SBEAM" >/dev/null && echo "  Safe   → $SBEAM ($(wc -c <"$SBEAM") bytes)"
echo "  Unsafe → attempting (Aggressive optimizer, ${UNSAFE_TIMEOUT}s timeout) ..."
if run_to "$UNSAFE_TIMEOUT" gleam run -- to-beam-wasm --unsafe "$WASM" "$UBEAM" >/dev/null 2>&1 && [ -f "$UBEAM" ]; then
  echo "  Unsafe → $UBEAM ($(wc -c <"$UBEAM") bytes)"; HAVE_UNSAFE=1
else
  echo "  Unsafe → n/a (Aggressive inliner did not finish within ${UNSAFE_TIMEOUT}s — see report)"; HAVE_UNSAFE=0
fi

# `exec -n N` prints "<result>\n<N> call(s) · <us> us total · <ns> ns/call".
exec_ns()  { gleam run -- exec -n "$1" "$2" "$3" "$4" 2>/dev/null | sed -n '2p' | awk '{print $(NF-1)}'; }
exec_val() { gleam run -- exec -n "$1" "$2" "$3" "$4" 2>/dev/null | sed -n '1p'; }
ratio()    { awk -v s="$1" -v u="$2" 'BEGIN{ if (u ~ /^[0-9]+$/ && u+0>0) printf "%.2f", s/u; else printf "n/a" }'; }
# Deflate is ~60 ms/call on 2core's paged memory; cap its repeat so the bench stays quick.
DREPEAT=$(( REPEAT/5 > 20 ? 20 : REPEAT/5 )); [ "$DREPEAT" -lt 5 ] && DREPEAT=5

# ── 2. hand-written pure-Erlang CRC-32 + native-NIF ceilings via an escript ─────────────────
BASE="$OUT/baseline.escript"
cat > "$BASE" <<'ESCRIPT'
#!/usr/bin/env escript
%%! -noshell
% Hand-written pure-Erlang baselines. Each kernel recomputes `gen(N)` per call, exactly as the
% wasm exports do, so the per-call work matches. crc32 is hand-written (table-driven); sha256 and
% zlib are native NIF ceilings (clearly labelled in the report), NOT hand-written Erlang.
main([RepS, NcrcS, NshaS, NdefS, DrepS]) ->
    R = list_to_integer(RepS), Dr = list_to_integer(DrepS),
    Ncrc = list_to_integer(NcrcS), Nsha = list_to_integer(NshaS), Ndef = list_to_integer(NdefS),
    T = crc_table(),
    bench("erlang_crc32",  fun() -> crc32(gen(Ncrc), T) end, R),
    bench("native_sha256", fun() -> sha_word(gen(Nsha)) end, R),
    bench("native_zlib",   fun() -> Z = gen(Ndef), C = zlib:compress(Z), Z = zlib:uncompress(C), ok end, Dr),
    io:format("erlang_crc32_value ~p~n", [crc32(gen(Ncrc), T)]),
    ok.

bench(Label, Fun, R) ->
    _ = Fun(),
    {Micros, _} = timer:tc(fun() -> loop(Fun, R) end),
    io:format("~s ~p ns/call~n", [Label, (Micros * 1000) div R]).
loop(_, 0) -> ok;
loop(F, K) -> _ = F(), loop(F, K - 1).

gen(N) -> list_to_binary(gen(N, 16#12345678, [])).
gen(0, _, Acc) -> lists:reverse(Acc);
gen(K, S, Acc) ->
    S2 = (S * 1664525 + 1013904223) band 16#FFFFFFFF,
    gen(K - 1, S2, [(S2 bsr 24) band 16#FF | Acc]).

crc_table() -> list_to_tuple([crc_e(N, 8) || N <- lists:seq(0, 255)]).
crc_e(C, 0) -> C;
crc_e(C, K) when C band 1 =:= 1 -> crc_e((C bsr 1) bxor 16#EDB88320, K - 1);
crc_e(C, K) -> crc_e(C bsr 1, K - 1).
crc32(Bin, T) -> crc32(Bin, 16#FFFFFFFF, T) bxor 16#FFFFFFFF.
crc32(<<B, Rest/binary>>, Crc, T) ->
    crc32(Rest, (Crc bsr 8) bxor element(((Crc bxor B) band 16#FF) + 1, T), T);
crc32(<<>>, Crc, _) -> Crc.

sha_word(Bin) -> <<W:32/big, _/binary>> = crypto:hash(sha256, Bin), W.
ESCRIPT

echo "== timing (crc/sha REPEAT=$REPEAT, deflate=$DREPEAT calls; ns/call) =="
CRC_S=$(exec_ns "$REPEAT" "$SBEAM" crc32 4096)
SHA_S=$(exec_ns "$REPEAT" "$SBEAM" sha256_word 4096)
DEF_S=$(exec_ns "$DREPEAT" "$SBEAM" deflate_roundtrip 2000)
CRC_VAL=$(exec_val "$REPEAT" "$SBEAM" crc32 4096)
if [ "$HAVE_UNSAFE" = 1 ]; then
  CRC_U=$(exec_ns "$REPEAT" "$UBEAM" crc32 4096)
  SHA_U=$(exec_ns "$REPEAT" "$UBEAM" sha256_word 4096)
  DEF_U=$(exec_ns "$DREPEAT" "$UBEAM" deflate_roundtrip 2000)
else
  CRC_U="n/a"; SHA_U="n/a"; DEF_U="n/a"
fi

BASE_OUT=$(escript "$BASE" "$REPEAT" 4096 4096 2000 "$DREPEAT" 2>/dev/null)
ERL_CRC=$(echo "$BASE_OUT"  | awk '/erlang_crc32 /{print $2}')
NAT_SHA=$(echo "$BASE_OUT"  | awk '/native_sha256 /{print $2}')
NAT_ZLIB=$(echo "$BASE_OUT" | awk '/native_zlib /{print $2}')
ERL_CRC_VAL=$(echo "$BASE_OUT" | awk '/erlang_crc32_value /{print $2}')

echo
printf "%-20s %14s %14s %16s %13s\n" "kernel" "2core-Unsafe" "2core-Safe" "hand-Erl/native" "Safe/Unsafe"
printf "%-20s %11s ns %11s ns %13s ns %12s×\n" "crc32(4096)"       "$CRC_U" "$CRC_S" "$ERL_CRC"  "$(ratio "$CRC_S" "$CRC_U")"
printf "%-20s %11s ns %11s ns %13s ns %12s×\n" "sha256_word(4096)" "$SHA_U" "$SHA_S" "$NAT_SHA"  "$(ratio "$SHA_S" "$SHA_U")"
printf "%-20s %11s ns %11s ns %13s ns %12s×\n" "deflate_rt(2000)"  "$DEF_U" "$DEF_S" "$NAT_ZLIB" "$(ratio "$DEF_S" "$DEF_U")"
echo
echo "crc32(4096): 2core=$CRC_VAL  hand-written-Erlang=$ERL_CRC_VAL  (bit-identical head-to-head; both cross-check vs wasmtime in run.sh)"
echo "hand-Erl/native col: crc32 = hand-written PURE Erlang; sha256/deflate = native NIF ceiling (crypto/zlib), NOT hand-written."
[ "$HAVE_UNSAFE" = 0 ] && echo "2core-Unsafe = n/a: the Aggressive inliner does not scale to this 80-function module (compile-time only; see report)."
