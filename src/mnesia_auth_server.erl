-module(mnesia_auth_server).
-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3,
         terminate/2, start_link/0]).
-include("records.hrl").

check_password(Username, Password) ->
    case mnesia:read({account, Username}) of
        [User = #account{pass = RealPass, salt = Salt, hash = Hash}] ->
            TestPass = irc_auth:hash_password(Salt, Password, Hash),
            case TestPass of
                RealPass ->
                    {ok, User};
                _ ->
                    {error, bad_pass}
            end;
        [] ->
            {error, not_found}
    end.

do_register(Username, Password, Flags) ->
    case mnesia:read({account, Username}) of
        [] ->
            {Salt, HashPass, Hash} = irc_auth:new_password(Password),
            NewUser = #account{ name = Username
                              , pass = HashPass
                              , salt = Salt
                              , hash = Hash
                              , group = none
                              , enabled = true
                              , flags = Flags
                              , chanflags = #{}
                              , aux = #{}},
            mnesia:write(NewUser),
            ok;
        [#account{name = Username}] ->
            {error, exists}
    end.

do_unregister(Username) ->
    mnesia:delete({account, Username}).

do_change_password(Username, NewPass) ->
    case mnesia:read({account, Username}) of
        [User0] ->
            {Salt, HashPass, Hash} = irc_auth:new_password(NewPass),
            User = User0#account{pass = HashPass, salt = Salt, hash = Hash},
            mnesia:write(User),
            ok;
        [] ->
            {error, not_found}
    end.

do_user_enabled(Username, Bool) ->
    case mnesia:read({account, Username}) of
        [User0] ->
            User = User0#account{enabled = Bool},
            mnesia:write(User),
            ok;
        [] ->
            {error, not_found}
    end.

do_user_enabled(Username) ->
    case mnesia:read({account, Username}) of
        [User] ->
            {ok, User#account.enabled};
        [] ->
            {error, not_found}
    end.

do_user_exists(Username) ->
    case mnesia:read({account, Username}) of
        [#account{name = Username}] -> true;
        [] -> false
    end.

do_update_flags(Username, system, Flags) ->
    case mnesia:read({account, Username}) of
        [User0] ->
            User = User0#account{flags = Flags},
            mnesia:write(User),
            ok;
        [] ->
            {error, not_found}
    end;
do_update_flags(Username, Channel, Flags) ->
    case mnesia:read({account, Username}) of
        [User0 = #account{chanflags = Chanflags0}] ->
            Chanflags = Chanflags0#{Channel => Flags},
            User = User0#account{chanflags = Chanflags},
            mnesia:write(User),
            ok;
        [] ->
            {error, not_found}
    end.

do_get_flags(Username, system) ->
    case mnesia:read({account, Username}) of
        [#account{flags = Flags}] ->
            {ok, Flags};
        [] ->
            {error, not_found}
    end;
do_get_flags(Username, Channel) ->
    case mnesia:read({account, Username}) of
        [#account{chanflags = Chanflags}] ->
            Chanflag = maps:get(Channel, Chanflags, #{}),
            {ok, Chanflag};
        [] ->
            {error, not_found}
    end.

do_get_aux(Username) ->
    case mnesia:read({account, Username}) of
        [#account{aux = Aux}] ->
            {ok, Aux};
        [] ->
            {error, not_found}
    end.

do_set_aux(Username, NewAux) ->
    case mnesia:read({account, Username}) of
        [User0] ->
            User = User0#account{aux = NewAux},
            mnesia:write(User),
            ok;
        [] ->
            {error, not_found}
    end.

do_check_password(Username, Password) ->
    case check_password(Username, Password) of
        {ok, _} ->
            ok;
        Error = {error, _Reason} ->
            Error
    end.

do_check_user(Username, Password, Policy) ->
    case check_password(Username, Password) of
        {ok, #account{enabled = true}} ->
            ok;
        {ok, #account{enabled = false}} ->
            case Policy of
                open -> ok;
                verify -> {error, disabled};
                closed -> {error, disabled}
            end;
        {error, bad_pass} ->
            case Policy of
                open -> ok;
                verify -> {error, bad_pass};
                closed -> {error, bad_pass}
            end;
        {error, not_found} ->
            case Policy of
                open -> ok;
                verify -> ok;
                closed -> {error, not_found}
            end
    end.

do_stats(Policy) ->
    Size = length(mnesia:all_keys(account)),
    {ok, [{type, mnesia}, {size, Size}, {policy, Policy}]}.

do_get_all_users() ->
    Foldfn = fun(Obj, Acc) ->
                     ObjMap = #{ username => Obj#account.name
                               , password => redacted
                               , salt => redacted
                               , hash => Obj#account.hash
                               , group => Obj#account.group
                               , enabled => Obj#account.enabled
                               , flags => Obj#account.flags
                               , chanflags => Obj#account.chanflags
                               , aux => Obj#account.aux
                               },
                     [ObjMap|Acc]
             end,
    AllUsers = mnesia:foldl(Foldfn, [], account),
    {ok, AllUsers}.

do_get_user(Username) ->
    case mnesia:read({account, Username}) of
        [User] ->
            UserMap = #{ username => User#account.name
                       , password => redacted
                       , salt => redacted
                       , hash => User#account.hash
                       , group => User#account.group
                       , enabled => User#account.enabled
                       , flags => User#account.flags
                       , chanflags => User#account.chanflags
                       , aux => User#account.aux
                       },
            {ok, UserMap};
        [] ->
            {error, not_found}
    end.

start_link() ->
    gen_server:start_link({local, auth_server}, ?MODULE, [], []).

init(_Args) ->
    {ok, Policy} = cfg:config(auth_policy),
    logger:notice("mnesia_auth_server: started"),
    {ok, #{policy => Policy}}.

handle_call({register, Username, Password, Flags}, _From, State) ->
    {atomic, Res} = mnesia:transaction(fun() -> do_register(Username, Password, Flags) end),
    {reply, Res, State};

handle_call({unregister, Username}, _From, State) ->
    {atomic, Res} = mnesia:transaction(fun() -> do_unregister(Username) end),
    {reply, Res, State};

handle_call({change_password, Username, Password}, _From, State) ->
    {atomic, Res} = mnesia:transaction(fun() -> do_change_password(Username, Password) end),
    {reply, Res, State};

handle_call({user_enabled, Username, Bool}, _From, State) ->
    {atomic, Res} = mnesia:transaction(fun() -> do_user_enabled(Username, Bool) end),
    {reply, Res, State};

handle_call({user_enabled, Username}, _From, State) ->
    {atomic, Res} = mnesia:transaction(fun() -> do_user_enabled(Username) end),
    {reply, Res, State};

handle_call({user_exists, Username}, _From, State) ->
    {atomic, Res} = mnesia:transaction(fun() -> do_user_exists(Username) end),
    {reply, Res, State};

handle_call({update_flags, Username, Channel, Flags}, _From, State) ->
    {atomic, Res} = mnesia:transaction(fun() -> do_update_flags(Username, Channel, Flags) end),
    {reply, Res, State};

handle_call({get_flags, Username, Channel}, _From, State) ->
    {atomic, Res} = mnesia:transaction(fun() -> do_get_flags(Username, Channel) end),
    {reply, Res, State};

handle_call({check_password, Username, Password}, _From, State) ->
    {atomic, Res} = mnesia:transaction(fun() -> do_check_password(Username, Password) end),
    {reply, Res, State};

handle_call({check_user, Username, Password}, _From, State = #{policy := Policy}) ->
    {atomic, Res} = mnesia:transaction(fun() -> do_check_user(Username, Password, Policy) end),
    {reply, Res, State};

handle_call(stats, _From, State = #{policy := Policy}) ->
    {atomic, Res} = mnesia:transaction(fun() -> do_stats(Policy) end),
    {reply, Res, State};

handle_call({policy, open}, _From, State) ->
    {reply, ok, State#{policy => open}};
handle_call({policy, verify}, _From, State) ->
    {reply, ok, State#{policy => verify}};
handle_call({policy, closed}, _From, State) ->
    {reply, ok, State#{policy => closed}};
handle_call({policy, _}, _From, State) ->
    {reply, {error, bad_policy}, State};

handle_call(get_all_users, _From, State) ->
    {atomic, Res} = mnesia:transaction(fun() -> do_get_all_users() end),
    {reply, Res, State};

handle_call({get_user, Username}, _From, State) ->
    {atomic, Res} = mnesia:transaction(fun() -> do_get_user(Username) end),
    {reply, Res, State};

handle_call({get_aux, Username}, _From, State) ->
    {atomic, Res} = mnesia:transaction(fun() -> do_get_aux(Username) end),
    {reply, Res, State};

handle_call({set_aux, Username, NewAux}, _From, State) ->
    {atomic, Res} = mnesia:transaction(fun() -> do_set_aux(Username, NewAux) end),
    {reply, Res, State};

handle_call(Msg, From, State) ->
    case cfg:config(auth_unhandled_msg, log) of
        log ->
            logger:notice("auth_server call: unhandled message: ~p, from: ~p", [Msg, From]);
        {log, Level} ->
            logger:log(Level, "auth_server call: unhandled message: ~p, from: ~p", [Msg, From]);
        crash ->
            logger:error("auth_server call: unhandled message: ~p, from: ~p", [Msg, From]),
            exit(unhandled_message);
        silent ->
            ok
    end,
    {reply, ok, State}.

handle_cast(Msg, State) ->
    case cfg:config(auth_unhandled_msg, log) of
        log ->
            logger:notice("auth_server cast: unhandled message: ~p", [Msg]);
        {log, Level} ->
            logger:log(Level, "auth_server cast: unhandled message: ~p", [Msg]);
        crash ->
            logger:error("auth_server cast: unhandled message: ~p", [Msg]),
            exit(unhandled_message);
        silent ->
            ok
    end,
    {noreply, State}.

handle_info(Msg, State) ->
    case cfg:config(auth_unhandled_msg, log) of
        log ->
            logger:notice("auth_server info: unhandled message: ~p", [Msg]);
        {log, Level} ->
            logger:log(Level, "auth_server info: unhandled message: ~p", [Msg]);
        crash ->
            logger:error("auth_server info: unhandled message: ~p", [Msg]),
            exit(unhandled_message);
        silent ->
            ok
    end,
    {noreply, State}.

code_change(_, State, _) ->
    {ok, State}.

terminate(_, _) ->
    ok.
