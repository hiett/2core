%% Test-only FFI shim for the unit-08 (`emit_core`) end-to-end tests.
%%
%% Hand-written Erlang, so it carries the `twocore_` namespace prefix (overview §5).
%% It exists only to drive a freshly-compiled-and-loaded generated module and to
%% capture a trap / capability-denial *without crashing the test process* (Gleam on
%% OTP 29 has no generic exception-rescue in this dependency set). It does not touch
%% any unit-owned source file.
-module(twocore_emit_test_ffi).
-export([catch_apply/3]).

%% Apply M:F(Args). On a normal return yield `{ok, V}` (a Gleam `Ok`); if the call
%% raises/exits/throws, yield `{error, Reason}` (a Gleam `Error`) with `Reason`
%% rendered as a UTF-8 binary (a Gleam `String`) so the caller can assert on its
%% text (e.g. that a trap surfaced as `{wasm_trap, int_div_by_zero}`).
catch_apply(M, F, Args) ->
    try erlang:apply(M, F, Args) of
        V -> {ok, V}
    catch
        _Class:Reason ->
            {error, unicode:characters_to_binary(io_lib:format("~0p", [Reason]))}
    end.
