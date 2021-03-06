%% @doc: Space-efficient dictionary implemented using a binary
%%
%% This module implements a space-efficient dictionary with no
%% overhead per entry. Read and write access is O(log n).
%%
%% Keys and values are fixed size binaries stored ordered in a larger
%% binary which acts as a sparse array. All operations are implemented
%% using a binary search.
%%
%% As large binaries can be shared among processes, there can be
%% multiple concurrent readers of an instance of this structure.
%%
%% serialize/1 and deserialize/1
-module(bisect).
-author('Knut Nesheim <knutin@gmail.com>').

-export([new/2, new/3, insert/3, bulk_insert/2, append/3, find/2, foldl/3]).
-export([next/2, next_nth/3, first/1, last/1, delete/2, compact/1, cas/4, update/4]).
-export([serialize/1, deserialize/1, from_orddict/2, to_orddict/1, find_many/2]).
-export([merge/2, intersection/1, intersection/2]).
-export([expected_size/2, expected_size_mb/2, num_keys/1, size/1]).

-compile({no_auto_import, [size/1]}).
-compile(native).

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.


%%
%% TYPES
%%

-type key_size()   :: pos_integer().
-type value_size() :: pos_integer().
-type block_size() :: pos_integer().

-type key()        :: binary().
-type value()      :: binary().

-type index()      :: pos_integer().

-record(bindict, {
          key_size   :: key_size(),
          value_size :: value_size(),
          block_size :: block_size(),
          b          :: binary()
}).
-type bindict() :: #bindict{}.


%%
%% API
%%

-spec new(key_size(), value_size()) -> bindict().
%% @doc: Returns a new empty dictionary where where the keys and
%% values will always be of the given size.
new(KeySize, ValueSize) when is_integer(KeySize)
                             andalso is_integer(ValueSize) ->
    new(KeySize, ValueSize, <<>>).

-spec new(key_size(), value_size(), binary()) -> bindict().
%% @doc: Returns a new dictionary with the given data
new(KeySize, ValueSize, Data) when is_integer(KeySize)
                                   andalso is_integer(ValueSize)
                                   andalso is_binary(Data) ->
    #bindict{key_size = KeySize,
             value_size = ValueSize,
             block_size = KeySize + ValueSize,
             b = Data}.


-spec insert(bindict(), key(), value()) -> bindict().
%% @doc: Inserts the key and value into the dictionary. If the size of
%% key and value is wrong, throws badarg. If the key is already in the
%% array, the value is updated.
insert(B, K, V) when byte_size(K) =/= B#bindict.key_size orelse
                     byte_size(V) =/= B#bindict.value_size ->
    erlang:error(badarg);

