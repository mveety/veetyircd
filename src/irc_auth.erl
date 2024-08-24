-module(irc_auth).
-export([generate_salt/0, hash_password/3, new_password/1]).
-export([register/3, unregister/1, change_password/2, user_enabled/1,
         user_enabled/2, update_flags/2, update_flags/3, get_flags/1,
         get_flags/2, check_password/2, check_user/2, stats/0, policy/1,
         get_all_users/0, get_user/1, user_exists/1, get_aux/1, set_aux/2]).
-export([get_flag/4, set_flag/4, check_flags/3]).

%% internal functions

generate_salt() ->
    crypto:strong_rand_bytes(16).

do_hashes(Data, _Hash, 0) ->
    Data;
do_hashes(Data0, Hash, N) ->
    Data = crypto:hash(Hash, Data0),
    do_hashes(Data, Hash, N-1).

hash_password(Salt, Password, {Hash, Times}) ->
    SaltedPass = <<Salt/binary, Password/binary>>,
    do_hashes(SaltedPass, Hash, Times).

new_password(Password) ->
    Salt = generate_salt(),
    Hashinfo = cfg:config(auth_hashinfo, {sha3_512, 10}),
    HashData = hash_password(Salt, Password, Hashinfo),
    {Salt, HashData, Hashinfo}.

%% the api

register(Username, Password, Flags) ->
    gen_server:call(auth_server, {register, Username, Password, Flags}).

unregister(Username) ->
    gen_server:call(auth_server, {unregister, Username}).

change_password(Username, Password) ->
    gen_server:call(auth_server, {change_password, Username, Password}).

user_enabled(Username) ->
    gen_server:call(auth_server, {user_enabled, Username}).
user_enabled(Username, Status) ->
    gen_server:call(auth_server, {user_enabled, Username, Status}).

update_flags(Username, Flags) ->
    update_flags(Username, system, Flags).
update_flags(Username, system, Flags) ->
    gen_server:call(auth_server, {update_flags, Username, system, Flags});
update_flags(Username, global, Flags) ->
    gen_server:call(auth_server, {update_flags, Username, system, Flags});
update_flags(Username, Channel, Flags) ->
    Self = self(),
    case channel_server:is_permachan(Channel) of
        true ->
            gen_server:call(auth_server, {update_flags, Username, Channel, Flags});
        false ->
            case names:lookup({channel, Channel}) of
                {ok, {channel, _, Self}} ->
                    error(circular_call);  % whoopsies
                {ok, {channel, Channel, Pid}} ->
                    channel:update_flags(Pid, Username, Flags);
                {error, _} ->
                    {error, not_found}
            end
    end.

get_flags(Username) ->
    get_flags(Username, system).
get_flags(Username, system) ->
    gen_server:call(auth_server, {get_flags, Username, system});
get_flags(Username, global) ->
    gen_server:call(auth_server, {get_flags, Username, system});
get_flags(Username, Channel) ->
    Self = self(),
    case channel_server:is_permachan(Channel) of
        true ->
            gen_server:call(auth_server, {get_flags, Username, Channel});
        false ->
            case names:lookup({channel, Channel}) of
                {ok, {channel, _, Self}} ->
                    error(circular_call);  % whoopsies
                {ok, {channel, Channel, Pid}} ->
                    channel:get_flags(Pid, Username);
                {error, _} ->
                    {error, not_found}
            end
    end.

check_password(Username, Password) ->
    gen_server:call(auth_server, {check_password, Username, Password}).

check_user(Username, Password) ->
    gen_server:call(auth_server, {check_user, Username, Password}).

stats() ->
    gen_server:call(auth_server, stats).

policy(Policy) ->
    gen_server:call(auth_server, {policy, Policy}).

get_all_users() ->
    gen_server:call(auth_server, get_all_users).

get_user(Username) ->
    gen_server:call(auth_server, {get_user, Username}).

get_flag(Username, global, Flag, Default) ->
    case get_flags(Username) of
        {ok, Flags} ->
            maps:get(Flag, Flags, Default);
        _ ->
            Default
    end;
get_flag(Username, Channel, Flag, Default) ->
    case {get_flags(Username), get_flags(Username, Channel)} of
        {{ok, Flags}, {ok, ChanFlags}} ->
            CombinedFlags = maps:merge(Flags, ChanFlags),
            maps:get(Flag, CombinedFlags, Default);
        _ ->
            Default
    end.

set_flag(Username, global, Flag, Value) ->
    {ok, Flags} = get_flags(Username),
    update_flags(Username, Flags#{Flag => Value});
set_flag(Username, Channel, Flag, Value) ->
    {ok, ChanFlags} = get_flags(Username, Channel),
    update_flags(Username, Channel, ChanFlags#{Flag => Value}).

check_flags(_Username, _Channel, []) ->
    false;
check_flags(Username, Channel, [Flag|Rest]) ->
    case get_flag(Username, Channel, Flag, false) of
        false ->
            check_flags(Username, Channel, Rest);
        true ->
            true
    end.

user_exists(Username) ->
    gen_server:call(auth_server, {user_exists, Username}).

get_aux(Username) ->
    gen_server:call(auth_server, {get_aux, Username}).

set_aux(Username, Aux) ->
    gen_server:call(auth_server, {set_aux, Username, Aux}).

