-module(authserv).
-export([start_link/0, init/1, parse_message/4, message/4]).

start_link() ->
    veetyircd_bot:start_link(?MODULE, []).

init([]) ->
    {failover, []}.

parse_message(Msg, _From, self, _State) ->
    case string:split(Msg, " ", leading) of
        [<<"help">>|_] ->
            {ok, {help, main}};
        [<<"register">>,Rest] ->
            case string:split(Rest, " ", leading) of
                [Password] -> {ok, {register, string:trim(Password, both)}};
                _ -> {ok, {error, Msg}}
            end;
        [<<"password">>,Rest] ->
            case string:split(Rest, " ", leading) of
                [Password] -> {ok, {password, string:trim(Password, both)}};
                _ -> {ok, {error, Msg}}
            end;
        [<<"info">>,Rest] ->
            case string:split(Rest, " ", leading) of
                [<<"help">>] -> {ok, {info, help}};
                [<<"email">>,R0] -> {ok, {info, email, R0}};
                [<<"realname">>,R0] -> {ok, {info, realname, R0}};
                [<<"birthday">>,R0] -> {ok, {info, birthday, R0}};
                [<<"location">>,R0] -> {ok, {info, location, R0}};
                [<<"timezone">>,R0] -> {ok, {info, timezone, R0}};
                [<<"website">>,R0] -> {ok, {info, website, R0}};
                [<<"software">>,R0] -> {ok, {info, software, R0}};
                [<<"github">>,R0] -> {ok, {info, github, R0}};
                [<<"about">>,R0] -> {ok, {info, about, R0}};
                [<<"minecraft_name">>,R0] -> {ok, {info, minecraft_name, R0}}; %% used by mc_bridge
                [<<"games">>,R0] -> {ok, {info, games, R0}}; %% map used by gamesbot. don't edit it!
                [<<"chick">>,R0] -> {ok, {info, chick, R0}}; %% map(?) used by chick. don't edit it!
                _ -> {ok, {error, Msg}}
            end;
        [<<"lookup">>,Rest] ->
            case string:split(Rest, " ", leading) of
                [Username] -> {ok, {lookup, Username}};
                _ -> {ok, {error, Msg}}
            end;
        [<<"all_users">>] -> {ok, all_users};
        [<<"kick_session">>] -> {ok, kick_session};
        [<<"kick_session">>,Rest] ->
            case string:split(Rest, " ", leading) of
                [<<"true">>] -> {ok, {kick_session, true}};
                [<<"yes">>] -> {ok, {kick_session, true}};
                [<<"on">>] -> {ok, {kick_session,true}};
                [<<"false">>] -> {ok, {kick_session,false}};
                [<<"no">>] -> {ok, {kick_session,false}};
                [<<"off">>] -> {ok, {kick_session,false}};
                _ -> {ok, {error, Msg}}
            end;
        _ ->
            {ok, {error, Msg}}
    end;
parse_message(_Msg, _From, _To, _State) ->
    {ok, skip_message}.

