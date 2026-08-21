-module(vouch_ffi).
-export([
    find_test_files/0,
    exported_zero_arity/1,
    run_test/3,
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
    crash_filter/2,
    log/2,
    forward_io/1,
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
    start_test/3,
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

%% BEAM crash reports — a process dying with an uncaught error (the
%% emulator's "Error in process"), a proc_lib CRASH REPORT, a gen_*
%% "terminating" report, a supervisor's child-died report — are diverted
%% away from the default logger handler into a public ETS table. The runner
%% reads that table after each test and charges each report to the test
%% whose process died (see the per-test group leaders in run_test/3), so a
%% worker that crashes behind an otherwise passing test still turns the
%% test red; the raw report text is printed only on request
%% (--show-crash-reports). Everything else routed through logger (a
%% library's warnings, a test's own log lines) is not a crash and still
%% prints, via the default handler moved to stderr so it cannot corrupt a
%% machine-read stdout stream.
%%
%% This module doubles as the capture handler: crash_filter/2 selects the
%% events and log/2 stores each one rendered with the default handler's own
%% formatter. If the capture handler cannot be installed, reports stay on
%% stderr — still better than corrupting stdout.
capture_diagnostics() ->
    catch case logger:get_handler_config(vouch_diagnostics) of
        {ok, _} ->
            %% Already capturing; installing twice would double reports.
            ok;
        _ ->
            case logger:get_handler_config(default) of
                {ok, #{formatter := Formatter}} ->
                    ensure_diagnostics_table(),
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

%% Rows are {Key, GroupLeader, Text, Reason, Claimed} for captured reports
%% (Key from unique_integer([monotonic]), so arrival order is table order)
%% and {{test, GroupLeader}, Module, Function} naming the test each
%% per-test group leader belongs to.
ensure_diagnostics_table() ->
    case ets:whereis(vouch_diagnostics) of
        undefined ->
            %% Owned by the runner process, which lives until halt.
            ets:new(vouch_diagnostics, [named_table, public, ordered_set]);
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

%% Logger handler callback, installed by capture_diagnostics/0. Runs in the
%% logging process for logger API calls and in the logger server for
%% emulator-generated reports; either way, render now and append. Must
%% never raise: logger removes a handler whose callback crashes.
log(#{meta := Meta} = Event, Config) ->
    catch ets:insert(vouch_diagnostics, {
        erlang:unique_integer([monotonic]),
        maps:get(gl, Meta, undefined),
        render_diagnostic(Event, Config),
        report_reason(Event),
        false
    }),
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

%% The exit reason a crash report carries, in the {Reason, Stacktrace} shape
%% catch_panic produces, so the Gleam side decodes a report exactly like a
%% caught panic: find_panic reaches a gleam_error map inside it and
%% split_crash names the top frame of anything else. Unknown report shapes
%% pass the whole message through.
report_reason(#{msg := {_Format, Args}, meta := #{error_logger := #{emulator := true}}})
        when is_list(Args), Args =/= [] ->
    %% "Error in process ~p [on node ~p] with exit value:~n~p~n": the exit
    %% value is the last argument, already {Reason, Stacktrace}.
    lists:last(Args);
report_reason(#{msg := {report, #{label := {proc_lib, crash}, report := [Info | _]}}})
        when is_list(Info) ->
    case lists:keyfind(error_info, 1, Info) of
        {error_info, {error, Reason, Stack}} -> {Reason, Stack};
        {error_info, {Class, Reason, Stack}} -> {{Class, Reason}, Stack};
        _ -> Info
    end;
report_reason(#{msg := {report, #{label := {_, terminate}, reason := Reason}}}) ->
    Reason;
report_reason(#{msg := {report, #{label := {supervisor, _}, report := Report}}})
        when is_list(Report) ->
    case lists:keyfind(reason, 1, Report) of
        {reason, Reason} -> Reason;
        false -> Report
    end;
report_reason(#{msg := Msg}) ->
    Msg.

%% Every captured report's text, in arrival order, for --show-crash-reports.
all_diagnostics() ->
    flush_logger(),
    [Text || {Key, _GL, Text, _Reason, _Claimed} <- rows(), is_integer(Key)].

%% The reports no test claimed — arrived after their test had finished, or
%% from a process no test started — each with the test its group leader
%% belonged to, when there was one. The run fails on these: a crash the
%% outcomes do not account for must not hide behind a green summary.
unattributed_diagnostics() ->
    flush_logger(),
    [{Text, test_of(GL)}
     || {Key, GL, Text, _Reason, false} <- rows(), is_integer(Key)].

test_of(GL) ->
    case catch ets:lookup(vouch_diagnostics, {test, GL}) of
        [{_, Module, Function}] -> {some, {Module, Function}};
        _ -> none
    end.

%% Remove and return only the captured reports whose text contains Marker,
%% leaving the rest alone. The suite-facing probe: a test that deliberately
%% crashes a process in its own process tree can consume the report (so it
%% is not charged to the test) and assert it was captured rather than
%% printed, without touching reports that belong to other tests.
take_diagnostics_matching(Marker) ->
    flush_logger(),
    [begin
         catch ets:delete(vouch_diagnostics, Key),
         Text
     end
     || {Key, _GL, Text, _Reason, _Claimed} <- rows(),
        is_integer(Key), binary:match(Text, Marker) =/= nomatch].

rows() ->
    case catch ets:tab2list(vouch_diagnostics) of
        Rows when is_list(Rows) -> Rows;
        _ -> []
    end.

%% Emulator-generated reports ("Error in process") are handled in the
%% logger_proxy process, whose mailbox they travel through; API-call events
%% (proc_lib, gen_server) are handled in the logging process itself, before
%% the crash propagates. A synchronous round-trip through logger_proxy makes
%% sure everything already sent is in the table before it is read. The
%% emulator sends the report before the dying process's exit signals and
%% monitors fire, so a death the test observed is always in the table by
%% the time the test's result reaches the runner. The logger server itself
%% is round-tripped too, cheaply, in case an OTP release routes through it.
flush_logger() ->
    catch sys:get_state(logger_proxy, 1000),
    catch sys:get_state(logger, 1000).

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
%% a constructor of vouch/internal/outcome.Invocation, and the crash reports
%% of processes the test started that died while it ran (outcome.CrashReport
%% tuples), which the runner folds into the test's outcome.
%%
%% The test process runs under its own group leader, a proxy that forwards
%% io to the real one (start_group_leader/2). Every process the test starts
%% inherits it, and every crash report the BEAM logs names the dying
%% process's group leader, so a report is charged to exactly the test whose
%% process died — in a parallel run as much as a sequential one — and a
%% report that arrives late can still say which test it belonged to.
run_test(ModuleName, FunctionName, TimeoutMs) ->
    Module = binary_to_atom(beam_name(ModuleName), utf8),
    Function = binary_to_atom(FunctionName, utf8),
    Self = self(),
    Leader = start_group_leader(ModuleName, FunctionName),
    {Pid, Ref} = spawn_monitor(fun() ->
        group_leader(Leader, self()),
        Self ! {vouch_result, self(), catch_panic(fun() -> Module:Function() end)}
    end),
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
    {Invocation, claim_crash_reports(Leader)}.

%% A group leader for one test: forwards every message (io requests, whose
%% replies go straight back to the requester) to the real group leader, so
%% tests and their processes print exactly as before. It is never stopped:
%% a worker the test left running may still be printing through it after
%% the test is over, and an io request to a dead leader raises. Idle
%% leaders hibernate down to a few hundred bytes each.
start_group_leader(ModuleName, FunctionName) ->
    Real = group_leader(),
    Leader = spawn(?MODULE, forward_io, [Real]),
    catch ets:insert(vouch_diagnostics, {{test, Leader}, ModuleName, FunctionName}),
    Leader.

forward_io(Real) ->
    receive
        Message ->
            Real ! Message,
            forward_io(Real)
    after 200 ->
        erlang:hibernate(?MODULE, forward_io, [Real])
    end.

%% The captured crash reports of processes under Leader, oldest first, each
%% marked claimed so the end-of-run sweep for unattributed reports skips
%% it. Flushing first is what makes this deterministic for a death the test
%% observed (see flush_logger/0).
claim_crash_reports(Leader) ->
    flush_logger(),
    case catch ets:select(vouch_diagnostics,
            [{{'$1', Leader, '$2', '$3', false},
              [{is_integer, '$1'}],
              [{{'$1', '$2', '$3'}}]}]) of
        Rows when is_list(Rows) ->
            [begin
                 catch ets:update_element(vouch_diagnostics, Key, {5, true}),
                 {crash_report, Reason, Text}
             end || {Key, Text, Reason} <- Rows];
        _ ->
            []
    end.


%% Parallel execution: start one test without blocking on it. The spawned
%% middleman runs the same run_test/3 as the sequential path — identical
%% isolation, timeout and crash-report semantics — measures the duration,
%% and posts the result back tagged with a unique ref. The monitor covers
%% the theoretical case of the middleman dying before it reports.
start_test(Module, Function, TimeoutMs) ->
    Self = self(),
    Ref = make_ref(),
    {_Pid, MonRef} = spawn_monitor(fun() ->
        Started = erlang:monotonic_time(microsecond),
        {Invocation, Reports} = run_test(Module, Function, TimeoutMs),
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
