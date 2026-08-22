-module(vouch_ffi).
-export([
    find_test_files/0,
    exported_zero_arity/1,
    run_test/4,
    catch_panic/1,
    split_crash/1,
    decode_panic/1,
    now_microseconds/0,
    is_stdout_tty/0,
    env/1,
    capture_diagnostics/0,
    all_diagnostics/0,
    unattributed_diagnostics/0,
    take_diagnostics_matching/1,
    take_unattributed_matching/1,
    leaked_processes/0,
    take_leaks_matching/1,
    crash_filter/2,
    log/2,
    %% The collector's three states. All exported because erlang:hibernate/3
    %% resumes through an exported call: hibernating into a local function
    %% succeeds and then fails with undef on wake-up, silently killing the
    %% collector.
    collect_crashes/4,
    sweep_leaks/3,
    forward_crashes/2,
    write_file/2,
    read_source/3,
    halt/1,
    halt_now/1,
    file_snapshot/1,
    run_passthrough/2,
    sleep_ms/1,
    install_quit_hooks/0,
    take_pending_key/0,
    keys_active/0,
    ensure_unicode_stdio/0,
    start_test/4,
    await_test/1,
    schedulers_online/0,
    is_erlang/0,
    run_tests/6
]).

is_erlang() -> true.

%% Stub for the JavaScript-only async loop. Unreachable: runner.run
%% dispatches on is_erlang/0 before either loop is entered.
run_tests(_State, _ShouldRun, _OnBegin, _OnTestStart, _OnTestResult, _OnDone) ->
    erlang:error(javascript_only).

write_file(Path, Content) ->
    case file:write_file(unicode:characters_to_list(Path), Content) of
        ok -> {ok, nil};
        {error, Reason} -> {error, atom_to_binary(Reason, utf8)}
    end.

%% The source text between two byte offsets, as the compiler recorded them
%% in a panic payload. Any failure to read is {error, nil}: source text is
%% a nicety on top of the payload, never a requirement.
read_source(Path, Start, End) ->
    case Start >= 0 andalso End > Start of
        true ->
            case file:read_file(unicode:characters_to_list(Path)) of
                {ok, Binary} when byte_size(Binary) >= End ->
                    {ok, binary:part(Binary, Start, End - Start)};
                _ ->
                    {error, nil}
            end;
        false ->
            {error, nil}
    end.

now_microseconds() ->
    erlang:monotonic_time(microsecond).

is_stdout_tty() ->
    case io:columns() of
        {ok, _} -> true;
        _ -> false
    end.

env(Name) ->
    case os:getenv(unicode:characters_to_list(Name)) of
        false -> {error, nil};
        Value -> {ok, unicode:characters_to_binary(Value)}
    end.

