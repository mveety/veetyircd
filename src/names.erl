-module(names).
-export([lookup/2, lookup/1, add_cache/2, new_cache/0, register/1,
         unregister/1, server_lookup/2, server_lookup/1, alive/0,
         lookup_names/2, get_all/1, merge_cache/2]).

search_list(_, Head, []) ->
    {not_found, Head};
search_list(Key, Head, [{Key, Value}|R]) ->
    {ok, {Key, Value}, Head, R};
search_list(Key, Head, [H|R]) ->
    search_list(Key, [H|Head], R).

cut_head([_|R], 0) ->
    R;
cut_head([_|R], X) ->
    cut_head(R, X-1).

glue(L, []) ->
    L;
glue(L, [H|R]) ->
    glue([H|L], R).

search(Key, Cache0, CacheMax) ->
    case search_list(Key, [], Cache0) of
        {not_found, RCache} ->
            Cache = lists:reverse(RCache),
            {not_found, Cache};
        {ok, Res, Head0, Rest0}
          when length(Head0) + length(Rest0) + 1 =< CacheMax ->
            Cache = [Res|lists:reverse(glue(Head0, Rest0))],
            {ok, Res, Cache};
        {ok, Res, Head0, Rest0} ->
            Cut = (length(Head0) + length(Rest0)) - CacheMax,
            Cache1 = glue(Head0, Rest0),
            Cache = [Res|lists:reverse(cut_head(Cache1, Cut))],
            {ok, Res, Cache}
    end.

trim(Cache0, CacheMax) when length(Cache0) > CacheMax ->
    {Cache, _} = lists:split(CacheMax, Cache0),
    Cache;
trim(Cache0, _) ->
    Cache0.

trim(Cache) ->
    CacheMax = cfg:config(name_cache_max, 10),
    trim(Cache, CacheMax).

new_cache() ->
    case cfg:config(name_cache, disabled) of
        map -> #{};
        list -> [];
        disabled -> undefined
    end.

do_lookup({Type, Name, _Pid}) ->
    do_lookup({Type, Name});
do_lookup({user, Name}) ->
    case whereis(name_server) of
        undefined -> user_server:lookup(Name);
        Pid when is_pid(Pid) -> gen_server:call(name_server, {lookup_user, Name})
    end;
do_lookup({channel, Name}) ->
    case whereis(name_server) of
        undefined -> channel_server:lookup(Name);
        Pid when is_pid(Pid) -> gen_server:call(name_server, {lookup_channel, Name})
    end.

complete({user, Name}, Pid) ->
    {user, Name, Pid};
complete({user, Name, _Pid0}, Pid) ->
    {user, Name, Pid};
complete({channel, Name}, Pid) ->
    {channel, Name, Pid};
complete({channel, Name, _Pid0}, Pid) ->
    {channel, Name, Pid}.

canonical({Type, Name}) -> {Type, Name};
canonical({Type, Name, _Pid}) -> {Type, Name}.

lookup(Cache0, Name) when is_list(Name) ->
    lookup(Cache0, list_to_binary(Name));
lookup(Cache0, Name) when is_binary(Name) ->
    lookup(Cache0, {user, Name});
lookup(Cache0, Name0) when is_tuple(Name0) ->
    case cfg:config(name_cache, disabled) of
        map -> lookup_map_cache(Cache0, Name0);
        list -> lookup_list_cache(Cache0, Name0);
        disabled -> lookup_nocache(Cache0, Name0)
    end.

lookup_map_cache(Cache0, Name0) ->
    Name = canonical(Name0),
    case maps:get(Name, Cache0, not_found) of
        not_found ->
            case do_lookup(Name) of
                Err = {error, _} ->
                    Err;
                {ok, Res = {_, _, Pid}} ->
                    Cache = Cache0#{Name => Pid},
                    {ok, Cache, Res}
            end;
        Pid ->
            case rpc:call(node(Pid), erlang, is_process_alive, [Pid]) of
                true ->
                    {ok, Cache0, complete(Name, Pid)};
                _ ->
                    Cache1 = maps:remove(Name, Cache0),
                    lookup(Cache1, Name)
            end
    end.

