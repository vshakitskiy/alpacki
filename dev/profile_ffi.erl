-module(profile_ffi).

-export([eprof/1]).

eprof(Fun) ->
    {ok, _Pid} = eprof:start(),
    eprof:start_profiling([self()]),
    Result = Fun(),
    eprof:stop_profiling(),
    eprof:analyze(total),
    eprof:stop(),
    Result.