%% Pass/fail for a process that dies behind a test is driven by tracing (see
%% run_test/3), not by these logger reports. The logger capture exists only
%% to keep BEAM crash reports (the emulator's "Error in process", proc_lib
%% CRASH REPORTs, gen_* terminate and supervisor child reports) off the
%% output streams and hand them to --show-crash-reports: a report is a raw
%% render of a death the trace already accounted for, wanted in full only on
%% request. Everything else routed through logger (a library's warnings, a
%% test's own log lines) is not a crash and still prints, via the default
%% handler moved to stderr so it cannot corrupt a machine-read stdout stream.
%%
%% This module doubles as the capture handler: crash_filter/2 selects the
%% events and log/2 stores each one rendered with the default handler's own
%% formatter. If the capture handler cannot be installed, reports stay on
%% stderr — still better than corrupting stdout.
capture_diagnostics() ->
    ensure_diagnostics_tables(),
    catch case logger:get_handler_config(vouch_diagnostics) of
        {ok, _} ->
            %% Already capturing; installing twice would double reports.
            ok;
        _ ->
            case logger:get_handler_config(default) of
                {ok, #{formatter := Formatter}} ->
                    Capture = logger:add_handler(vouch_diagnostics, ?MODULE, #{
                        formatter => Formatter,
                        filter_default => stop,
                        filters => [{vouch_crashes_only,
                            {fun ?MODULE:crash_filter/2, only}}]
                    }),
                    redirect_default_to_stderr(),
                    case Capture of
                        ok ->
                            %% Only once the capture handler is live, so no
                            %% crash report is dropped by both sides.
                            logger:add_handler_filter(default,
                                vouch_crashes_out,
                                {fun ?MODULE:crash_filter/2, stop});
                        _ ->
                            ok
                    end;
                _ ->
                    %% No default handler: nothing would have printed, so
                    %% there is nothing to divert.
                    ok
            end
    end,
    nil.

%% vouch_crash_texts: {Key, Text} rendered reports, Key from
%% unique_integer([monotonic]) so arrival order is table order — the raw
%% text for --show-crash-reports. vouch_unattributed: {Key, Reason,
%% TestName} for crashes a collector saw after its test was already claimed
%% (a worker outliving its test) or that no test's tree produced — these
%% fail the run. Both owned by the runner process, which lives until halt.
%% vouch_leaks: {Key, TestName, Leak} for processes a test left running,
%% recorded as each test is claimed.
ensure_diagnostics_tables() ->
    case ets:whereis(vouch_crash_texts) of
        undefined ->
            ets:new(vouch_crash_texts, [named_table, public, ordered_set]),
            ets:new(vouch_unattributed, [named_table, public, ordered_set]),
            ets:new(vouch_leaks, [named_table, public, ordered_set]);
        _ ->
            ok
    end.

%% Logger filter, used two ways: `only` passes crash reports and stops
%% everything else (the capture handler), `stop` stops crash reports and
%% leaves the rest to the remaining filters (the default handler).
crash_filter(Event, Mode) ->
    case {is_crash_report(Event), Mode} of
        {true, only} -> Event;
        {true, stop} -> stop;
        {false, only} -> stop;
        {false, stop} -> ignore
    end.

%% The shapes the BEAM and OTP use for a dying process. Only these are
%% crashes; an error-level log line from the code under test is not.
is_crash_report(#{msg := {Format, _}, meta := #{error_logger := #{emulator := true}}})
        when is_list(Format) ->
    lists:prefix("Error in process", Format);
is_crash_report(#{meta := #{error_logger := #{type := crash_report}}}) ->
    true;
is_crash_report(#{msg := {report, #{label := {proc_lib, crash}}}}) ->
    true;
is_crash_report(#{level := error, msg := {report, #{label := {_, terminate}}}}) ->
    true;
is_crash_report(#{level := error, msg := {report, #{label := {supervisor, _}}}}) ->
    true;
is_crash_report(_) ->
    false.

%% Logger handler callback, installed by capture_diagnostics/0. Renders the
%% event with the default handler's formatter and stores the text. Must
%% never raise: logger removes a handler whose callback crashes.
log(Event, Config) ->
    catch ets:insert(vouch_crash_texts,
        {erlang:unique_integer([monotonic]), render_diagnostic(Event, Config)}),
    ok.

render_diagnostic(Event, Config) ->
    try
        {FModule, FConfig} = maps:get(formatter, Config),
        Text = unicode:characters_to_binary(FModule:format(Event, FConfig)),
        true = is_binary(Text),
        Text
    catch
        _:_ ->
            unicode:characters_to_binary(io_lib:format("~0tp~n", [Event]))
    end.

%% Every captured report's text, in arrival order, for --show-crash-reports.
%% Read once at the end of the run, by when every report has arrived.
all_diagnostics() ->
    flush_logger(),
    [Text || {_Key, Text} <- table(vouch_crash_texts)].

%% The crashes no test claimed — a process that died after its test had
%% finished (named here, from its collector), or in no test's tree at all —
%% each as {ReasonText, TestName}. Trace-driven, so these are exact; the run
%% fails on them, because a crash no outcome accounts for must not hide
%% behind a green summary.
unattributed_diagnostics() ->
    [{reason_text(Reason), TestName}
     || {_Key, Reason, TestName} <- table(vouch_unattributed)].

reason_text(Reason) ->
    unicode:characters_to_binary(io_lib:format("~0tp", [Reason])).

%% Remove and return the captured report texts containing Marker, leaving
%% the rest alone. The suite-facing probe: a test that crashes a process on
%% purpose can assert its report reached the capture table rather than
%% stderr, without disturbing other tests' reports.
take_diagnostics_matching(Marker) ->
    flush_logger(),
    [begin
         catch ets:delete(vouch_crash_texts, Key),
         Text
     end
     || {Key, Text} <- table(vouch_crash_texts),
        binary:match(Text, Marker) =/= nomatch].

%% Remove and return the rendered reasons of unattributed crashes containing
%% Marker. The suite-facing probe for the late-crash path: a test whose
%% worker outlives it can poll for its own late crash and consume it, so the
%% suite run does not fail on the unattributed entry it deliberately caused.
take_unattributed_matching(Marker) ->
    [begin
         catch ets:delete(vouch_unattributed, Key),
         Text
     end
     || {Key, Reason, _TestName} <- table(vouch_unattributed),
        Text <- [reason_text(Reason)],
        binary:match(Text, Marker) =/= nomatch].

%% Every process a test left running, in the order they were recorded, as
%% {TestModule, TestFunction, Leak}. Read once at the end of the run.
leaked_processes() ->
    [{TestModule, TestFunction, Leak}
     || {_Key, {TestModule, TestFunction}, Leak} <- table(vouch_leaks)].

%% Remove and return the leaks whose origin function contains Marker. The
%% suite-facing probe: a test that leaks a process on purpose can assert it
%% was killed and recorded, and consume the row so the end-of-run leak
%% report does not carry the suite's own deliberate leaks.
take_leaks_matching(Marker) ->
    [begin
         catch ets:delete(vouch_leaks, Key),
         {TestModule, TestFunction, Leak}
     end
     || {Key, {TestModule, TestFunction}, Leak} <- table(vouch_leaks),
        {process_leak, _Module, Function, _Arity} <- [Leak],
        binary:match(Function, Marker) =/= nomatch].

table(Name) ->
    case catch ets:tab2list(Name) of
        Rows when is_list(Rows) -> Rows;
        _ -> []
    end.

%% Emulator-generated reports ("Error in process") reach the capture handler
%% through the logger_proxy process's mailbox; API-call events (proc_lib,
%% gen_server) are handled inline. A synchronous round-trip through each
%% makes sure everything already sent is stored before the table is read.
%% This is off the per-test hot path — the reports are display-only, read
%% once at the end and by the suite's own probes.
flush_logger() ->
    flush(logger_proxy),
    flush(logger).

flush(Name) ->
    case whereis(Name) of
        undefined -> ok;
        Pid -> catch sys:get_state(Pid, 1000)
    end.

%% Route the default handler to stderr, so whatever it still prints (and
%% everything, if the capture handler could not be installed) stays off the
%% stdout stream reporters own. logger_std_h does not honour a runtime
%% `type` change, so the handler is removed and re-added with its filters
%% and formatter preserved.
redirect_default_to_stderr() ->
    case logger:get_handler_config(default) of
        {ok, #{module := Module, config := HConfig} = Cfg} ->
            NewCfg0 = Cfg#{config := HConfig#{type => standard_error}},
            NewCfg = maps:remove(id, maps:remove(module, NewCfg0)),
            logger:remove_handler(default),
            case logger:add_handler(default, Module, NewCfg) of
                ok ->
                    ok;
                _ ->
                    %% The reconstructed config was rejected. A fresh
                    %% stderr handler beats both no handler (reports
                    %% lost) and the old one (reports on stdout).
                    logger:add_handler(default, logger_std_h,
                        #{config => #{type => standard_error}})
            end;
        _ ->
            ok
    end.

%% Paths of .gleam files under test/, relative to test/.
find_test_files() ->
    Files = filelib:wildcard("**/*.gleam", "test"),
    [unicode:characters_to_binary(F) || F <- Files].

%% Names of the zero-arity exported functions of a module. Module names arrive
%% in Gleam form ("foo/bar_test"); nested modules compile to foo@bar_test.
exported_zero_arity(ModuleName) ->
    Module = binary_to_atom(beam_name(ModuleName), utf8),
    case code:ensure_loaded(Module) of
        {module, _} ->
            [atom_to_binary(Name, utf8)
             || {Name, Arity} <- Module:module_info(exports), Arity =:= 0];
        _ ->
            []
    end.

%% Run one test by name in its own monitored process. The test process
%% catches its own panic and sends the payload back, so decoding never
%% depends on exit-reason fidelity; the DOWN branch only fires when the
%% process died without reporting (exit signal, linked crash), and a test
%% that outlives the timeout is killed. Returns {Invocation, CrashReports}:
%% a constructor of vouch/internal/outcome.Invocation, and the reasons of
%% processes the test started that crashed while it ran (outcome.CrashReport
%% tuples), which the runner folds into the test's outcome.
%%
%% A collector process traces the test process with `set_on_spawn`, so every
%% process the test starts — directly or transitively — is traced too, and
%% the collector receives a trace message for each abnormal exit. This is
%% the pass/fail signal: exact, and never a race, because a trace exit is
%% delivered before any result the test can send (unlike the BEAM's
%% asynchronous crash report). After the result, trace_delivered/1 flushes
%% any trace messages still in transit, then the collector is claimed. It
%% keeps tracing afterwards: a worker that outlives its test and crashes
%% later is recorded as unattributed (the runner fails the run on those).
%%
%% The same trace also names every process the test started that is still
%% alive when the test ends. With KillLeaked those are killed — ancestors
%% first, so a supervisor cannot restart what has already gone — and
%% recorded as leaks, which is what makes process-per-test a real boundary
%% rather than a 90% one: nothing survives to crash late. With KillLeaked
%% false the tree is left alone and late crashes take the unattributed path.
run_test(ModuleName, FunctionName, TimeoutMs, KillLeaked) ->
    Module = binary_to_atom(beam_name(ModuleName), utf8),
    Function = binary_to_atom(FunctionName, utf8),
    Self = self(),
    %% Spawned suspended on a `go` message so tracing is in place before the
    %% test can start any worker.
    {Pid, Ref} = spawn_monitor(fun() ->
        receive go -> ok end,
        Self ! {vouch_result, self(), catch_panic(fun() -> Module:Function() end)}
    end),
    Collector = spawn(?MODULE, collect_crashes,
        [Pid, {ModuleName, FunctionName}, [], #{}]),
    %% Drop any trace inherited from a traced caller — vouch's own suite runs
    %% tests that themselves run tests, and a process can have only one
    %% tracer — before setting this test's own. A harmless no-op for a
    %% top-level test, which inherits nothing.
    catch erlang:trace(Pid, false, [procs, set_on_spawn]),
    catch erlang:trace(Pid, true, [procs, set_on_spawn, {tracer, Collector}]),
    Pid ! go,
    Invocation = receive
        {vouch_result, Pid, {ok, nil}} ->
            erlang:demonitor(Ref, [flush]),
            passed;
        {vouch_result, Pid, {error, Reason}} ->
            erlang:demonitor(Ref, [flush]),
            {panicked, Reason};
        {'DOWN', Ref, process, Pid, Reason} ->
            %% decode_panic's recursive search handles {Reason, Stacktrace}
            %% and OTP wrappers, so the reason is passed through raw.
            {died, Reason}
    after TimeoutMs ->
        erlang:demonitor(Ref, [flush]),
        exit(Pid, kill),
        receive
            {vouch_result, Pid, _} -> ok
        after 0 -> ok
        end,
        {timed_out, TimeoutMs}
    end,
    {Reports, Leaks} = claim_crashes(Collector, KillLeaked),
    record_leaks({ModuleName, FunctionName}, Leaks),
    {Invocation, Reports}.

%% Recorded from whichever process ran the test — the runner, or a parallel
%% middleman that dies with it — so the table is never created here: it is
%% owned by the runner (capture_diagnostics) and a middleman that created it
%% would take it to the grave.
record_leaks(_TestName, []) ->
    ok;
record_leaks(TestName, Leaks) ->
    [catch ets:insert(vouch_leaks,
        {erlang:unique_integer([monotonic]), TestName, Leak}) || Leak <- Leaks],
    ok.

%% Tracer for one test's process tree. Accumulates the exit reason of every
%% descendant that dies abnormally — anything but a clean exit (normal,
%% shutdown), and never the test process itself, whose death is the
%% invocation. On `claim` it hands back what it has and switches to
%% forwarding: any later crash (a worker that outlived the test) goes to the
%% unattributed table, tagged with this test, for the runner's end-of-run
%% failure. Idle between events, it hibernates to a few hundred bytes.
collect_crashes(TestPid, TestName, Acc, Live) ->
    receive
        {trace, TestPid, exit, _Reason} ->
            collect_crashes(TestPid, TestName, Acc, Live);
        {trace, Pid, exit, Reason} ->
            Rest = maps:remove(Pid, Live),
            case is_clean_exit(Reason) of
                true -> collect_crashes(TestPid, TestName, Acc, Rest);
                false -> collect_crashes(TestPid, TestName, [Reason | Acc], Rest)
            end;
        {trace, _Parent, spawn, Child, MFA} ->
            collect_crashes(TestPid, TestName, Acc,
                note_spawn(Child, MFA, Live));
        {trace, Child, spawned, _Parent, MFA} ->
            collect_crashes(TestPid, TestName, Acc,
                note_spawn(Child, MFA, Live));
        {claim, From, Ref, Kill} ->
            From ! {crashes, Ref, lists:reverse(Acc), leaks_of(Live)},
            case Kill of
                true -> sweep_leaks(TestPid, TestName, Live);
                false -> forward_crashes(TestPid, TestName)
            end;
        _Other ->
            collect_crashes(TestPid, TestName, Acc, Live)
    after 200 ->
        erlang:hibernate(?MODULE, collect_crashes,
            [TestPid, TestName, Acc, Live])
    end.

%% Between the claim and the last kill round. Crash reasons are discarded:
%% every death from here is one the runner is causing, and reporting our own
%% kills as the test's crashes is exactly the trap `killed` sets. Spawns are
%% still tracked, so a child a supervisor restarted before it was itself
%% killed shows up in the next sweep. On `finish` the collector stops if
%% nothing survived — which is the normal case, and retires the one
%% lingering process per test — or falls back to forwarding if something
%% did, so a stubborn survivor still reports a late crash.
sweep_leaks(TestPid, TestName, Live) ->
    receive
        {trace, TestPid, exit, _Reason} ->
            sweep_leaks(TestPid, TestName, Live);
        {trace, Pid, exit, _Reason} ->
            sweep_leaks(TestPid, TestName, maps:remove(Pid, Live));
        {trace, _Parent, spawn, Child, MFA} ->
            sweep_leaks(TestPid, TestName, note_spawn(Child, MFA, Live));
        {trace, Child, spawned, _Parent, MFA} ->
            sweep_leaks(TestPid, TestName, note_spawn(Child, MFA, Live));
        {sweep, From, Ref} ->
            From ! {swept, Ref, live_pids(Live)},
            sweep_leaks(TestPid, TestName, Live);
        {finish, From, Ref} ->
            From ! {finished, Ref},
            case live_pids(Live) of
                [] -> ok;
                _ -> forward_crashes(TestPid, TestName)
            end;
        _Other ->
            sweep_leaks(TestPid, TestName, Live)
    after 200 ->
        erlang:hibernate(?MODULE, sweep_leaks, [TestPid, TestName, Live])
    end.

%% One live descendant, keyed by pid. The monotonic key orders the set by
%% spawn, so killing in key order takes ancestors before their children and
%% a supervisor is gone before anything it would restart is touched. `spawn`
%% and `spawned` both arrive for the same child, so the first one wins.
note_spawn(Child, MFA, Live) ->
    case maps:is_key(Child, Live) of
        true -> Live;
        false -> Live#{Child => {erlang:unique_integer([monotonic]), origin(MFA)}}
    end.

%% What started a process, for the leak report. A Gleam closure reaches the
%% trace as erlang:apply/2 over a fun, naming nothing useful; fun_info
%% recovers the module it was compiled into and the generated name
%% `-enclosing/0-fun-0-`, whose enclosing function is the half worth showing
%% — the same function a panic in that closure would report.
origin({erlang, apply, [Fun, Args]}) when is_function(Fun), is_list(Args) ->
    Info = erlang:fun_info(Fun),
    Module = proplists:get_value(module, Info, unknown),
    Name = proplists:get_value(name, Info, unknown),
    {process_leak, atom_to_binary(Module, utf8), enclosing_name(Name),
     length(Args)};
origin({Module, Function, Args})
        when is_atom(Module), is_atom(Function), is_list(Args) ->
    {process_leak, atom_to_binary(Module, utf8),
     atom_to_binary(Function, utf8), length(Args)};
origin(_) ->
    {process_leak, <<"unknown">>, <<"unknown">>, 0}.

enclosing_name(Name) when is_atom(Name) ->
    Bin = atom_to_binary(Name, utf8),
    case Bin of
        <<"-", Rest/binary>> ->
            case binary:split(Rest, <<"/">>) of
                [Enclosing, _] -> Enclosing;
                _ -> Bin
            end;
        _ ->
            Bin
    end;
enclosing_name(_) ->
    <<"unknown">>.

%% The leaked processes still alive, oldest spawn first. Two exclusions.
%% Dead pids: a descendant whose trace was dropped (the nested case below)
%% never reports its exit, so the map can outlive it. vouch's own
%% scaffolding: the suite runs tests that run tests, and the inner test
%% process, its collector and the parallel middleman are all spawned inside
%% a traced tree — vouch's plumbing, not the user's leak, and killing our
%% own collector would be self-inflicted.
live_leaks(Live) ->
    Sorted = lists:sort(fun({_, {A, _}}, {_, {B, _}}) -> A =< B end,
                        maps:to_list(Live)),
    [{Pid, Origin}
     || {Pid, {_Key, Origin}} <- Sorted,
        not is_vouch_process(Origin),
        is_process_alive(Pid)].

is_vouch_process({process_leak, <<"vouch_ffi">>, _Function, _Arity}) -> true;
is_vouch_process(_) -> false.

leaks_of(Live) -> [Origin || {_Pid, Origin} <- live_leaks(Live)].

live_pids(Live) -> [Pid || {Pid, _Origin} <- live_leaks(Live)].

forward_crashes(TestPid, TestName) ->
    receive
        {trace, TestPid, exit, _Reason} ->
            forward_crashes(TestPid, TestName);
        {trace, _Pid, exit, Reason} ->
            case is_clean_exit(Reason) of
                true -> ok;
                false ->
                    catch ets:insert(vouch_unattributed,
                        {erlang:unique_integer([monotonic]), Reason,
                         {some, TestName}})
            end,
            forward_crashes(TestPid, TestName);
        _Other ->
            forward_crashes(TestPid, TestName)
    after 200 ->
        erlang:hibernate(?MODULE, forward_crashes, [TestPid, TestName])
    end.

is_clean_exit(normal) -> true;
is_clean_exit(shutdown) -> true;
is_clean_exit({shutdown, _}) -> true;
is_clean_exit(_) -> false.

%% Flush trace messages still in transit to their tracers (see run_test/4),
%% then take the collector's accumulated crash reasons and the processes the
%% test left running. The flush comes first so every death the test caused
%% on its own is already accounted for before the runner causes any itself.
claim_crashes(Collector, KillLeaked) ->
    flush_traces(),
    Ref = make_ref(),
    Collector ! {claim, self(), Ref, KillLeaked},
    {Reasons, Leaks} =
        receive {crashes, Ref, Rs, Ls} -> {Rs, Ls} after 5000 -> {[], []} end,
    case KillLeaked of
        true -> kill_leaked(Collector);
        false -> ok
    end,
    {reasons_to_reports(Reasons), Leaks}.

%% Take down what the test left running. A second round only if the first
%% killed anything: the one thing that can reappear is a child a supervisor
%% restarted, and the supervisor itself died in round one.
kill_leaked(Collector) ->
    case kill_round(Collector) of
        [] -> ok;
        _ -> kill_round(Collector)
    end,
    Ref = make_ref(),
    Collector ! {finish, self(), Ref},
    receive {finished, Ref} -> ok after 5000 -> ok end.

%% `kill` rather than `shutdown`, which a process trapping exits may ignore.
%% The flush afterwards puts the resulting exits in the collector's mailbox
%% before the next sweep reads its map, so a round's own kills never look
%% like survivors.
kill_round(Collector) ->
    Ref = make_ref(),
    Collector ! {sweep, self(), Ref},
    Pids = receive {swept, Ref, Ps} -> Ps after 5000 -> [] end,
    [exit(Pid, kill) || Pid <- Pids],
    flush_traces(),
    Pids.

flush_traces() ->
    Delivered = erlang:trace_delivered(all),
    receive {trace_delivered, all, Delivered} -> ok end.

%% Each crash reason as an outcome.CrashReport, whose single field the
%% Gleam side decodes exactly like a caught panic — find_panic reaches a
%% gleam_error map inside a {Reason, Stacktrace} exit, split_crash names the
%% top frame of anything else.
reasons_to_reports(Reasons) ->
    [{crash_report, Reason} || Reason <- Reasons].


%% Parallel execution: start one test without blocking on it. The spawned
%% middleman runs the same run_test/3 as the sequential path — identical
%% isolation, timeout and crash-report semantics — measures the duration,
%% and posts the result back tagged with a unique ref. The monitor covers
%% the theoretical case of the middleman dying before it reports.
start_test(Module, Function, TimeoutMs, KillLeaked) ->
    Self = self(),
    Ref = make_ref(),
    {_Pid, MonRef} = spawn_monitor(fun() ->
        Started = erlang:monotonic_time(microsecond),
        {Invocation, Reports} =
            run_test(Module, Function, TimeoutMs, KillLeaked),
        Duration = erlang:monotonic_time(microsecond) - Started,
        Self ! {vouch_parallel, Ref, Invocation, Reports, Duration}
    end),
    {Ref, MonRef}.

await_test({Ref, MonRef}) ->
    receive
        {vouch_parallel, Ref, Invocation, Reports, Duration} ->
            erlang:demonitor(MonRef, [flush]),
            {Invocation, Reports, Duration};
        {'DOWN', MonRef, process, _Pid, Reason} ->
            {{died, Reason}, [], 0}
    end.

schedulers_online() ->
    erlang:system_info(schedulers_online).

%% Call a function, capturing anything it throws. The reason is paired with
%% the stacktrace — for a non-Gleam crash (undef from a stale .beam, an FFI
%% error) the top frame is the only thing that names what failed, and
%% split_crash/1 reduces it to a site during classification. Gleam-side
%% decoding is unaffected: a Gleam panic's reason is a map tagged
%% gleam_error, which find_panic's recursive search still reaches inside the
%% extra tuple. The {Reason, Stacktrace} shape deliberately matches BEAM
%% exit reasons, so both feed the same split.
catch_panic(F) ->
    try
        F(),
        {ok, nil}
    catch
        error:Reason:Stacktrace -> {error, {Reason, Stacktrace}};
        Class:Reason:Stacktrace -> {error, {{Class, Reason}, Stacktrace}}
    end.

%% Split a raw caught term into the error reason and the crash site from the
%% top of its stacktrace. Fed by catch_panic's {Reason, Stacktrace} capture
%% and by exit reasons, which the BEAM already shapes the same way. A frame
%% carries the argument list instead of an arity when the arguments are
%% known — an undef frame always does. Tuple shapes must match the
%% CrashSite constructor in src/vouch/internal/outcome.gleam. Anything
%% unrecognised passes through untouched with no site.
split_crash({Reason, [{Module, Function, ArityOrArgs, Info} | _]})
    when is_atom(Module), is_atom(Function),
         is_list(ArityOrArgs) orelse is_integer(ArityOrArgs) ->
    Arity = case ArityOrArgs of
        Args when is_list(Args) -> length(Args);
        A -> A
    end,
    Site = {crash_site,
        atom_to_binary(Module, utf8),
        atom_to_binary(Function, utf8),
        Arity,
        frame_location(Info)},
    {Reason, {some, Site}};
split_crash(Raw) ->
    {Raw, none}.

frame_location(Info) when is_list(Info) ->
    case {lists:keyfind(file, 1, Info), lists:keyfind(line, 1, Info)} of
        {{file, File}, {line, Line}} when is_integer(Line) ->
            {some, {unicode:characters_to_binary(File), Line}};
        _ ->
            none
    end;
frame_location(_) ->
    none.

%% Decode a raw error term into vouch's GleamPanic type, or error for
%% anything that is not a Gleam panic. The panic map is searched for
%% recursively through nested tuples, because OTP wraps exit reasons: a todo
%% inside a gen_server callback reaches the caller as
%% {{Map, Stacktrace}, {gen_server, call, [...]}}, a plain error exit as
%% {Map, Stacktrace}, and vouch's own catch wrapper adds {Class, Reason}.
%% Tuple shapes must match the constructor definitions in
%% src/vouch/internal/gleam_panic.gleam.
decode_panic(Term) ->
    case find_panic(Term, 6) of
        {ok, Map} -> panic_from_map(Map);
        error -> {error, nil}
    end.

find_panic(#{gleam_error := _} = Map, _Depth) ->
    {ok, Map};
find_panic(Term, Depth) when is_tuple(Term), Depth > 0 ->
    find_panic_in(tuple_to_list(Term), Depth - 1);
find_panic(_, _) ->
    error.

find_panic_in([], _Depth) ->
    error;
find_panic_in([Head | Tail], Depth) ->
    case find_panic(Head, Depth) of
        {ok, Map} -> {ok, Map};
        error -> find_panic_in(Tail, Depth)
    end.

panic_from_map(#{
    gleam_error := assert,
    start := Start,
    'end' := End,
    expression_start := EStart
} = E) ->
    wrap(E, {assert, Start, End, EStart, assert_kind(E)});
panic_from_map(#{
    gleam_error := let_assert,
    start := Start,
    'end' := End,
    pattern_start := PStart,
    pattern_end := PEnd,
    value := Value
} = E) ->
    wrap(E, {let_assert, Start, End, PStart, PEnd, Value});
panic_from_map(#{gleam_error := panic} = E) ->
    wrap(E, panic);
panic_from_map(#{gleam_error := todo} = E) ->
    wrap(E, todo);
panic_from_map(_) ->
    {error, nil}.

assert_kind(#{kind := binary_operator, left := L, right := R, operator := O}) ->
    {binary_operator, atom_to_binary(O, utf8), expression(L), expression(R)};
assert_kind(#{kind := function_call, arguments := Arguments}) ->
    {function_call, lists:map(fun expression/1, Arguments)};
assert_kind(#{kind := expression, expression := Expression}) ->
    {other_expression, expression(Expression)}.

expression(#{start := S, 'end' := E, kind := literal, value := Value}) ->
    {asserted_expression, S, E, {literal, Value}};
expression(#{start := S, 'end' := E, kind := expression, value := Value}) ->
    {asserted_expression, S, E, {expression, Value}};
expression(#{start := S, 'end' := E, kind := unevaluated}) ->
    {asserted_expression, S, E, unevaluated}.

wrap(#{
    file := File,
    message := Message,
    module := Module,
    function := Function,
    line := Line
}, Kind) ->
    {ok, {gleam_panic, Message, File, Module, Function, Line, Kind}}.

halt(Code) ->
    erlang:halt(Code),
    nil.

%% On the BEAM halt is already immediate; the distinction only matters on
%% JavaScript, where halt/1 defers to a callback the blocked watch loop
%% can never run. erlang:halt directly, not the local halt/1 — calling
%% that is an ambiguous-BIF error on older toolchains.
halt_now(Code) ->
    erlang:halt(Code),
    nil.

%% Watch-mode primitives. One row per file under the given roots (a root may
%% be a file or a directory, searched recursively): path, mtime in gregorian
%% seconds, size in bytes. Sorted so two snapshots of an unchanged tree
%% compare equal regardless of traversal order.
file_snapshot(Roots) ->
    lists:sort(lists:flatmap(fun snapshot_root/1, Roots)).

snapshot_root(Root) ->
    Path = unicode:characters_to_list(Root),
    case filelib:is_dir(Path) of
        true ->
            filelib:fold_files(Path, ".*", true, fun(File, Acc) ->
                [snapshot_entry(File) | Acc]
            end, []);
        false ->
            case filelib:is_regular(Path) of
                true -> [snapshot_entry(Path)];
                false -> []
            end
    end.

snapshot_entry(Path) ->
    Seconds = case filelib:last_modified(Path) of
        0 -> 0;
        DateTime -> calendar:datetime_to_gregorian_seconds(DateTime)
    end,
    {unicode:characters_to_binary(Path), Seconds, filelib:file_size(Path)}.

%% Spawn a command with its stdout streamed through to ours as chunks
%% arrive; stderr is inherited by the child directly, so build-tool
%% diagnostics keep their usual destination. Returns the exit code.
%% exit_status can overtake data still in flight (its order relative to
%% the stream is unspecified), so the port is opened with eof and the
%% loop runs until both the stream end and the exit code have arrived.
run_passthrough(Command, Args) ->
    case os:find_executable(unicode:characters_to_list(Command)) of
        false ->
            {error, nil};
        Exe ->
            Port = open_port({spawn_executable, Exe}, [
                {args, [unicode:characters_to_list(A) || A <- Args]},
                exit_status,
                eof,
                binary,
                hide
            ]),
            stream_through(Port, undefined, false)
    end.

stream_through(Port, Code, GotEof) ->
    receive
        {Port, {data, Data}} ->
            io:put_chars(Data),
            stream_through(Port, Code, GotEof);
        {Port, eof} when Code =/= undefined ->
            catch port_close(Port),
            {ok, Code};
        {Port, eof} ->
            stream_through(Port, Code, true);
        {Port, {exit_status, Status}} when GotEof ->
            catch port_close(Port),
            {ok, Status};
        {Port, {exit_status, Status}} ->
            stream_through(Port, Status, GotEof)
    end.

sleep_ms(Ms) ->
    receive after Ms -> nil end.

%% Watch mode prints non-ASCII glyphs. Terminals get unicode encoding
%% by default, but a redirected stream can come up latin1 (the pre-OTP-26
%% default off a tty, and C locales since), where those glyphs raise
%% no_translation instead of printing. Pin both standard streams to
%% unicode so redirected output degrades to UTF-8 bytes in a file.
ensure_unicode_stdio() ->
    catch io:setopts(standard_io, [{encoding, unicode}]),
    catch io:setopts(standard_error, [{encoding, unicode}]),
    nil.

%% Quitting the watch loop: a stdin listener that halts on "q" + Enter.
%% This is the only clean quit the BEAM allows a long-running foreground
%% program: SIGINT belongs to the emulator's break handler and cannot be
%% taken over (os:set_signal(sigint, handle) is badarg), and booting with
%% +Bd/+Bi merely turns Ctrl+C into a no-op, so Ctrl+C either opens the
%% BREAK menu or does nothing. The inner runs never contend for stdin —
%% their ports get pipes. eof means stdin is not interactive (piped or
%% closed), so the listener just retires rather than treating it as a
%% quit.
%%
%% Callers must only install this when stdout is a terminal: with stdout
%% redirected on Windows, the read itself is fatal — prim_tty's reader
%% dies on ReadConsoleW before ever returning eof, and its crash takes
%% user_drv (and with it every subsequent stdout write) down too.
install_quit_hooks() ->
    spawn(fun quit_listener/0),
    nil.

%% The watch loop polls this for the JavaScript interactive keys
%% (Enter / a / q). The BEAM has no key worker — its quit listener
%% handles stdin — so there is never a pending key here.
take_pending_key() -> 0.

%% Unreachable: print_status only asks on the JavaScript target.
keys_active() -> erlang:error(javascript_only).

quit_listener() ->
    case io:get_line("") of
        eof ->
            ok;
        {error, _} ->
            ok;
        Line ->
            case string:trim(unicode:characters_to_list(Line)) of
                "q" -> erlang:halt(0);
                "quit" -> erlang:halt(0);
                _ -> quit_listener()
            end
    end.

beam_name(ModuleName) ->
    binary:replace(ModuleName, <<"/">>, <<"@">>, [global]).
