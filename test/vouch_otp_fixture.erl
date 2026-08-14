%% A minimal real gen_server whose handle_call runs unimplemented Gleam
%% code. Not a *_test module, so it is never discovered; the suite calls
%% call_into_todo/0 to prove that a todo raised inside an OTP process is
%% still classified as a Todo outcome, not an opaque failure.
-module(vouch_otp_fixture).
-behaviour(gen_server).
-export([call_into_todo/0, init/1, handle_call/3, handle_cast/2]).

call_into_todo() ->
    {ok, Pid} = gen_server:start(?MODULE, nil, []),
    gen_server:call(Pid, go).

init(nil) ->
    {ok, nil}.

handle_call(go, _From, State) ->
    helpers:unimplemented(),
    {reply, ok, State}.

handle_cast(_Msg, State) ->
    {noreply, State}.
