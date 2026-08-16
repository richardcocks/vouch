%% Test-only helper: run a command in a directory, capturing stdout and the
%% exit code. stderr is deliberately not captured — the e2e tests assert
%% that stdout alone is a clean stream.
-module(vouch_e2e_ffi).
-export([run_command/3]).

run_command(Command, Args, Dir) ->
    case os:find_executable(unicode:characters_to_list(Command)) of
        false ->
            {error, nil};
        Exe ->
            Port = open_port({spawn_executable, Exe}, [
                {args, [unicode:characters_to_list(A) || A <- Args]},
                {cd, unicode:characters_to_list(Dir)},
                exit_status,
                eof,
                binary,
                hide
            ]),
            collect(Port, [], undefined, false)
    end.

%% Data messages arrive in stream order and eof marks the end of the
%% stream, but exit_status is delivered independently: the docs leave its
%% order relative to eof unspecified, and it can overtake data still in
%% flight. Waiting for both eof and exit_status is the only way to get the
%% complete stream alongside the code.
collect(Port, Acc, Code, GotEof) ->
    receive
        {Port, {data, Data}} ->
            collect(Port, [Data | Acc], Code, GotEof);
        {Port, eof} when Code =/= undefined ->
            finish(Port, Acc, Code);
        {Port, eof} ->
            collect(Port, Acc, Code, true);
        {Port, {exit_status, Status}} when GotEof ->
            finish(Port, Acc, Status);
        {Port, {exit_status, Status}} ->
            collect(Port, Acc, Status, false)
    end.

finish(Port, Acc, Code) ->
    catch port_close(Port),
    {ok, {Code, unicode:characters_to_binary(lists:reverse(Acc))}}.
