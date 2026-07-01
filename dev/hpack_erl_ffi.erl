-module(hpack_erl_ffi).

-export([new/1, resize/2, decode/2, encode/2]).

new(MaxSize) ->
    hpack:new_context(MaxSize).

resize(Table, NewSize) ->
    hpack:new_max_table_size(NewSize, Table).

decode(Data, Context) ->
    hpack:decode(Data, Context).

encode(Headers, Context) ->
    {ok, {Bin, NewContext}} = hpack:encode(Headers, Context),
    {Bin, NewContext}.
