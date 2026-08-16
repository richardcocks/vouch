#!/usr/bin/env escript
%% Soak harness for the intermittent vouch_e2e_test.playground_erlang_e2e_test
%% all_json_objects failure. Runs `gleam test -- --format=json` in a project
%% directory repeatedly, capturing stdout through a port exactly the way
%% test/vouch_e2e_ffi.erl does (mode "plain": exit_status option, no eof,
%% drain with `after 0`), or through an eof-correct variant (mode "eof").
%% Any capture whose stdout is not purely JSON-object lines (or that lacks
%% the run_end event, or exits with a code other than 1) is written to
%% OutDir for inspection.
%%
%% Usage:
%%   escript e2e_soak.escript plain|eof N ProjectDir OutDir [Prep]
%% Prep:
%%   none          - steady-state runs (default)
%%   touch:<file>  - append a unique comment to <file> before each run,
%%                   forcing a recompile (restored afterwards)
%%   wipe:<dir>    - delete <dir> before each run (e.g. the build directory,
%%                   recreating the cold first-run condition)

main([ModeStr, NStr, Dir, OutDir]) ->
    main([ModeStr, NStr, Dir, OutDir, "none"]);
main([ModeStr, NStr, Dir, OutDir, PrepStr]) ->
    Mode = list_to_atom(ModeStr),
    N = list_to_integer(NStr),
    Prep = parse_prep(PrepStr),
    ok = filelib:ensure_path(OutDir),
    Fails = loop(Mode, 1, N, Dir, OutDir, Prep, 0),
    restore(Prep),
    io:format("done mode=~s prep=~s iterations=~p failures=~p~n",
        [ModeStr, PrepStr, N, Fails]),
    case Fails of
        0 -> halt(0);
        _ -> halt(1)
    end.

parse_prep("none") ->
    none;
parse_prep("touch:" ++ Path) ->
    {ok, Original} = file:read_file(Path),
    {touch, Path, Original};
parse_prep("wipe:" ++ Path) ->
    {wipe, Path}.

restore({touch, Path, Original}) ->
    ok = file:write_file(Path, Original);
restore(_) ->
    ok.

prepare(none, _I) ->
    ok;
prepare({touch, Path, Original}, I) ->
    Extra = io_lib:format("// soak iteration ~p~n", [I]),
    ok = file:write_file(Path, [Original, Extra]);
prepare({wipe, Path}, _I) ->
    case filelib:is_dir(Path) of
        true -> ok = file:del_dir_r(Path);
        false -> ok
    end.

loop(_, I, N, _, _, _, Fails) when I > N ->
    Fails;
loop(Mode, I, N, Dir, OutDir, Prep, Fails) ->
    case I rem 25 of
        0 -> io:format("progress ~p/~p failures=~p~n", [I, N, Fails]);
        _ -> ok
    end,
    prepare(Prep, I),
    {Code, Out} = run(Mode, Dir),
    Trimmed = string:trim(Out),
    Lines = binary:split(Trimmed, <<"\n">>, [global]),
    Bad = [L || L <- Lines, not json_line(L)],
    HasRunEnd = binary:match(Out, <<"\"event\":\"run_end\"">>) =/= nomatch,
    case {Code, Bad, HasRunEnd} of
        {1, [], true} ->
            loop(Mode, I + 1, N, Dir, OutDir, Prep, Fails);
        _ ->
            File = filename:join(OutDir,
                lists:flatten(io_lib:format("bad_~s_~p.txt", [Mode, I]))),
            ok = file:write_file(File, Out),
            io:format("ITER ~p code=~p run_end=~p bad_lines=~p~n",
                [I, Code, HasRunEnd, [clip(L) || L <- Bad]]),
            loop(Mode, I + 1, N, Dir, OutDir, Prep, Fails + 1)
    end.

clip(L) when byte_size(L) > 120 ->
    <<Head:60/binary, _/binary>> = L,
    Tail = binary:part(L, byte_size(L) - 60, 60),
    {clipped, byte_size(L), Head, Tail};
clip(L) ->
    L.

json_line(<<>>) ->
    false;
json_line(<<"{", _/binary>> = L) ->
    binary:last(L) =:= $};
json_line(_) ->
    false.

run(Mode, Dir) ->
    Exe = case os:find_executable("gleam") of
        false -> erlang:error(no_gleam);
        E -> E
    end,
    Opts0 = [
        {args, ["test", "--", "--format=json"]},
        {cd, Dir},
        exit_status,
        binary,
        hide
    ],
    Opts = case Mode of
        eof -> [eof | Opts0];
        plain -> Opts0
    end,
    Port = open_port({spawn_executable, Exe}, Opts),
    case Mode of
        plain -> collect_plain(Port, []);
        eof -> collect_eof(Port, [], undefined, false)
    end.

%% Exactly the shape of vouch_e2e_ffi:collect/2 + drain/2.
collect_plain(Port, Acc) ->
    receive
        {Port, {data, Data}} ->
            collect_plain(Port, [Data | Acc]);
        {Port, {exit_status, Code}} ->
            Output = drain_plain(Port, Acc),
            {Code, unicode:characters_to_binary(lists:reverse(Output))}
    end.

drain_plain(Port, Acc) ->
    receive
        {Port, {data, Data}} -> drain_plain(Port, [Data | Acc])
    after 0 ->
        Acc
    end.

%% Wait for both eof (stream fully read) and exit_status, in either order.
collect_eof(Port, Acc, Code, GotEof) ->
    receive
        {Port, {data, Data}} ->
            collect_eof(Port, [Data | Acc], Code, GotEof);
        {Port, eof} when Code =/= undefined ->
            {Code, unicode:characters_to_binary(lists:reverse(Acc))};
        {Port, eof} ->
            collect_eof(Port, Acc, Code, true);
        {Port, {exit_status, C}} when GotEof ->
            {C, unicode:characters_to_binary(lists:reverse(Acc))};
        {Port, {exit_status, C}} ->
            collect_eof(Port, Acc, C, GotEof)
    end.