insert(#bindict{b = <<>>} = B, K, V) ->
    B#bindict{b = <<K/binary, V/binary>>};

insert(B, K, V) ->
    Index = index(B, K),
    LeftOffset = Index * B#bindict.block_size,
    RightOffset = byte_size(B#bindict.b) - LeftOffset,

    KeySize = B#bindict.key_size,
    ValueSize = B#bindict.value_size,

    case B#bindict.b of
        <<Left:LeftOffset/binary, K:KeySize/binary, _:ValueSize/binary, Right/binary>> ->
            B#bindict{b = iolist_to_binary([Left, K, V, Right])};

        <<Left:LeftOffset/binary, Right:RightOffset/binary>> ->
            B#bindict{b = iolist_to_binary([Left, K, V, Right])}
    end.

%% @doc: Update the value stored under the key by calling F on the old
%% value to get a new value. If the key is not present, initial will
%% be stored as the first value. Same as dict:update/4. Note: find and
%% insert requires two binary searches in the binary, while update
%% only needs one. It's as close to in-place update we can get in pure
%% Erlang.
update(B, K, Initial, F) when byte_size(K) =/= B#bindict.key_size orelse
                              byte_size(Initial) =/= B#bindict.value_size orelse
                              not is_function(F) ->
    erlang:error(badarg);

update(B, K, Initial, F) ->
    Index = index(B, K),
    LeftOffset = Index * B#bindict.block_size,
    RightOffset = byte_size(B#bindict.b) - LeftOffset,

    KeySize = B#bindict.key_size,
    ValueSize = B#bindict.value_size,

    case B#bindict.b of
        <<Left:LeftOffset/binary, K:KeySize/binary, OldV:ValueSize/binary, Right/binary>> ->
            case F(OldV) of
                OldV ->
                    B;
                NewV ->
                    byte_size(NewV) =:= ValueSize orelse erlang:error(badarg),
                    B#bindict{b = iolist_to_binary([Left, K, NewV, Right])}
            end;

        <<Left:LeftOffset/binary, Right:RightOffset/binary>> ->
            B#bindict{b = iolist_to_binary([Left, K, Initial, Right])}
    end.

-spec append(bindict(), key(), value()) -> bindict().
%% @doc: Append a key and value. This is only useful if the key is known
%% to be larger than any other key. Otherwise it will corrupt the bindict.
append(B, K, V) when byte_size(K) =/= B#bindict.key_size orelse
                     byte_size(V) =/= B#bindict.value_size ->
    erlang:error(badarg);

append(B, K, V) ->
    case last(B) of
        {KLast, _} when K =< KLast ->
          erlang:error(badarg);
        _ ->
          Bin = B#bindict.b,
          B#bindict{b = <<Bin/binary, K/binary, V/binary>>}
    end.

-spec cas(bindict(), key(), value() | 'not_found', value()) -> bindict().
%% @doc: Check-and-set operation. If 'not_found' is specified as the
%% old value, the key should not exist in the array. Provided for use
%% by bisect_server.
cas(B, K, OldV, V) ->
    case find(B, K) of
        OldV ->
            insert(B, K, V);
        _OtherV ->
            error(badarg)
    end.


-spec find(bindict(), key()) -> value() | not_found.
%% @doc: Returns the value associated with the key or 'not_found' if
%% there is no such key.
find(B, K) ->
    case at(B, index(B, K)) of
        {K, Value}   -> Value;
        {_OtherK, _} -> not_found;
        not_found    -> not_found
    end.

-spec find_many(bindict(), [key()]) -> [value() | not_found].
find_many(B, Keys) ->
    lists:map(fun (K) -> find(B, K) end, Keys).

-spec delete(bindict(), key()) -> bindict().
delete(B, K) ->
    LeftOffset = index2offset(B, index(B, K)),
    KeySize = B#bindict.key_size,
    ValueSize = B#bindict.value_size,

    case B#bindict.b of
        <<Left:LeftOffset/binary, K:KeySize/binary, _:ValueSize/binary, Right/binary>> ->
            B#bindict{b = <<Left/binary, Right/binary>>};
        _ ->
            erlang:error(badarg)
    end.

-spec next(bindict(), key()) -> {key(), value()} | not_found.
%% @doc: Returns the next larger key and value associated with it or
%% 'not_found' if no larger key exists.
next(B, K) ->
  next_nth(B, K, 1).

%% @doc: Returns the nth next larger key and value associated with it
%% or 'not_found' if it does not exist.
-spec next_nth(bindict(), key(), non_neg_integer()) -> value() | not_found.
next_nth(B, K, Steps) ->
    at(B, index(B, inc(K)) + Steps - 1).



-spec first(bindict()) -> {key(), value()} | not_found.
%% @doc: Returns the first key-value pair or 'not_found' if the dict is empty
first(B) ->
    at(B, 0).

-spec last(bindict()) -> {key(), value()} | not_found.
%% @doc: Returns the last key-value pair or 'not_found' if the dict is empty
last(B) ->
    at(B, num_keys(B) - 1).

-spec foldl(bindict(), fun(), any()) -> any().
foldl(B, F, Acc) ->
    case first(B) of
        {Key, Value} ->
            do_foldl(B, F, Key, F(Key, Value, Acc));
        not_found ->
            []
    end.

do_foldl(B, F, PrevKey, Acc) ->
    case next(B, PrevKey) of
        {Key, Value} ->
            do_foldl(B, F, Key, F(Key, Value, Acc));
        not_found ->
            Acc
    end.


%% @doc: Compacts the internal binary used for storage, by creating a
%% new copy where all the data is aligned in memory. Writes will cause
%% fragmentation.
compact(B) ->
    B#bindict{b = binary:copy(B#bindict.b)}.

%% @doc: Returns how many bytes would be used by the structure if it
%% was storing NumKeys.
expected_size(B, NumKeys) ->
    B#bindict.block_size * NumKeys.

expected_size_mb(B, NumKeys) ->
    expected_size(B, NumKeys) / 1024 / 1024.

-spec num_keys(bindict()) -> integer().
%% @doc: Returns the number of keys in the dictionary
num_keys(B) ->
    byte_size(B#bindict.b) div B#bindict.block_size.

size(#bindict{b = B}) ->
    erlang:byte_size(B).


-spec serialize(bindict()) -> binary().
%% @doc: Returns a binary representation of the dictionary which can
%% be deserialized later to recreate the same structure.
serialize(#bindict{} = B) ->
    term_to_binary(B).

-spec deserialize(binary()) -> bindict().
deserialize(Bin) ->
    case binary_to_term(Bin) of
        #bindict{} = B ->
            B;
        _ ->
            erlang:error(badarg)
    end.

%% @doc: Insert a batch of key-value pairs into the dictionary. A new
%% binary is only created once, making it much cheaper than individual
%% calls to insert/2. The input list must be sorted.
bulk_insert(#bindict{} = B, Orddict) ->
    L = do_bulk_insert(B, B#bindict.b, [], Orddict),
    B#bindict{b = iolist_to_binary(lists:reverse(L))}.

do_bulk_insert(_B, Bin, Acc, []) ->
    [Bin | Acc];
do_bulk_insert(B, Bin, Acc, [{Key, Value} | Rest]) ->
    {Left, Right} = split_at(Bin, B#bindict.key_size, B#bindict.value_size, Key, 0),
    do_bulk_insert(B, Right, [Value, Key, Left | Acc], Rest).

split_at(Bin, KeySize, ValueSize, Key, I) ->
    LeftOffset = I * (KeySize + ValueSize),
    case Bin of
        Bin when byte_size(Bin) < LeftOffset ->
            {Bin, <<>>};

        <<Left:LeftOffset/binary,
          Key:KeySize/binary, _:ValueSize/binary,
          Right/binary>> ->
            {Left, Right};

        <<Left:LeftOffset/binary,
          OtherKey:KeySize/binary, Value:ValueSize/binary,
          Right/binary>> when OtherKey > Key ->
            NewRight = <<OtherKey/binary, Value/binary, Right/binary>>,
            {Left, NewRight};
        _ ->
            split_at(Bin, KeySize, ValueSize, Key, I+1)
    end.

merge(Small, Big) ->
    Small#bindict.block_size =:= Big#bindict.block_size
        orelse erlang:error(badarg),

    L = do_merge(Small#bindict.b, Big#bindict.b, [],
                 Big#bindict.key_size, Big#bindict.value_size),
    Big#bindict{b = iolist_to_binary(L)}.

do_merge(Small, Big, Acc, KeySize, ValueSize) ->
    case Small of
        <<Key:KeySize/binary, Value:ValueSize/binary, RestSmall/binary>> ->
            {LeftBig, RightBig} = split_at(Big, KeySize, ValueSize, Key, 0),
            do_merge(RestSmall, RightBig, [Value, Key, LeftBig | Acc],
                     KeySize, ValueSize);
        <<>> ->
            lists:reverse([Big | Acc])
    end.

%% @doc: Intersect two or more bindicts by key. The resulting bindict
%% contains keys found in all input bindicts.
intersection(Bs) when length(Bs) >= 2 ->
    intersection(Bs, svs);
intersection(_TooFewSets) ->
    erlang:error(badarg).

%% @doc: SvS set intersection algorithm, as described in
%% http://www.cs.toronto.edu/~tl/papers/fiats.pdf
intersection(Bs, svs) ->
    [CandidateSet | Sets] = lists:sort(fun (A, B) -> size(A) =< size(B) end, Bs),
    from_orddict(new(CandidateSet#bindict.key_size,
                     CandidateSet#bindict.value_size),
                 do_svs(Sets, CandidateSet)).

do_svs([], Candidates) ->
    Candidates;
do_svs([Set | Sets], #bindict{} = Candidates) ->
    %% Optimization: we let the candidate set remain a bindict for the
    %% first iteration to avoid creating a large orddict just to throw
    %% most of it away. For the remainding sets, we keep the candidate
    %% set as a list
    {_, NewCandidatesList} =
        foldl(Candidates,
              fun (K, V, {L, Acc}) ->
                      Size = byte_size(Set#bindict.b) div Set#bindict.block_size,
                      Rank = index(Set, L, Size, K),
                      %% TODO: Skip candidates until OtherK?
                      case at(Set, Rank) of
                          {K, _}       -> {Rank, [{K, V} | Acc]};
                          {_OtherK, _} -> {Rank, Acc};
                          not_found    -> {Rank, Acc}
                      end
              end, {0, []}),
    do_svs(Sets, lists:reverse(NewCandidatesList));

do_svs([Set | Sets], Candidates) when is_list(Candidates) ->
    {_, NewCandidates} =
        lists:foldl(fun ({K, V}, {L, Acc}) ->
                            Size = byte_size(Set#bindict.b) div Set#bindict.block_size,
                            Rank = index(Set, L, Size, K),
                            case at(Set, Rank) of
                                {K, _}       -> {Rank, [{K, V} | Acc]};
                                {_OtherK, _} -> {Rank, Acc};
                                not_found    -> {Rank, Acc}
                            end
                    end, {0, []}, Candidates),
    do_svs(Sets, lists:reverse(NewCandidates)).

at(B, I) ->
    Offset = index2offset(B, I),
    KeySize = B#bindict.key_size,
    ValueSize = B#bindict.value_size,
    case B#bindict.b of
        <<_:Offset/binary, Key:KeySize/binary, Value:ValueSize/binary, _/binary>> ->
            {Key, Value};
        _ ->
            not_found
    end.


%% @doc: Populates the dictionary with data from the orddict, taking
%% advantage of the fact that it is already ordered. The given bindict
%% must be empty, but contain size parameters.
from_orddict(#bindict{b = <<>>} = B, Orddict) ->
    KeySize = B#bindict.key_size,
    ValueSize = B#bindict.value_size,
    L = orddict:fold(fun (K, V, Acc)
                           when byte_size(K) =:= B#bindict.key_size andalso
                                byte_size(V) =:= B#bindict.value_size ->
                             [<<K:KeySize/binary, V:ValueSize/binary>> | Acc];
                         (_, _, _) ->
                             erlang:error(badarg)
                     end, [], Orddict),
    B#bindict{b = iolist_to_binary(lists:reverse(L))}.

to_orddict(#bindict{} = B) ->
    lists:reverse(
      foldl(B, fun (Key, Value, Acc) ->
                       [{Key, Value} | Acc]
               end, [])).


%%
%% INTERNAL HELPERS
%%

index2offset(_, 0) -> 0;
index2offset(B, I) -> I * B#bindict.block_size.

%% @doc: Uses binary search to find the index of the given key. If the
%% key does not exist, the index where it should be inserted is
%% returned.
-spec index(bindict(), key()) -> index().
index(<<>>, _) ->
    0;
index(B, K) ->
    N = byte_size(B#bindict.b) div B#bindict.block_size,
    index(B, 0, N, K).

index(_B, Low, High, _K) when High =:= Low ->
    Low;

index(_B, Low, High, _K) when High < Low ->
    -1;

index(B, Low, High, K) ->
    Mid = (Low + High) div 2,
    MidOffset = index2offset(B, Mid),

    KeySize = B#bindict.key_size,
    case byte_size(B#bindict.b) > MidOffset of
        true ->
            <<_:MidOffset/binary, MidKey:KeySize/binary, _/binary>> = B#bindict.b,

            if
                MidKey > K ->
                    index(B, Low, Mid, K);
                MidKey < K ->
                    index(B, Mid + 1, High, K);
                MidKey =:= K ->
                    Mid
            end;
        false ->
            Mid
    end.

inc(B) ->
    IncInt = binary:decode_unsigned(B) + 1,
    SizeBits = erlang:size(B) * 8,
    <<IncInt:SizeBits>>.

%%
%% TEST
%%
-ifdef(TEST).


-define(i2k(I), <<I:64/integer>>).
-define(i2v(I), <<I:8/integer>>).
-define(b2i(B), list_to_integer(binary_to_list(B))).

new_with_data_test() ->
    Dict = insert_many(new(8, 1), [{2, 2}, {4, 4}, {1, 1}, {3, 3}]),
    ?assertEqual(Dict, new(8, 1, Dict#bindict.b)).

insert_test() ->
    insert_many(new(8, 1), [{2, 2}, {4, 4}, {1, 1}, {3, 3}]).

sorted_insert_test() ->
    B = insert_many(new(8, 1), [{1, 1}, {2, 2}, {3, 3}, {4, 4}]),
    ?assertEqual(<<1:64/integer, 1, 2:64/integer, 2,
                   3:64/integer, 3, 4:64/integer, 4>>, B#bindict.b).

index_test() ->
    B = #bindict{key_size = 8, value_size = 1, block_size = 9,
           b = <<0,0,0,0,0,0,0,1,1,0,0,0,0,0,0,0,2,2>>},
    ?assertEqual(0, index(B, <<1:64/integer>>)),
    ?assertEqual(1, index(B, <<2:64/integer>>)),
    ?assertEqual(2, index(B, <<3:64/integer>>)),
    ?assertEqual(2, index(B, <<100:64/integer>>)).

find_test() ->
    B = insert_many(new(8, 1), [{2, 2}, {3, 3}, {1, 1}]),
    ?assertEqual(<<3:8/integer>>, find(B, <<3:64/integer>>)).

find_non_existing_test() ->
    B = insert_many(new(8, 1), [{2, 2}, {3, 3}, {1, 1}]),
    ?assertEqual(not_found, find(B, ?i2k(4))).

find_many_test() ->
    B = insert_many(new(8, 1), [{2, 2}, {3, 3}, {1, 1}]),
    find_many(B, [<<1:64/integer>>, <<2:64/integer>>, <<3:64/integer>>]).

insert_overwrite_test() ->
    B = insert_many(new(8, 1), [{2, 2}]),
    ?assertEqual(<<2>>, find(B, <<2:64/integer>>)),
    B2 = insert(B, <<2:64/integer>>, <<4>>),
    ?assertEqual(<<4>>, find(B2, <<2:64/integer>>)).

update_test() ->
    B = insert_many(new(8, 1), [{2, 2}]),
    B2 = update(B, <<2:64/integer>>, <<4>>, fun (Old) ->
                                                    ?assertEqual(Old, <<2>>),
                                                    <<5>>
                                            end),
    ?assertEqual(<<5>>, find(B2, <<2:64/integer>>)),
    B3 = update(B2, <<3:64/integer>>, <<3>>, fun (_) ->
                                                     throw(unexpected_call)
                                             end),
    ?assertEqual(<<3>>, find(B3, <<3:64/integer>>)).

append_test() ->
    KV1 = {<<2:64>>, <<2:8>>},
    {K2, V2} = {<<3:64>>, <<3:8>>},
    B = insert_many(new(8, 1), [KV1]),
    ?assertError(badarg, append(B, <<1:64>>, V2)),
    ?assertError(badarg, append(B, <<2:64>>, V2)),
    B2 = append(B, K2, V2),
    ?assertEqual(V2, find(B2, K2)).

next_test() ->
    KV1 = {<<2:64>>, <<2:8>>},
    KV2 = {<<3:64>>, <<3:8>>},
    B = insert_many(new(8, 1), [KV1, KV2]),
    ?assertEqual(KV1, next(B, <<0:64>>)),
    ?assertEqual(KV1, next(B, <<1:64>>)),
    ?assertEqual(KV2, next(B, <<2:64>>)),
    ?assertEqual(not_found, next(B, <<3:64>>)).

next_nth_test() ->
    KV1 = {<<2:64>>, <<2:8>>},
    KV2 = {<<3:64>>, <<3:8>>},
    B = insert_many(new(8, 1), [KV1, KV2]),
    ?assertEqual(KV1, next_nth(B, <<0:64>>, 1)),
    ?assertEqual(KV2, next_nth(B, <<0:64>>, 2)),
    ?assertEqual(KV2, next_nth(B, <<2:64>>, 1)),
    ?assertEqual(not_found, next_nth(B, <<2:64>>, 2)),
    ?assertEqual(not_found, next_nth(B, <<3:64>>, 1)).

first_test() ->
    KV1  = {K1, V1} = {<<2:64>>, <<2:8>>},
    _KV2 = {K2, V2} = {<<3:64>>, <<3:8>>},
    B1 = new(8, 1),
    ?assertEqual(not_found, first(B1)),
    B2 = insert(B1, K1, V1),
    ?assertEqual(KV1, first(B2)),
    B3 = insert(B2, K2, V2),
    ?assertEqual(KV1, first(B3)).

last_test() ->
    KV1 = {K1, V1} = {<<2:64>>, <<2:8>>},
    KV2 = {K2, V2} = {<<3:64>>, <<3:8>>},
    B1 = new(8, 1),
    ?assertEqual(not_found, last(B1)),
    ?assertEqual(0, num_keys(B1)),
    ?assertEqual(not_found, at(B1, 0)),
    ?assertEqual(not_found, at(B1, -1)),
    ?assertEqual(not_found, at(B1, 1)),
    B2 = insert(B1, K1, V1),
    ?assertEqual(KV1, last(B2)),
    B3 = insert(B2, K2, V2),
    ?assertEqual(KV2, last(B3)).

delete_test() ->
    B = insert_many(new(8, 1), [{2, 2}, {3, 3}, {1, 1}]),
    ?assertEqual(<<2:8/integer>>, find(B, ?i2k(2))),

    NewB = delete(B, ?i2k(2)),
    ?assertEqual(not_found, find(NewB, ?i2k(2))).

delete_non_existing_test() ->
    B = insert_many(new(8, 1), [{2, 2}, {3, 3}, {1, 1}]),
    ?assertError(badarg, delete(B, ?i2k(4))).

foldl_test() ->
    B = insert_many(new(8, 1), [{2, 2}, {3, 3}, {1, 1}]),
    ?assertEqual(2+3+1, foldl(B, fun (_, <<V:8/integer>>, Acc) -> V + Acc end, 0)),
    ?assertEqual([], foldl(new(8, 1), fun (I, V, Acc) -> [{I, V} | Acc] end, [])).


size_test() ->
    Start = 100000000000000,
    N = 1000,
    Spread = 1,
    KeyPairs = lists:map(fun (I) -> {I, 255} end,
                         lists:seq(Start, Start+(N*Spread), Spread)),

    B = insert_many(new(8, 1), KeyPairs),
    ?assertEqual(N+Spread, num_keys(B)).

serialize_test() ->
    KeyPairs = lists:map(fun (I) -> {I, 255} end, lists:seq(1, 100)),
    B = insert_many(new(8, 1), KeyPairs),
    ?assertEqual(B, deserialize(serialize(B))).

from_orddict_test() ->
    Orddict = orddict:from_list([{<<1:64/integer>>, <<255:8/integer>>}]),
    ?assertEqual(<<255>>, find(from_orddict(new(8, 1), Orddict), <<1:64/integer>>)).


intersection_test() ->
    Sets = [insert_many(new(8, 1), [{1, 1}, {2, 2}, {3, 3}]),
            insert_many(new(8, 1), [{1, 1}, {2, 3}, {4, 4}]),
            insert_many(new(8, 1), [{1, 1}, {2, 3}, {5, 5}]),
            insert_many(new(8, 1), [{1, 1}, {2, 3}, {6, 6}])],

    Intersection = intersection(Sets),
    ?assertEqual(to_orddict(insert_many(new(8, 1), [{1, 1}, {2, 2}])),
                 to_orddict(Intersection)).


intersection_perf_test_() ->
    {timeout, 600, ?_test(intersection_perf())}.

intersection_perf() ->
    TestCases = [{[1000, 1000], 10},
                 {[100000, 100000, 100000], 1000},
                 {[10000, 100000, 1000000], 1000},
                 {[1000000, 1000000, 1000000], 10000}
                ],

    lists:foreach(
      fun ({SetSizes, IntersectionSize}) ->
              UnionSize = lists:sum([SetSize - IntersectionSize
                                     || SetSize <- SetSizes]) + IntersectionSize,
              KVs = lists:map(fun (K) -> {<<K:36/binary>>, <<97:32/integer>>} end,
                              generate_unique(UnionSize)),
              ?assertEqual(UnionSize, sets:size(sets:from_list(KVs))),

              {IntersectionKeys, Rest} = lists:split(IntersectionSize, KVs),
              {SetKeys, []} = lists:mapfoldl(fun (Size, AccRest) ->
                                                     lists:split(Size - IntersectionSize,
                                                                 AccRest)
                                             end, Rest, SetSizes),
              ?assertEqual(IntersectionSize, length(IntersectionKeys)),

              SetIntersection = sets:intersection(
                                  [sets:from_list(Ks ++ IntersectionKeys)
                                   || Ks <- SetKeys]),
              ?assertEqual(IntersectionSize, sets:size(SetIntersection)),

              Bisects = lists:map(fun (Ks) ->
                                          AllKeys = orddict:from_list(
                                                      Ks ++ IntersectionKeys),
                                          from_orddict(new(36, 4), AllKeys)
                                  end, SetKeys),
              {IntersectUs, BisectIntersection} = timer:tc(
                                                    fun () -> intersection(Bisects) end),
              IntersectingKeys = to_orddict(BisectIntersection),
              ?assertEqual(length(lists:sort(sets:to_list(SetIntersection))),
                           length(lists:sort(IntersectingKeys))),
              ?assertEqual(lists:sort(sets:to_list(SetIntersection)),
                           lists:sort(IntersectingKeys)),
              error_logger:info_msg("Set sizes: ~p, Intersection size: ~p~n"
                                    "Intersection runtime: ~.2f ms~n",
                                    [SetSizes, IntersectionSize,
                                     IntersectUs / 1000]),

              ok
      end, TestCases).


generate_unique(N) ->
    RandomGenerator = fun () -> crypto:rand_bytes(36) end,
    generate_unique(RandomGenerator, [], N).

generate_unique(RandomGenerator, Acc, N) ->
    case length(Acc) =:= N of
        true ->
            Acc;
        false ->
            Gen = fun (_, 0) -> [];
                      (F, M) -> [RandomGenerator() | F(F, M-1)]
                  end,
            Uniques = lists:usort(Gen(Gen, N - length(Acc))),
            generate_unique(RandomGenerator, Acc ++ Uniques, N)
    end.


speed_test_() ->
    {timeout, 600,
     fun() ->
             Start = 100000000000000,
             N = 100000,
             Keys = lists:seq(Start, Start+N),
             KeyValuePairs = lists:map(fun (I) -> {<<I:64/integer>>, <<255:8/integer>>} end,
                                       Keys),

             %% Will mostly be unique, if N is bigger than 10000
             ReadKeys = [lists:nth(random:uniform(N), Keys) || _ <- lists:seq(1, 1000)],
             B = from_orddict(new(8, 1), KeyValuePairs),
             time_reads(B, N, ReadKeys)
     end}.


insert_speed_test_() ->
    {timeout, 600,
     fun() ->
             Start = 100000000000000,
             N = 10000,
             Keys = lists:seq(Start, Start+N),
             KeyValuePairs = lists:map(fun (I) -> {<<I:64/integer>>, <<255:8/integer>>} end,
                                       Keys),
             ReadKeys = [lists:nth(random:uniform(N), Keys) || _ <- lists:seq(1, 1000)],

             StartTime = now(),
             B = lists:foldl(fun ({K, V}, B) ->
                                 insert(B, K, V)
                         end, new(8, 1), KeyValuePairs),
             ElapsedUs = timer:now_diff(now(), StartTime),
             error_logger:info_msg("insert in ~p ms, ~p us per key~n",
                                   [ElapsedUs / 1000,
                                    ElapsedUs / N
                                   ]),
             time_reads(B, N, ReadKeys)
     end}.


time_reads(B, Size, ReadKeys) ->
    Parent = self(),
    spawn(
      fun() ->
              Runs = 100,
              Timings =
                  lists:map(
                    fun (_) ->
                            StartTime = now(),
                            find_many(B, ReadKeys),
                            timer:now_diff(now(), StartTime)
                    end, lists:seq(1, Runs)),

              Rps = 1000000 / ((lists:sum(Timings) / length(Timings)) / length(ReadKeys)),
              error_logger:info_msg("Average over ~p runs, ~p keys in dict~n"
                                    "Average fetch ~p keys: ~p us, max: ~p us~n"
                                    "Average fetch 1 key: ~p us~n"
                                    "Theoretical sequential RPS: ~w~n",
                                    [Runs, Size, length(ReadKeys),
                                     lists:sum(Timings) / length(Timings),
                                     lists:max(Timings),
                                     (lists:sum(Timings) / length(Timings)) / length(ReadKeys),
                                     trunc(Rps)]),

              Parent ! done
      end),
    receive done -> ok after 1000 -> ok end.


time_write_test_() ->
  {timeout, 600,
    fun() ->
      Fun = fun(N , B) ->
        insert(B, <<N:64/integer>>, <<255:8/integer>>)
      end,
      start_time_interval("Insert", Fun, new(8, 1), 1000, 20000)
    end
  }.

time_write_and_read_test_() ->
  {timeout, 600,
    fun() ->
      Fun = fun(Count, B) ->
        KInt = random:uniform(Count),
        find(B, <<KInt:64/integer>>),
        insert(B, <<Count:64/integer>>, <<255:8/integer>>)
      end,
      start_time_interval("Insert and find", Fun, new(8, 1), 1000, 10000)
    end
  }.

time_appends_test_() ->
  {timeout, 600,
    fun() ->
      Fun = fun(Count, B) ->
        append(B, <<Count:64/integer>>, <<255:8/integer>>)
      end,
      start_time_interval("Append", Fun, new(8, 1), 1000, 50000)
    end
  }.

time_appends_and_find_test_() ->
  {timeout, 600,
    fun() ->
      Fun = fun(Count, B) ->
        KInt = random:uniform(Count),
        find(B, <<KInt:64/integer>>),
        append(B, <<Count:64/integer>>, <<255:8/integer>>)
      end,
      start_time_interval("Append and find", Fun, new(8, 1), 1000, 50000)
    end
  }.

time_appends_and_next_test_() ->
  {timeout, 600,
    fun() ->
      Fun = fun(Count , B) ->
        KInt = random:uniform(Count),
        next(B, <<KInt:64/integer>>),
        append(B, <<Count:64/integer>>, <<255:8/integer>>)
      end,
      start_time_interval("Append and next", Fun, new(8, 1), 1000, 50000)
    end
  }.

start_time_interval(Operation, Fun, B, MeasureEvery, N) ->
  Times = time_interval(Fun, B, MeasureEvery, N, 1, now()),
  error_logger:info_msg("Time (ms) taken for ~p executions each of ~p:\n~p\n",
                        [MeasureEvery, Operation, Times]).

time_interval(_, _, _, N, N, _) ->
  [];
time_interval(Fun, B, MeasureEvery, N, Count, T) ->
  B2 = Fun(Count, B),
  case Count rem MeasureEvery =:= 0 of
    true ->
      [timer:now_diff(now(), T)| time_interval(Fun, B2, MeasureEvery, N, Count + 1, now())];
    false ->
      time_interval(Fun, B2, MeasureEvery, N, Count + 1, T)
  end.


insert_many(Bin, Pairs) ->
    lists:foldl(fun ({K, V}, B) when is_integer(K) andalso is_integer(V) ->
                        insert(B, ?i2k(K), ?i2v(V));
                    ({K, V}, B) ->
                        insert(B, K, V)
                end, Bin, Pairs).

inc_test() ->
    ?assertEqual(<<7:64>>, inc(<<6:64>>)).


bulk_insert_test() ->
    B = insert_many(new(8, 1), [{1, 1}, {10, 10}, {12, 12}]),
    New = bulk_insert(B, [{?i2k(0), ?i2v(0)},
                          {?i2k(5), ?i2v(5)},
                          {?i2k(10), ?i2v(11)},
                          {?i2k(11), ?i2v(11)}]),

    ?assertEqual([{?i2k(0) , ?i2v(0)},
                  {?i2k(1) , ?i2v(1)},
                  {?i2k(5) , ?i2v(5)},
                  {?i2k(10), ?i2v(11)},
                  {?i2k(11), ?i2v(11)},
                  {?i2k(12), ?i2v(12)}],
                 to_orddict(New)).

smart_merge_test() ->
    Big   = insert_many(new(8, 1), [{1, 1}, {10, 10}, {25, 25}]),
    Small = insert_many(new(8, 1), [{0, 0}, {10, 11}, {12, 12}]),

    Merged = merge(Small, Big),

    ?assertEqual([{?i2k(0) , ?i2v(0)},
                  {?i2k(1) , ?i2v(1)},
                  {?i2k(10) , ?i2v(11)},
                  {?i2k(12), ?i2v(12)},
                  {?i2k(25), ?i2v(25)}],
                 to_orddict(Merged)).


-endif.
