-module(channel).
-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3,
         terminate/2, start_link/1, server_start/2, get_pid/1, join/2,
         part/3, ban/2, rejoin/2, supervisor/1, get_flags/2, update_flags/3,
         all_flags/1, remove_user/2]).
-export([takeover_shutdown/1, get_endpoints/1, get_takeover_data/1,
         do_takeover/2, takeover/1, rejoin_takeover/2, topic/1,
         nusers/1]).
-include_lib("stdlib/include/ms_transform.hrl").
-record(user, {
               name, %% user's nick
               ref,  %% user's process monitor reference
               pid   %% user's process pid
              }).

sendpartmsg(#{broadcast := Broadcast, name := Name}, UserRec, PartMsg) ->
    Msg = {chanpart, {user, UserRec#user.name, UserRec#user.pid}, {channel, Name, self()}, PartMsg},
    broadcast:send(Broadcast, Msg),
    ok.

sendjoinmsg(#{broadcast := Broadcast, name := Name}, UserRec) ->
    Msg = {chanjoin, {user, UserRec#user.name, UserRec#user.pid}, {channel, Name, self()}},
    broadcast:send(Broadcast, Msg),
    ok.

sendbanmsg(State, UserRec) ->
    sendpartmsg(State, UserRec, none).

allusers(Users) ->
    GetUsers = fun(#user{name = UserNick, pid = UserPid}, Acc) ->
                       [{user, UserNick, UserPid}|Acc]
               end,
    ets:foldl(GetUsers, [], Users).

channel_joiner(Parent, _Name, []) ->
    unlink(Parent),
    ok;
channel_joiner(Parent, Name, Endpoints) ->
    channel_joiner(Parent, Name, Endpoints, 0).

channel_joiner(Parent, Name, [], N) ->
    unlink(Parent),
    logger:notice("channel ~p (~p): rejoined ~p users", [Name, Parent, N]),
    ok;
channel_joiner(Parent, Name, [Endpoint|Rest], N) ->
    case user_worker:gettuple(Endpoint) of
        {ok, User} ->
            channel:rejoin(Parent, User),
            channel_joiner(Parent, Name, Rest, N+1);
        _ ->
            channel_joiner(Parent, Name, Rest, N)
    end.

safe_check_flags(Nick, Chan, Flags, _State = #{userflags := Userflags}) ->
    case channel_server:is_permachan(Chan) of
        true ->
            irc_auth:check_flags(Nick, Chan, Flags);
        false ->
            Chanflag = maps:get(Nick, Userflags, #{}),
            {ok, Globalflag} = irc_auth:get_flags(Nick, global),
            Userflag = maps:merge(Chanflag, Globalflag),
            CheckFlags = fun CheckFlags([]) ->
                                 false;
                             CheckFlags([H|R]) ->
                                 case maps:get(H, Userflag, false) of
                                     false -> CheckFlags(R);
                                     true -> true
                                 end
                         end,
            CheckFlags(Flags)
    end.

safe_set_flag(Nick, Chan, Flag, Value) ->
    case channel_server:is_permachan(Chan) of
        true ->
            irc_auth:set_flag(Nick, Chan, Flag, Value);
        false ->
            %% this is a bit of a hack
            gen_server:cast(self(), {set_flag, Nick, Flag, Value})
    end.

safe_get_flag(Nick, Chan, Flag, Default, #{userflags := Userflags}) ->
    case channel_server:is_permachan(Chan) of
        true ->
            irc_auth:get_flag(Nick, Chan, Flag, Default);
        false ->
            Flags = maps:get(Nick, Userflags, #{}),
            maps:get(Flag, Flags, Default)
    end.

could_gc(#{users := Users, name := Name}) ->
    Nusers = ets:info(Users, size),
    GCchannel = cfg:config(chan_gc_empty_channels, false),
    Permachan = channel_server:is_permachan(Name),
    case {Nusers, Permachan, GCchannel} of
        {0, false, true} -> true;
        _ -> false
    end.

part_call_return(Reply, State) ->
    case could_gc(State) of
        true -> {stop, shutdown, Reply, State};
        false -> {reply, Reply, State}
    end.

part_cast_return(State) ->
    case could_gc(State) of
        true -> {stop, shutdown, State};
        false -> {noreply, State}
    end.

init([SupPid, takeover]) ->
    State = #{sup => SupPid,
              name => takeover,
              topic => takeover},
    gen_server:cast(self(), initialize_takeover),
    {ok, State};
init([SupPid, Name]) ->
    State = #{sup => SupPid,
              name => Name,
              topic => <<"intentionally left blank">>},
    Ref = make_ref(),
    names:register({channel, Name, self()}),
    gen_server:cast(self(), {initialize, Ref}),
    {ok, {Ref, State}}.

handle_cast({initialize, Ref}, {Ref, State0 = #{name := Name, sup := SupPid}}) ->
    Me = self(),
    Siblings = supervisor:which_children(SupPid),
    {_, Broadcast, _, _} = lists:keyfind(broadcast, 1, Siblings),
    {ok, Topic} = channel_server:topic(Name),
    {ok, Flags} = case channel_server:is_permachan(Name) of
                      false -> channel_server:flags(Name);
                      true -> {ok, #{}}
                  end,
    Users = ets:new(chan_users, [set, {keypos, #user.name}]),
    State = State0#{broadcast => Broadcast,
                    users => Users,
                    topic => Topic,
                    userflags => Flags},
    {ok, Endpoints} = broadcast:endpoints(Broadcast),
    spawn_link(fun() -> channel_joiner(Me, Name, Endpoints) end),
    {noreply, State};

handle_cast(initialize_takeover, State0 = #{sup := SupPid}) ->
    Siblings = supervisor:which_children(SupPid),
    {_, Broadcast, _, _} = lists:keyfind(broadcast, 1, Siblings),
    Users = ets:new(chan_users, [set, {keypos, #user.name}]),
    State = State0#{broadcast => Broadcast, users => Users},
    {noreply, State};

handle_cast({set_flag, Nick, Flag, Value}, State0 = #{name := Name, userflags := Userflags0}) ->
    Userflag0 = maps:get(Nick, Userflags0, #{}),
    Userflag = Userflag0#{Flag => Value},
    Userflags = Userflags0#{Nick => Userflag},
    channel_server:update_flags(Name, Userflags),
    {noreply, State0#{userflags => Userflags}};

handle_cast(crash_me, #{name := Name}) ->
    logger:notice("channel ~p (~p): crashing!", [Name, self()]),
    exit(induced_crash);

handle_cast({finish_takeover, TargetPid}, State) ->
    channel:takeover_shutdown(TargetPid),
    {noreply, State};

handle_cast(Msg, State) ->
    case cfg:config(chan_unhandled_msg, log) of
        log ->
            logger:notice("channel ~p cast: unhandled message: ~p", [self(), Msg]);
        {log, Level} ->
            logger:log(Level, "channel ~p cast: unhandled message: ~p", [self(), Msg]);
        crash ->
            logger:error("channel ~p cast: unhandled message: ~p", [self(), Msg]),
            exit(unhandled_message);
        silent ->
            ok
    end,
    {noreply, State}.

handle_info({'DOWN', Ref, process, _Pid, Reason},
            State = #{users := Users, broadcast := Broadcast}) ->
    MS = ets:fun2ms(fun(X = #user{ref = R}) when R == Ref -> X end),
    [UserRec] = ets:select(Users, MS),
    ets:delete(Users, UserRec#user.name),
    broadcast:remove_endpoint(Broadcast, UserRec#user.ref),
    PartMsg = case Reason of
                  noconnection -> <<"user's node went down">>;
                  shutdown -> <<"disconnected">>;
                  noproc -> <<"ghost user exorcised">>;
                  _ -> <<"user went MIA">>
              end,
    sendpartmsg(State, UserRec, PartMsg),
    part_cast_return(State);

%% messages use the "general message protocol" instead of gen_server
%% handle messages for this channel
handle_info(Msg = {message, MsgRef, _From = {user, Nick, Pid}, _To = {channel, Chan, _}, _Data},
            State = #{users := Users, broadcast := Broadcast, name := Chan}) ->
    case ets:member(Users, Nick) of
        true ->
            broadcast:send_nowait(Broadcast, Msg),
            Pid ! {MsgRef, ok},
            {noreply, State};
        false ->
            Pid ! {MsgRef, {error, not_joined}},
            {noreply, State}
    end;
%% return to sender
handle_info(Msg = {message, MsgRef, {_, _, Pid}, _, _}, State) ->
    Pid ! {MsgRef, {error, rts}},
    case cfg:config(chan_unhandled_msg, silent) of
        crash ->
            logger:info("channel ~p: message astray: ~p", [self(), Msg]),
            exit(message_astray);
        log ->
            logger:info("channel ~p: message astray: ~p", [self(), Msg]);
        {log, Level} ->
            logger:log(Level, "channel ~p: message astray: ~p", [self(), Msg]);
        silent ->
            ok
    end,
    {noreply, State};

handle_info({topic,
             From = {user, _FromNick, FromPid},
             Channel = {channel, Chan, _},
             query},
            State = #{name := Chan, topic := Topic}) ->
    FromPid ! {ircmsg, rpl_topic, Channel, From, {default, [Channel, Topic]}},
    {noreply, State};
handle_info({topic,
             From = {user, FromNick, FromPid},
             Channel = {channel, Chan, _},
             NewTopic},
            State0 = #{name := Chan, broadcast := Broadcast}) ->
    case safe_check_flags(FromNick, Chan, [operator, owner], State0) of
        true ->
            State = State0#{topic => NewTopic},
            Msg = {ircmsg, topic, From, Channel, NewTopic},
            broadcast:send_nowait(Broadcast, Msg),
            channel_server:update_topic(Chan, NewTopic),
            {noreply, State};
        false ->
            FromPid ! {ircmsg, err_chanoprivsneeded, Channel, From, {default, Channel}},
            {noreply, State0}
    end;

handle_info({mode, _From = {user, _FromNick, _FromPid},
             _Channel = {channel, Chan, _},
             {list, _ModeList},
             _User = {user, _UserNick, _}},
            State = #{users := _Users, broadcast := _Broadcast, name := Chan}) ->
    {noreply, State};
handle_info({mode, From = {user, FromNick, FromPid},
             Channel = {channel, Chan, _},
             {Op, ModeList},
             User = {user, UserNick, UserPid}},
            State = #{broadcast := Broadcast, name := Chan}) ->
    SetFlag = fun (Flag, O) ->
                      FlagValue = case O of
                                      add -> true;
                                      remove -> false
                                  end,
                      safe_set_flag(UserNick, Chan, Flag, FlagValue),
                      Msg = {ircmsg, mode, Channel, User, {O, [Flag]}},
                      broadcast:send_nowait(Broadcast, Msg)
              end,
    OperApplyModes = fun OperApplyModes(_, []) -> ok;
                         OperApplyModes(O, [operator|Rest]) ->
                             SetFlag(operator, O),
                             OperApplyModes(O, Rest);
                         OperApplyModes(O, [ban|Rest]) ->
                             SetFlag(ban, O),
                             UserPid ! {ban, O, User, Channel, From},
                             OperApplyModes(O, Rest);
                         OperApplyModes(O, [_|Rest]) ->
                             OperApplyModes(O, Rest)
                     end,
    case safe_check_flags(FromNick, Chan, [operator, owner], State) of
        false ->
            FromPid ! {ircmsg, err_chanoprivsneeded, Channel, From, {default, Channel}},
            {noreply, State};
        true ->
            OperApplyModes(Op, ModeList),
            {noreply, State}
    end;

handle_info({names, _From = {user, _FromNick, FromPid}, Channel = {channel, Chan, _}},
            State = #{users := Users, name := Chan}) ->
    FromPid ! {channames, Channel, allusers(Users)},
    {noreply, State};

handle_info({who, _From = {user, _FromNick, FromPid}, Channel = {channel, Chan, _}},
            State = #{users := Users, name := Chan}) ->
    FromPid ! {chanwho, Channel, allusers(Users)},
    {noreply, State};

handle_info({kick, From = {user, FromNick, FromPid}, Channel = {channel, Chan, _}, Users, Message},
            State = #{broadcast := Broadcast, name := Chan}) ->
    SendKick = fun SendKick([]) ->
                       ok;
                   SendKick([User = {user, _, _}|Rest]) ->
                       broadcast:send_nowait(Broadcast, {chankick, Channel, From, User, Message}),
                       SendKick(Rest);
                   SendKick([_|Rest]) ->
                       SendKick(Rest)
               end,
    case safe_check_flags(FromNick, Chan, [operator, owner], State) of
        true ->
            SendKick(Users);
        false ->
            FromPid ! {ircmsg, err_chanoprivsneeded, Channel, From, {default, Channel}}
    end,
    {noreply, State};

handle_info(Msg, State) ->
    case cfg:config(chan_unhandled_msg, log) of
        log ->
            logger:notice("channel ~p info: unhandled message: ~p", [self(), Msg]);
        {log, Level} ->
            logger:log(Level, "channel ~p info: unhandled message: ~p", [self(), Msg]);
        crash ->
            logger:error("channel ~p info: unhandled message: ~p", [self(), Msg]),
            exit(unhandled_message);
        silent ->
            ok
    end,
    {noreply, State}.

handle_call({join, UserId = {user, Nick, Pid}, Restart}, _From,
            State = #{users := Users, broadcast := Broadcast, name := ChanName, topic := Topic}) ->
    case {ets:member(Users, Nick),
          safe_get_flag(Nick, ChanName, ban, false, State)} of
        {_, true} ->
            {reply, {error, user_banned}, State};
        {false, false} ->
            Ref = monitor(process, Pid),
            User = #user{name = Nick, ref = Ref, pid = Pid},
            true = ets:insert(Users, User),
            case Restart of
                false ->
                    broadcast:add_endpoint(Broadcast, Ref, Pid),
                    sendjoinmsg(State, User);
                true ->
                    irc_verify:msg(Pid, {chanrejoin, UserId, {channel, ChanName, self()}})
            end,
            Channel = {channel, ChanName},
            case {Topic, Restart} of
                {<<"">>, false} ->
                    Pid ! {ircmsg, rpl_notopic, Channel, UserId, {default, Channel}};
                {Topic, false} when is_binary(Topic) ->
                    Pid ! {ircmsg, rpl_topic, Channel, UserId, {default, [Channel, Topic]}};
                {_, false} ->
                    Pid ! {ircmsg, rpl_notopic, Channel, UserId, {default, Channel}};
                {_, true} ->
                    ok
            end,
            case {application:get_env(veetyircd, chan_send_join_names, false), Restart} of
                {true, false} -> Pid ! {channames, Channel, allusers(Users)};
                _ -> ok
            end,
            {reply, ok, State};
        {true, false} ->
            {reply, {error, user_exists}, State}
    end;

handle_call({part, {user, Nick, _}, Msg}, _From,
            State = #{users := Users, broadcast := Broadcast}) ->
    case ets:lookup(Users, Nick) of
        [UserRec] ->
            demonitor(UserRec#user.ref, [flush]),
            ets:delete(Users, UserRec#user.name),
            sendpartmsg(State, UserRec, Msg),
            broadcast:remove_endpoint(Broadcast, UserRec#user.ref),
            part_call_return(ok, State);
        _ ->
            {reply, {error, no_user}, State}
    end;

handle_call({remove_user, {user, Nick, _}}, _From,
            State = #{users := Users, broadcast := Broadcast}) ->
    case ets:lookup(Users, Nick) of
        [UserRec] ->
            demonitor(UserRec#user.ref, [flush]),
            ets:delete(Users, UserRec#user.name),
            broadcast:remove_endpoint(Broadcast, UserRec#user.ref),
            part_call_return(ok, State);
        _ ->
            {reply, {error, no_user}, State}
    end;

handle_call({ban, {user, Nick, _}}, _From,
            State = #{users := Users, broadcast := Broadcast}) ->
    case ets:lookup(Users, Nick) of
        [UserRec] ->
            demonitor(UserRec#user.ref, [flush]),
            ets:delete(Users, UserRec#user.name),
            sendbanmsg(State, UserRec),
            broadcast:remove_endpoint(Broadcast, UserRec#user.ref),
            {reply, ok, State};
        _ ->
            {reply, {error, no_user}, State}
    end;

handle_call({get_flags, Nick}, _From, State = #{userflags := Userflags}) ->
    {reply, {ok, maps:get(Nick, Userflags, #{})}, State};

handle_call({update_flags, Nick, NewFlags}, _From, State0 = #{name := Name, userflags := Userflags0}) ->
    Userflags = Userflags0#{Nick => NewFlags},
    channel_server:update_flags(Name, Userflags),
    State = State0#{userflags := Userflags},
    {reply, ok, State};

handle_call(all_flags, _From, State = #{userflags := Userflags}) ->
    {reply, {ok, Userflags}, State};

handle_call(supervisor, _From, State = #{sup := SupPid}) ->
    {reply, {ok, SupPid}, State};

handle_call(takeover_shutdown, _From, State) ->
    {stop, shutdown, ok, State};

handle_call(get_endpoints, _From, State = #{broadcast := Broadcast}) ->
    Status = broadcast:endpoints(Broadcast),
    {reply, Status, State};

handle_call(get_takeover_data, _From, State = #{name := Name, topic := Topic, userflags := Userflags}) ->
    {reply, {Name, Topic, Userflags}, State};

handle_call({do_takeover, TargetPid}, _From,
            State0 = #{sup := Sup, users := Users, broadcast := Broadcast}) ->
    {Name, Topic, Userflags} = channel:get_takeover_data(TargetPid),
    {ok, Endpoints} = channel:get_endpoints(TargetPid),
    names:unregister({channel, Name}),
    names:register({channel, Name, self()}),
    State = State0#{name => Name,
                    topic => Topic,
                    userflags => Userflags},
    Rejoin = fun (EpPid, Acc0) ->
                     case user_worker:gettuple(EpPid) of
                         {ok, Uid = {user, Nick, EpPid}} ->
                             Ref = monitor(process, EpPid),
                             User = #user{name = Nick, ref = Ref, pid = EpPid},
                             true = ets:insert(Users, User),
                             broadcast:add_endpoint(Broadcast, Ref, EpPid),
                             ok = irc_verify:msg(EpPid, {chanrejoin, Uid, Sup, {channel, Name, self()}}),
                             [ok|Acc0];
                         _ ->
                             Acc0
                     end
             end,
    S = lists:foldl(Rejoin, [], Endpoints),
    Nusers = length(S),
    ok = channel_server:do_takeover(TargetPid, Name, Sup, Topic, Userflags),
    takeover_shutdown(TargetPid),
    logger:notice("channel ~p (~p -> ~p): takeover complete, ~p users rejoined",
                  [Name, TargetPid, self(), Nusers]),
    {reply, ok, State};

handle_call(Msg, _From, State) ->
    case cfg:config(chan_unhandled_msg, log) of
        log ->
            logger:notice("channel ~p call: unhandled message: ~p", [self(), Msg]);
        {log, Level} ->
            logger:log(Level, "channel ~p call: unhandled message: ~p", [self(), Msg]);
        crash ->
            logger:error("channel ~p call: unhandled message: ~p", [self(), Msg]),
            exit(unhandled_message);
        silent ->
            ok
    end,
    {noreply, State}.

code_change(_, State, _) ->
    {ok, State}.

terminate(shutdown, #{name := Name}) ->
    logger:info("channel ~p (~p): shutting down", [Name, self()]),
    ok;
terminate(_, _) ->
    ok.

server_start(SupPid, Name) ->
    gen_server:start_link(?MODULE, [SupPid, Name], []).

start_link(Name) ->
    channel_sup:start_link(Name).

get_pid(SupPid) ->
    Siblings = supervisor:which_children(SupPid),
    {_, Pid, _, _} = lists:keyfind(channel, 1, Siblings),
    Pid.

join(Pid, User) ->
    gen_server:call(Pid, {join, User, false}).

rejoin(Pid, User) ->
    gen_server:call(Pid, {join, User, true}).

rejoin_takeover(Pid, User) ->
    gen_server:call(Pid, {join, User, takeover}).

part(Pid, User, Msg) ->
    gen_server:call(Pid, {part, User, Msg}).

ban(Pid, User) ->
    gen_server:call(Pid, {ban, User}).

remove_user(Pid, User) ->
    gen_server:call(Pid, {remove_user, User}).

get_flags(Pid, User) ->
    gen_server:call(Pid, {get_flags, User}).

update_flags(Pid, User, Flags) ->
    gen_server:call(Pid, {update_flags, User, Flags}).

all_flags(Pid) ->
    gen_server:call(Pid, all_flags).

supervisor(Pid) ->
    gen_server:call(Pid, supervisor, infinity).

topic(Pid) ->
    {_, Topic, _} = get_takeover_data(Pid),
    Topic.

nusers(Pid) ->
    {ok, Endpoints} = get_endpoints(Pid),
    length(Endpoints).

%% stuff for takeovers

takeover_shutdown(Pid) ->
    gen_server:call(Pid, takeover_shutdown).

get_endpoints(Pid) ->
    gen_server:call(Pid, get_endpoints).

get_takeover_data(Pid) ->
    gen_server:call(Pid, get_takeover_data).

do_takeover(Pid, TargetPid) ->
    gen_server:call(Pid, {do_takeover, TargetPid}).

takeover({channel, _, TargetPid}) ->
    takeover(TargetPid);
takeover(TargetPid) when is_pid(TargetPid) ->
    {ok, {channel, takeover, TakeChan}} = channel_server:create_takeover(),
    ok = do_takeover(TakeChan, TargetPid),
    {ok, {TargetPid, TakeChan}}.