lookup_list_cache(Cache0, Name0) ->
    Name = canonical(Name0),
    CacheMax = cfg:config(name_cache_max, 10),
    case search(Name, Cache0, CacheMax) of
        {not_found, _} ->
            case do_lookup(Name) of
                Err = {error, _} ->
                    Err;
                {ok, Res = {_, _, Pid}} ->
                    Cache = [{Name, Pid}|Cache0],
                    {ok, Cache, Res}
            end;
        {ok, {Name, Pid}, Cache} ->
            case rpc:call(node(Pid), erlang, is_process_alive, [Pid]) of
                true ->
                    {ok, Cache, complete(Name, Pid)};
                _ ->
                    Cache1 = lists:delete({Name, Pid}, Cache0),
                    lookup(Cache1, Name)
            end
    end.

lookup_nocache(Cache, Name0) ->
    Name = canonical(Name0),
    case do_lookup(Name) of
        Err = {error, _} ->
            Err;
        {ok, Res} ->
            {ok, Cache, Res}
    end.

lookup_names(NameCache, Users) ->
    lookup_names(NameCache, Users, []).

lookup_names(NameCache, [], Acc) ->
    {NameCache, Acc};
lookup_names(NameCache0, [Victim0|Rest], Acc) ->
    case lookup(NameCache0, Victim0) of
        {ok, NameCache, Victim} ->
            lookup_names(NameCache, Rest, [Victim|Acc]);
        {error, _} ->
            lookup_names(NameCache0, Rest, Acc)
    end.

lookup(Name) ->
    case lookup(new_cache(), Name) of
        {error, Error} ->
            {error, Error};
        {ok, _, Result} ->
            {ok, Result}
    end.

add_cache(Cache0, Name0 = {channel, Namestr, Pid}) when is_pid(Pid), is_binary(Namestr) ->
    add_cache0(Cache0, Name0);
add_cache(Cache0, Name0 = {user, Namestr, Pid}) when is_pid(Pid), is_binary(Namestr) ->
    add_cache0(Cache0, Name0);
add_cache(_, _) ->
    error(invalid_qualified_name).

add_cache0(Cache, Name0 = {_, _, Pid}) when is_map(Cache) ->
    Name = canonical(Name0),
    Cache#{Name => Pid};
add_cache0(Cache, Name0 = {_, _, Pid}) when is_list(Cache) ->
    Name = canonical(Name0),
    trim([{Name, Pid}|Cache]);
add_cache0(undefined, _) ->
    undefined.


%% it would be nice to use lists:merge here, but order is
%% significant :(
merge_cache_list(Cache, []) ->
    Cache;
merge_cache_list(Cache, [H|R]) ->
    case lists:member(H, Cache) of
        true ->
            merge_cache_list(Cache, R);
        false ->
            merge_cache_list([H|Cache], R)
    end.

merge_cache(Cache, New) when is_list(Cache), is_list(New) ->
    trim(merge_cache_list(Cache, lists:reverse(New)));
merge_cache(Cache, New) when is_map(Cache), is_map(New) ->
    maps:merge(Cache, New);
merge_cache(undefined, _) ->
    undefined.

register1(Tuple) ->
    case whereis(name_server) of
        Pid when is_pid(Pid) ->
            gen_server:call(name_server, {register, Tuple});
        _ ->
            ok
    end.

register(Tuple = {user, _Name, _Pid}) -> register1(Tuple);
register(Tuple = {channel, _Name, _Pid}) -> register1(Tuple);
register({_Type, _Name}) -> error(short_name_tuple);
register(_) -> error(bad_name_tuple).

unregister1(Tuple) ->
    case whereis(name_server) of
        Pid when is_pid(Pid) ->
            gen_server:call(name_server, {unregister, Tuple});
        _ ->
            ok
    end.

unregister(Tuple = {channel, _Name}) -> unregister1(Tuple);
unregister(Tuple = {user, _Name}) -> unregister1(Tuple);
unregister({Type, Name, _Pid}) -> names:unregister({Type, Name});
unregister(_) -> error(bad_name_tuple).

server_lookup({user, Name}, Timeout) ->
    gen_server:call(name_server, {lookup_user, Name}, Timeout);
server_lookup({channel, Name}, Timeout) ->
    gen_server:call(name_server, {lookup_channel, Name}, Timeout).

server_lookup(Object) ->
    server_lookup(Object, 5000).

alive() ->
    case whereis(name_server) of
        undefined -> false;
        Pid when is_pid(Pid) -> true
    end.

get_all(channel) ->
    case names:alive() of
        true ->
            gen_server:call(name_server, {get_all, channel});
        false ->
            channel_server:all_channels()
    end;
get_all(user) ->
    case names:alive() of
        true ->
            gen_server:call(name_server, {get_all, user});
        false ->
            user_server:get_all()
    end.
