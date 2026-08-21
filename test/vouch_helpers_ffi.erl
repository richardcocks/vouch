%% Test-only helper for the background-crash fixtures in helpers.gleam.
-module(vouch_helpers_ffi).
-export([run_in_background/1]).

%% Run F in an unlinked process and wait until that process is gone. The
%% caller is not linked, so the crash does not reach it; the monitor only
%% sequences the death before the return. The BEAM logs a crash report
%% before the monitor fires, so by the time this returns the report is on
%% its way to the capture handler.
run_in_background(F) ->
    {_Pid, Ref} = spawn_monitor(fun() -> F() end),
    receive
        {'DOWN', Ref, process, _, _} -> nil
    end.
