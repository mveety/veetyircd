-module(cfg_check).
-export([type_check/1, member_check/2]). 

tuplelencheck(V, L) ->
    try element(L, V) of
        _ -> true
    catch
        error:_ -> false
    end.
tupleexactlen(V, L) ->
    tuplelencheck(V, L) and (not tuplelencheck(V, L+1)).

do_type_check(Value, boolean) when is_boolean(Value) ->
    true;
do_type_check(_, boolean) ->
    false;

do_type_check(Value, list) when is_list(Value) ->
    true;
do_type_check(_, list) ->
    false;

do_type_check(Value, integer) when is_integer(Value) ->
    true;
do_type_check(_, integer) ->
    false;

do_type_check(Value, binary) when is_binary(Value) ->
    true;
do_type_check(_, binary) ->
    false;

do_type_check(Value, atom) when is_atom(Value) ->
    true;
do_type_check(_, atom) ->
    false;
do_type_check(Value, {atom, Atoms}) ->
    Foldfn = fun(A, _) when A =:= Value ->
                     true;
                (_, Acc0) ->
                     Acc0
             end,
    lists:foldl(Foldfn, false, Atoms);

do_type_check(Value, {tuple, Len}) when is_tuple(Value) ->
    tupleexactlen(Value, Len);

do_type_check(Value, {tuple, Len, TypeDefs}) when is_tuple(Value) ->
    TupleElemCheck = fun TupleElemCheck(_, _, 0) ->
                             true;
                         TupleElemCheck(Val, Type, N) ->
                             ValElem = element(N, Val),
                             TypeElem = element(N, Type),
                             case do_type_check(ValElem, TypeElem) of
                                 true ->
                                     TupleElemCheck(Val, Type, N-1);
                                 false ->
                                     false
                             end
                     end,
    case tupleexactlen(Value, Len) of
        true ->
            TupleElemCheck(Value, TypeDefs, Len);
        false ->
            false
    end;

do_type_check(Value, {tagged_tuple, Len, Tag}) when is_tuple(Value) ->
    tupleexactlen(Value, Len) and (element(1, Value) =:= Tag);

do_type_check(_, []) ->
    false;
do_type_check(Value, [H|R]) ->
    case do_type_check(Value, H) of
        true ->
            true;
        false ->
            do_type_check(Value, R)
    end;

do_type_check(_, Type) ->
    error({bad_type_check, Type}).

do_config_check(Var, Type) ->
    case cfg:config(Var) of
        {ok, Value} ->
            do_type_check(Value, Type);
        undefined ->
            missing
    end.

do_config_check([]) ->
    ok;
do_config_check([{Var, Type}|R]) ->
    case do_config_check(Var, Type) of
        true ->
            do_config_check(R);
        false ->
            {error, {bad_type, Var, Type}};
        missing ->
            {error, {env_missing, Var, Type}}
    end.

type_check(Defs) ->
    do_config_check(Defs).

do_existing([], _) ->
    ok;
do_existing([H|R], Defs) ->
    case lists:member(H, Defs) of
        true ->
            do_existing(R, Defs);
        false ->
            {error, {def_missing, H}}
    end.

member_check(Envs0, Defs0) ->
    Envs = proplists:get_keys(Envs0),
    Defs = proplists:get_keys(Defs0),
    do_existing(Envs, Defs).