message({register, Password}, From = {user, Nick, _}, self, State)->
    case cfg:config(bots_authserv_allow_registrations, false) of
        false ->
            {ok, {reply, From, <<"user registrations are disabled. ask an admin for an account">>}, State};
        true ->
            case irc_auth:register(Nick, Password, #{}) of
                ok ->
                    logger:notice("authserv: created user ~p", [Nick]),
                    {ok, {reply, From, <<"user ", Nick/binary, " created!">>}, State};
                _ ->
                    {ok, {reply, From, <<"user ", Nick/binary, " already exists">>}, State}
            end
    end;

message({password, Password}, From = {user, Nick, _}, self, State) ->
    case irc_auth:change_password(Nick, Password) of
        ok ->
            {ok, {reply, From, <<"password changed">>}, State};
        _ ->
            {ok, {reply, From, <<"unable to change password">>}, State}
    end;

message({info, help}, From, self, State) ->
    {ok, {reply, From, [ <<"help           -- this text">>
                       , <<"email          -- your email address">>
                       , <<"realname       -- your real name">>
                       , <<"birthday       -- your birthday">>
                       , <<"location       -- where you live">>
                       , <<"timezone       -- your timezone">>
                       , <<"website        -- your website">>
                       , <<"software       -- your local repo">>
                       , <<"github         -- your github">>
                       , <<"about          -- idk some like text? be creative">>
                       , <<"minecraft_name -- minecraft user name (for the bridge)">>
                       , <<"games          -- it's a map. don't touch this.">>
                       , <<"chick          -- also a map. for nick's bot">>
                       ]}, State};

message({info, Field, Data}, From = {user, Nick, _}, self, State) ->
    Field0 = atom_to_binary(Field),
    case irc_auth:get_aux(Nick) of
        {ok, Aux0} ->
            Aux = Aux0#{Field => Data},
            ok = irc_auth:set_aux(Nick, Aux),
            {ok, {reply, From, <<Field0/binary, " set">>}, State};
        _ ->
            {ok, {reply, From, <<"unable to set ", Field0/binary>>}, State}
    end;

message({lookup, Username}, From, self, State) ->
    FormatFields = fun FormatFields([], 0, _) ->
                           <<"user ", Username/binary, " has no fields">>;
                       FormatFields([], _, Acc) ->
                           Msg = <<"user ", Username/binary, "'s fields:">>,
                           [Msg|Acc];
                       FormatFields([{Field, Data}|R], Len, Acc) when is_binary(Data) ->
                           Field0 = atom_to_binary(Field),
                           Msg = <<Field0/binary, " => ", Data/binary>>,
                           FormatFields(R, Len, [Msg|Acc]);
                       FormatFields([_|R], Len, Acc) ->
                           FormatFields(R, Len, Acc)
                   end,
    Type0 = case {irc_auth:check_flags(Username, global, [owner]),
                  irc_auth:check_flags(Username, global, [operator])} of
                {true, _} -> <<"owner">>;
                {_, true} -> <<"operator">>;
                _ -> <<"normal">>
            end,
    case irc_auth:get_aux(Username) of
        {ok, Aux} ->
            AuxList = lists:reverse([{type, Type0}|maps:to_list(Aux)]),
            Fields0 = FormatFields(AuxList, length(AuxList), []),
            {ok, {reply, From, Fields0}, State};
        _ ->
            {ok, {reply, From, <<Username/binary, " not found">>}, State}
    end;

message(all_users, From, self, State) ->
    {ok, AllUsers} = irc_auth:get_all_users(),
    GetNames = fun(#{username := Username}, Acc0) ->
                       [Username|Acc0]
               end,
    Usernames = lists:foldl(GetNames, [], AllUsers),
    {ok, {reply, From, Usernames}, State};

message({kick_session, Value}, From = {user, Nick, _}, self, State) ->
    irc_auth:set_flag(Nick, global, kick_old_session, Value),
    Value0 = atom_to_binary(Value),
    {ok, {reply, From, <<"kick_session = ", Value0/binary>>}, State};
message(kick_session, From = {user, Nick, _}, self, State) ->
    Value = irc_auth:check_flags(Nick, global, [kick_old_session]),
    Value0 = atom_to_binary(Value),
    {ok, {reply, From, <<"kick_session = ", Value0/binary>>}, State};

message({help, main}, From, self, State) ->
    {ok, {reply, From, [ <<"Authserv help">>
                       , <<"register [password]       -- register this user">>
                       , <<"password [password]       -- change existing user's password">>
                       , <<"info [field] [data...]    -- change one of your account's aux fields">>
                       , <<"lookup [username]         -- look up a user and display their aux fields">>
                       , <<"all_users                 -- list all known users">>
                       , <<"kick_session [true|false] -- kick old sessions at login">>
                       , <<"">>
                       ]}, State};

message({error, Msg}, From, self, State) ->
    logger:info("authserv: errored authserv message ~p", [Msg]),
    {ok, {reply, From, <<"error: unknown message">>}, State};

message(Msg, From, To, State) ->
    logger:info("authserv: unhandled message. Msg = ~p, From = ~p, To = ~p", [Msg, From, To]),
    {ok, noreply, State}.
