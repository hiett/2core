%% Unit 11c — CLI / run-invoke FFI shim (the catching-apply seam for `pipeline:invoke`).
%%
%% Hand-written Erlang, so it carries the `twocore_` namespace prefix (overview §5), never
%% `lists`/`maps`/`erlang`. It exists only so the run/invoke ABU (`pipeline.gleam`) can
%% apply a freshly-loaded generated export and capture a trap / capability-denial WITHOUT
%% crashing the calling process — Gleam on OTP 29 has no generic exception rescue in this
%% dependency set (gleam_erlang 1.3), so the catch must live in Erlang.
%%
%% The doc (11d) asked unit 04 to add a catching-apply path to its `twocore_codegen_ffi`
%% shim; that seam was not present and 04's file is single-owned (D1, must not be edited),
%% so the seam is provided here instead. It touches no unit-owned source file.
-module(twocore_cli_ffi).
-export([catch_apply/3]).

%% Apply Mod:Fun(Args) on the loaded generated module. On a normal return yield
%% `{ok, V}` (a Gleam `Ok(Int)`) where V is the result rendered as an integer (the raw
%% value / IEEE-754 bit pattern, per D5). If the call raises/exits/throws — a trap raised
%% by `rt_trap` as error-class `{wasm_trap, Kind}`, or a deny-all `{capability_denied,
%% Cap, Name}` — yield `{error, Reason}` (a Gleam `Error(String)`) with Reason rendered as
%% a UTF-8 binary so the caller can substring-match the spec trap phrase. Never crashes the
%% caller.
catch_apply(Mod, Fun, Args) ->
    try erlang:apply(Mod, Fun, Args) of
        V -> {ok, V}
    catch
        _Class:Reason ->
            {error, unicode:characters_to_binary(io_lib:format("~0p", [Reason]))}
    end.
