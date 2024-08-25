-module(dets_auth_server).
-behaviour(gen_server).
-include_lib("stdlib/include/ms_transform.hrl").
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3,
         terminate/2, start_link/0]).
-include("records.hrl").

do_check_password(Username, Password, #{auth_db := AuthDb}) ->
    case dets:lookup(AuthDb, Username) of
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

start_link() ->
    gen_server:start_link({local, auth_server}, ?MODULE, [], []).

init(_Args) ->
    {ok, Database} = cfg:config(auth_database),
    {ok, Policy} = cfg:config(auth_policy),
    AuthDb = make_ref(),
    {ok, AuthDb} = dets:open_file(AuthDb, [ {auto_save, 5000}
                                           , {file, Database}
                                           , {keypos, #account.name}
                                           , {type, set}]),
    dets:safe_fixtable(AuthDb, true),
    {size, Size} = proplists:lookup(size, dets:info(AuthDb)),
    logger:notice("dets_auth_server: loaded ~p users", [Size]),
    {ok, #{database => Database, policy => Policy, auth_db => AuthDb}}.

handle_call({register, Username, Password, Flags}, _From, State = #{auth_db := AuthDb}) ->
    case dets:member(AuthDb, Username) of
        false ->
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
            dets:insert(AuthDb, NewUser),
            {reply, ok, State};
        true ->
            {reply, {error, exists}, State}
    end;

handle_call({unregister, Username}, _From, State = #{auth_db := AuthDb}) ->
    dets:delete(AuthDb, Username),
    {reply, ok, State};

handle_call({change_password, Username, NewPass}, _From, State = #{auth_db := AuthDb}) ->
    case dets:lookup(AuthDb, Username) of
        [User0] ->
            {Salt, HashPass, Hash} = irc_auth:new_password(NewPass),
            User = User0#account{pass = HashPass, salt = Salt, hash = Hash},
            dets:insert(AuthDb, User),
            {reply, ok, State};
        [] ->
            {reply, {error, not_found}, State}
    end;

handle_call({user_enabled, Username, Bool}, _From, State = #{auth_db := AuthDb}) ->
    case dets:lookup(AuthDb, Username) of
        [User0] ->
            User = User0#account{enabled = Bool},
            dets:insert(AuthDb, User),
            {reply, ok, State};
        [] ->
            {reply, {error, not_found}, State}
    end;
handle_call({user_enabled, Username}, _From, State = #{auth_db := AuthDb}) ->
    case dets:lookup(AuthDb, Username) of
        [User] ->
            {reply, {ok, User#account.enabled}, State};
        [] ->
            {reply, {error, not_found}, State}
    end;

handle_call({user_exists, Username}, _From, State = #{auth_db := AuthDb}) ->
    {reply, dets:member(AuthDb, Username), State};

handle_call({update_flags, Username, system, Flags}, _From, State = #{auth_db := AuthDb}) ->
    case dets:lookup(AuthDb, Username) of
        [User0] ->
            User = User0#account{flags = Flags},
            dets:insert(AuthDb, User),
            {reply, ok, State};
        [] ->
            {reply, {error, not_found}, State}
    end;
handle_call({update_flags, Username, Channel, Flags}, _From, State = #{auth_db := AuthDb}) ->
    case dets:lookup(AuthDb, Username) of
        [User0 = #account{chanflags = Chanflags0}] ->
            Chanflags = Chanflags0#{Channel => Flags},
            User = User0#account{chanflags = Chanflags},
            dets:insert(AuthDb, User),
            {reply, ok, State};
        [] ->
            {reply, {error, not_found}, State}
    end;

handle_call({get_flags, Username, system}, _From, State = #{auth_db := AuthDb}) ->
    case dets:lookup(AuthDb, Username) of
        [#account{flags = Flags}] ->
            {reply, {ok, Flags}, State};
        [] ->
            {reply, {error, not_found}, State}
    end;
handle_call({get_flags, Username, Channel}, _From, State = #{auth_db := AuthDb}) ->
    case dets:lookup(AuthDb, Username) of
        [#account{chanflags = Chanflags}] ->
            Chanflag = maps:get(Channel, Chanflags, #{}),
            {reply, {ok, Chanflag}, State};
        [] ->
            {reply, {error, not_found}, State}
    end;

handle_call({check_password, Username, Password}, _From, State) ->
    case do_check_password(Username, Password, State) of
        {ok, _} ->
            {reply, ok, State};
        Error = {error, _Reason} ->
            {reply, Error, State}
    end;

handle_call({check_user, Username, Password}, _From, State = #{policy := Policy}) ->
    case do_check_password(Username, Password, State) of
        {ok, #account{enabled = true}} ->
            {reply, ok, State};
        {ok, #account{enabled = false}} ->
            case Policy of
                open -> {reply, ok, State};
                verify -> {reply, {error, disabled}, State};
                closed -> {reply, {error, disabled}, State}
            end;
        {error, bad_pass} ->
            case Policy of
                open -> {reply, ok, State};
                verify -> {reply, {error, bad_pass}, State};
                closed -> {reply, {error, bad_pass}, State}
            end;
        {error, not_found} ->
            case Policy of
                open -> {reply, ok, State};
                verify -> {reply, ok, State};
                closed -> {reply, {error, not_found}, State}
            end
    end;

handle_call(stats, _From, State = #{policy := Policy, auth_db := AuthDb}) ->
    Info = dets:info(AuthDb),
    {size, Size} = proplists:lookup(size, Info),
    Res = [ {type, dets}
          , {users, Size}
          , {policy, Policy}
          ],
    {reply, {ok, Res}, State};

handle_call({policy, open}, _From, State) ->
    {reply, ok, State#{policy => open}};
handle_call({policy, verify}, _From, State) ->
    {reply, ok, State#{policy => verify}};
handle_call({policy, closed}, _From, State) ->
    {reply, ok, State#{policy => closed}};
handle_call({policy, _}, _From, State) ->
    {reply, {error, bad_policy}, State};

handle_call(get_all_users, _From, State = #{auth_db := AuthDb}) ->
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
    AllUsers = dets:foldl(Foldfn, [], AuthDb),
    {reply, {ok, AllUsers}, State};

handle_call({get_user, Username}, _From, State = #{auth_db := AuthDb}) ->
    case dets:lookup(AuthDb, Username) of
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
            {reply, {ok, UserMap}, State};
        [] ->
            {reply, {error, not_found}, State}
    end;

handle_call({get_aux, Username}, _From, State = #{auth_db := AuthDb}) ->
    case dets:lookup(AuthDb, Username) of
        [User] ->
            {reply, {ok, User#account.aux}, State};
        [] ->
            {reply, {error, not_found}, State}
    end;

handle_call({set_aux, Username, NewAux}, _From, State = #{auth_db := AuthDb}) ->
    case dets:lookup(AuthDb, Username) of
        [User0] ->
            User = User0#account{aux = NewAux},
            dets:insert(AuthDb, User),
            {reply, ok, State};
        [] ->
            {reply, {error, not_found}, State}
    end;

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

terminate(_, #{auth_db := AuthDb}) ->
    ok = dets:sync(AuthDb),
    ok = dets:close(AuthDb),
    ok.
