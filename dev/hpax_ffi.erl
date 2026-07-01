-module(hpax_ffi).

-export([new/1, resize/2, decode/2, encode_store/2]).

new(MaxSize) ->
    'Elixir.HPAX':new(MaxSize).

resize(Table, NewSize) ->
    'Elixir.HPAX':resize(Table, NewSize).

decode(Data, Table) ->
    'Elixir.HPAX':decode(Data, Table).

encode_store(Headers, Table) ->
    Store = lists:map(fun({Name, Value}) -> {store, Name, Value} end, Headers),
    {IoData, Table2} = 'Elixir.HPAX':encode(Store, Table),
    {erlang:iolist_to_binary(IoData), Table2}.
