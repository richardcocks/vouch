-module(playground_ffi).
-export([sleep/1]).

sleep(Ms) ->
    timer:sleep(Ms),
    nil.
