-module(user_worker).
%% otp functions
-export([init/1, system_continue/3, system_terminate/4, system_code_change/4,
         system_replace_state/2, system_get_state/1]).
%% module functions
-export([start_link/0, loop/3, getmodes/1, getnode/1, gettuple/1, quit/1]).

%% otp stuff

handle_system_msg({system, From, Request}, {Parent, Debug}, Stage, State) ->
    sys:handle_system_msg(Request, From, Parent, ?MODULE, Debug, {Stage, State}).

system_continue(Parent, Debug, {Stage, State}) ->
    loop({Parent, Debug}, Stage, State).

system_terminate(Reason, _, _, _) ->
    exit(Reason).

system_code_change(State = {_, #{cc_ref := CCRef}}, _Module, _OldVsn, _Extra) ->
    self() ! {code_change, CCRef},
    {ok, State}.

system_replace_state(StateFun, State) ->
    NState = StateFun(State),
    {ok, NState, NState}.

system_get_state(State) ->
    {ok, State}.

%% State = #{
%%           connpid,
%%           name_cache,
%%           nick,
%%           user,
%%           realname,
%%           channels
%%          }.

split_all([], Acc, _) ->
    Acc;
split_all(List, Acc, Size) when Size =< length(List) ->
    {L0, Rest} = lists:split(Size, List),
    split_all(Rest, [L0|Acc], Size);
split_all(List, Acc, Size) when Size > length(List) ->
    split_all([], [List|Acc], Size).

%% my question here is do i really need the reverse calls?
%% do the users really care?

make_names_msgs(From, To, Chan, [], Acc0) ->
    Acc1 = [{rpl_endofnames, From, To, {default, Chan}}|Acc0],
    lists:reverse(Acc1);
make_names_msgs(From, To, Chan, [NickBlock|Rest], Acc0) ->
    Msg = {rpl_namreply, From, To, {default, {Chan, NickBlock}}},
    Acc = [Msg|Acc0],
    make_names_msgs(From, To, Chan, Rest, Acc).

make_names_msgs(From, To, Chan, Names) ->
    NickBlocks = lists:reverse(split_all(Names, [], 5)),
    make_names_msgs(From, To, Chan, NickBlocks, []).

make_who_msg(From, To, Chan = {channel, ChanName, _}, {user, Nick, Pid}) ->
    Op = irc_auth:check_flags(Nick, ChanName, [operator, owner]),
    {rpl_whoreply, From, To, {default, {Chan, node(Pid), Nick, Op}}}.

make_who_msgs(From, To, Chan, Names) ->
    Fmtfn = fun(N, Acc0) ->
                    Msg = make_who_msg(From, To, Chan, N),
                    [Msg|Acc0]
            end,
    EndMsg = {rpl_endofwho, From, To, {default, Chan}},
    lists:foldl(Fmtfn, [EndMsg], Names).

userhost({user, Nick, Pid}) ->
    {userhost, Nick, Pid};
userhost({user, Nick}) ->
    {userhost, Nick}.

%% entry and user setup
loop(Pinfo, start, _) ->
    CCRef = make_ref(),
    receive
        {conn, Ref, Pid} ->
            link(Pid),
            State = #{ connpid => Pid
                     , name_cache => names:new_cache()
                     , nick => <<"">>
                     , password => <<"">>
                     , user => <<"">>
                     , realname => <<"">>
                     , channels => {#{}, #{}}
                     , cc_ref => CCRef
                     , user_modes => #{}
                     , retries => 0
                     , client_node => none
                     },
            Pid ! {ok, Ref, self()},
            loop(Pinfo, conn_start0, State);
        cancel ->
            ok;
        Msg = {system, _, _} ->
            handle_system_msg(Msg, Pinfo, start, none);
        {code_change, CCRef} ->
            ?MODULE:loop(Pinfo, start, none);
        {quit, _} ->
            exit(shutdown)
    after
        5000 ->
            exit(timeout)
    end;
loop(Pinfo, conn_start0, State0 = #{cc_ref := CCRef, connpid := Connpid}) ->
    receive
        {nick, Nick} ->
            loop(Pinfo, conn_start1, State0#{nick => Nick});
        {pass, Password} ->
            loop(Pinfo, conn_start0, State0#{password => Password});
        {cap, ls, _} ->
            irc_verify:msg(Connpid, {ircmsg, {cap, <<"* LS : ">>}}),
            loop(Pinfo, conn_start0, State0);
        {cap, endcap} ->
            loop(Pinfo, conn_start0, State0);
        cancel ->
            ok;
        Msg = {system, _, _} ->
            handle_system_msg(Msg, Pinfo, conn_start0, State0);
        {code_change, CCRef} ->
            ?MODULE:loop(Pinfo, conn_start0, State0);
        {quit, _} ->
            Quitref = make_ref(),
            Connpid ! {quit, Quitref, self()},
            loop(Pinfo, quit, {Quitref, Connpid})
    end;
loop(Pinfo, conn_start1, State0 = #{nick := Nick, cc_ref := CCRef, connpid := Connpid}) ->
    receive
        {nick, Nick} ->
            loop(Pinfo, conn_start1, State0#{nick => Nick});
        {user, Username, _Mode, ClientNode, Realname} ->
            State = State0#{user => Username,
                            realname => Realname,
                            client_node => ClientNode},
            loop(Pinfo, auth, State);
        {pass, Password} ->
            loop(Pinfo, conn_start0, State0#{password => Password});
        {cap, ls, _} ->
            irc_verify:msg(Connpid, {ircmsg, {cap, <<"* LS : ">>}}),
            loop(Pinfo, conn_start0, State0);
        {cap, endcap} ->
            loop(Pinfo, conn_start0, State0);
        cancel ->
            ok;
        Msg = {system, _, _} ->
            handle_system_msg(Msg, Pinfo, conn_start1, State0);
        {code_change, CCRef} ->
            ?MODULE:loop(Pinfo, conn_start1, State0);
        {quit, _} ->
            Quitref = make_ref(),
            Connpid ! {quit, Quitref, self()},
            loop(Pinfo, quit, {Quitref, Connpid})
    end;

%% authentication
loop(Pinfo, auth, State = #{nick := <<"">>}) ->
    loop(Pinfo, conn_start1, State);
loop(Pinfo, auth, State0 = #{nick := Nick, connpid := Connpid, password := Password}) ->
    case cfg:config(auth, enabled) of
        enabled ->
            State = State0#{auth_status => irc_auth:check_user(Nick, Password), password => redacted},
            loop(Pinfo, auth1, State);
        _ ->
            ok = user_server:register(Nick, self()),
            WelMsg = case cfg:config(user_welcome_message, none) of
                         none -> 
                             {ircmsg, {rpl_welcome, host, {user, Nick}}};
                         {Msg, user} when is_binary(Msg) ->
                             {ircmsg, {rpl_welcome, host, {user, Nick}, {default, {msg, Msg, Nick}}}};
                         Msg when is_binary(Msg) ->
                             {ircmsg, {rpl_welcome, host, {user, Nick}, Msg}};
                         Msg ->
                             logger:notice("user_worker ~p: invalid user_welcome_message: ~p", [self(), Msg]),
                             {ircmsg, {rpl_welcome, host, {user, Nick}}}
                     end,
            irc_verify:msg(Connpid, WelMsg),
            State = State0#{password => redacted},
            case cfg:config(user_print_login_motd, false) of
                true -> loop(Pinfo, motd, State);
                _ -> loop(Pinfo, main, State)
            end
    end;

%%% i should probably do this instead. idk how i should handle this exactly
%%% both kick the old user and kick the new user has been suggested. maybe
%%% configurable. who knows
%% loop(Pinfo, auth1, State = #{auth_status := ok, nick := Nick, connpid := Connpid}) ->
%%     case user_server:register(Nick, self()) of
%%         ok ->
%%             Connpid ! {ircmsg, {rpl_welcome, host, {user, Nick}}},
%%             loop(Pinfo, main, State);
%%         {error, user_exists} ->
%%             ok = irc_verify(Connpid, {ircmsg, {err_nicknameinuse, host, any, {default, Nick}}}),
%%             exit(shutdown)
%%     end;
loop(_, auth1, #{retries := Retries}) when Retries >= 5 ->
    exit(too_many_retries);
loop(Pinfo, auth1, State = #{auth_status := ok, nick := Nick, connpid := Connpid, retries := Retries}) ->
    case user_server:register(Nick, self()) of
        {error, user_exists} ->
            case cfg:config(user_kick_old_session, false)
                or irc_auth:check_flags(Nick, global, [kick_old_session]) of
                false ->
                    ok = irc_verify:msg(Connpid, {ircmsg, {err_nicknameinuse, host, any, {default, Nick}}}),
                    Quitref = monitor(process, Connpid),
                    Connpid ! {quit, Quitref, self()},
                    receive
                        {quit, Quitref, none} ->
                            Connpid ! {quit_ok, Quitref},
                            exit(shutdown);
                        {'DOWN', Quitref, process, _, _} ->
                            exit(shutdown)
                    end;
                true ->
                    case names:lookup({user, Nick}) of
                        {ok, {user, Nick, OldPid}} ->
                            ok = quit(OldPid),
                            loop(Pinfo, auth1, State#{retries => Retries + 1});
                        {error, no_user} ->
                            loop(Pinfo, auth1, State#{retries => Retries + 1})
                    end
            end;
        ok ->
            WelMsg = case cfg:config(user_welcome_message, none) of
                         none -> 
                             {ircmsg, {rpl_welcome, host, {user, Nick}}};
                         {Msg, user} when is_binary(Msg) ->
                             {ircmsg, {rpl_welcome, host, {user, Nick}, {default, {msg, Msg, Nick}}}};
                         {Msg, user} when is_list(Msg) ->
                             Msg0 = list_to_binary(Msg),
                             {ircmsg, {rpl_welcome, host, {user, Nick}, {default, {msg, Msg0, Nick}}}};
                         Msg when is_binary(Msg) ->
                             {ircmsg, {rpl_welcome, host, {user, Nick}, Msg}};
                         Msg when is_list(Msg) ->
                             Msg0 = list_to_binary(Msg),
                             {ircmsg, {rpl_welcome, host, {user, Nick}, Msg0}};
                         Msg ->
                             logger:notice("user_worker ~p: invalid user_welcome_message: ~p", [self(), Msg]),
                             {ircmsg, {rpl_welcome, host, {user, Nick}}}
                     end,
            irc_verify:msg(Connpid, WelMsg),
            case cfg:config(user_print_login_motd, false) of
                true -> loop(Pinfo, motd, State);
                _ -> loop(Pinfo, main, State)
            end
    end;

loop(_Pinfo, auth1, State = #{auth_status := {error, Reason}, nick := Nick, connpid := Connpid}) ->
    ok = irc_verify:msg(Connpid, {ircmsg, {err_restricted, host, {user, Nick}}}),
    case cfg:config(auth_failure, crash) of
        crash ->
            exit({error, bad_login, State, Reason});
        log ->
            logger:notice("bad login: reason = ~p, nick = ~p", [Reason, Nick]),
            exit(shutdown);
        {log, state} ->
            logger:notice("bad login: reason = ~p, nick = ~p, state = ~p", [Reason, Nick, State]),
            exit(shutdown);
        {log, Level} ->
            logger:log(Level, "bad login: reason = ~p, nick = ~p", [Reason, Nick]),
            exit(shutdown);
        {{log, Level}, state} ->
            logger:log(Level, "bad login: reason = ~p, nick = ~p, state = ~p", [Reason, Nick, State]),
            exit(shutdown);
        silent ->
            exit(shutdown);
        EnvVar = _ ->
            logger:warning("invalid auth_failure: auth_failure = ~p", [EnvVar]),
            exit([{error, bad_env_var}, {error, bad_login, State, Reason}])
    end;

loop(_Pinfo, auth1, State = #{auth_status := IdkMan}) ->
    logger:error("user_worker idkman: state = ~p", [State]),
    error({idkman, IdkMan});

loop(Pinfo, motd, State = #{connpid := Connpid}) ->
    case data_server:get_formatted_motd(host, any) of
        {ok, Motd} -> Connpid ! Motd;
        _ -> ok
    end,
    loop(Pinfo, main, State);

loop(Pinfo, main, State0 = #{nick := Nick, name_cache := NameCache0,
                             connpid := Connpid, cc_ref := CCRef,
                             channels := Channels0, user_modes := Usermodes0}) ->
    Self = {user, Nick, self()},
    Self0 = {user, Nick},
    receive
        %% system messages
        SysMsg = {system, _, _} ->
            handle_system_msg(SysMsg, Pinfo, main, State0);
        {code_change, CCRef} ->
            ?MODULE:loop(Pinfo, main, State0);
        {getccref, MsgRef, From} ->
            From ! {ccref, MsgRef, CCRef},
            loop(Pinfo, main, State0);
        {'DOWN', Ref, process, _Pid, _Reason} ->
            %% this case really fucking annoys me.
            case remove_channel_ref(Ref, Channels0) of
                {ok, Channels, Channel} ->
                    Connpid ! {ircmsg, {part, userhost(Self), Channel, {default, <<"channel died">>}}},
                    loop(Pinfo, main, State0#{channels => Channels});
                {error, bad_ref} ->
                    loop(Pinfo, main, State0)
            end;

        %% messages from other users or channels
        {message, _MsgRef, Self, {channel, _, _}, _Data} -> %% from me to channel
            loop(Pinfo, main, State0);
        {message, _MsgRef, From, To = {channel, _, _}, Data} -> %% from other to channel
            Connpid ! {ircmsg, {privmsg, From, To, Data}},
            loop(Pinfo, main, State0);
        {message, MsgRef, From = {_, _, FromPid}, Self, Data} -> %% from other to me
            Connpid ! {ircmsg, {privmsg, From, Self, Data}},
            FromPid ! {MsgRef, ok},
            loop(Pinfo, main, State0);
        Msg = {message, MsgRef, {_, _, FromPid}, _To, _Data} -> %% from other to other
            FromPid ! {MsgRef, {error, rts}},
            case cfg:config(user_unhandled_msg, silent) of
                crash ->
                    logger:info("user_worker ~p: message astray: ~p", [self(), Msg]),
                    exit(message_astray);
                log ->
                    logger:info("user_worker ~p: message astray: ~p", [self(), Msg]);
                {log, Level} ->
                    logger:log(Level, "user_worker ~p: message astray: ~p", [self(), Msg]);
                silent ->
                    ok
            end,
            loop(Pinfo, main, State0);
        {chanjoin, Self, Channel} ->
            Channels = add_channel(Channel, Channels0),
            Connpid ! {ircmsg, {join, userhost(Self), Channel}},
            loop(Pinfo, main, State0#{channels := Channels});
        {chanjoin, User = {user, UserNick, _}, Channel = {channel, ChanName, _}} ->
            Connpid ! {ircmsg, {join, userhost(User), Channel}},
            case irc_auth:check_flags(UserNick, ChanName, [operator, owner]) of
                true -> self() ! {ircmsg, mode, Channel, User, {add, [operator]}};
                false -> ok
            end,
            loop(Pinfo, main, State0);
        {verify, Rts, {chanrejoin, Self, ChanSup, Channel = {channel, _Name, _}}} ->
            Channels = update_channel_mon(Channel, ChanSup, Channels0),
            logger:info("user_worker ~p: (verified) rejoined ~p", [self(), Channel]),
            irc_verify:reply(Rts),
            loop(Pinfo, main, State0#{channels := Channels});
        {chanrejoin, Self, ChanSup, Channel = {channel, _Name, _}} ->
            Channels = update_channel_mon(Channel, ChanSup, Channels0),
            logger:info("user_worker ~p: rejoined ~p", [self(), Channel]),
            loop(Pinfo, main, State0#{channels := Channels});
        {chanpart, Self, Channel, Msg} ->
            {ok, Channels} = remove_channel_name(Channel, Channels0),
            Connpid ! {ircmsg, {part, userhost(Self), Channel, {default, Msg}}},
            loop(Pinfo, main, State0#{channels := Channels});
        {chanpart, User, Channel, Msg} ->
            Connpid ! {ircmsg, {part, userhost(User), Channel, {default, Msg}}},
            loop(Pinfo, main, State0);
        {chanban, Channel} ->
            Connpid ! {ircmsg, {err_bannedfromchan, host, any, {default, Channel}}},
            loop(Pinfo, main, State0);
        {chanmissing, Channel = {channel, NewChanName}} ->
            case {cfg:config(chan_create_missing, false),
                  irc_auth:user_exists(Nick),
                  channel_server:is_permachan(NewChanName)} of
                {true, true, false} ->
                    {ok, NewChan} = channel_server:cluster_create(NewChanName, <<"Automatically created topic!">>),
                    {channel, NewChanName, ChanPid} = NewChan,
                    ok = irc_auth:set_flag(Nick, NewChanName, owner, true),
                    channel:join(ChanPid, Self),
                    NameCache1 = names:add_cache(NameCache0, NewChan),
                    loop(Pinfo, main, State0#{name_cache := NameCache1});
                _ ->
                    Connpid ! {ircmsg, {err_nosuchchannel, host, any, {default, Channel}}},
                    loop(Pinfo, main, State0)
            end;
        {ban, add, Self, Channel = {channel, _, ChanPid}, _From = {user, _FromNick, _}} ->
             {ok, Channels} = remove_channel_name(Channel, Channels0),
            channel:ban(ChanPid, Self),
            loop(Pinfo, main, State0#{channels => Channels});
        {ban, _, _, _} ->
            loop(Pinfo, main, State0);
        {channames, Channel, Names} ->
            Msgs = make_names_msgs(host, any, Channel, Names),
            Connpid ! {ircmultipart, Msgs},
            loop(Pinfo, main, State0);
        {chankick, Channel = {channel, _, ChanPid}, From, Self, Msg} ->
            irc_verify:msg(Connpid, {ircmsg, {kick, From, Channel, {default, {Self, Msg}}}}),
            {ok, Channels} =  remove_channel_name(Channel, Channels0),
            channel:remove_user(ChanPid, Self),
            loop(Pinfo, main, State0#{channels => Channels});
        {chankick, Channel, From, User, Msg} ->
            Connpid ! {ircmsg, {kick, From, Channel, {default, {User, Msg}}}},
            loop(Pinfo, main, State0);
        {chanwho, Channel, Names} ->
            Msgs = make_who_msgs(host, any, Channel, Names),
            Connpid ! {ircmultipart, Msgs},
            loop(Pinfo, main, State0);
        {MsgRef, _} when is_reference(MsgRef) ->
            loop(Pinfo, main, State0);
        %% ircmsg's are special messages that need no processing on this end
        %% valid sysmsgs are all status numbers and/or defined reply0 cases
        {ircmsg, Msgs} when is_list(Msgs) ->
            Connpid ! {ircmultipart, Msgs},
            loop(Pinfo, main, State0);
        Msg = {ircmsg, Body} when is_tuple(Body) ->
            Connpid ! Msg,
            loop(Pinfo, main, State0);
        {ircmsg, Type, Aux} ->
            Connpid ! {ircmsg, {Type, Aux}},
            loop(Pinfo, main, State0);
        {ircmsg, Type, From, To} ->
            Connpid ! {ircmsg, {Type, From, To}},
            loop(Pinfo, main, State0);
        {ircmsg, Type, From, To, Data} ->
            Connpid ! {ircmsg, {Type, From, To, Data}},
            loop(Pinfo, main, State0);

        %% messages from Connpid
        {privmsg, Victim0, Data} ->
            case {names:lookup(NameCache0, Victim0), Victim0} of
                {{ok, NameCache1, Victim}, _} ->
                    State1 = State0#{name_cache => NameCache1},
                    Msg = message:make(Self, Victim, Data),
                    case message:send(Msg) of
                        ok ->
                            ok;
                        {error, _} ->
                            ok
                    end,
                    loop(Pinfo, main, State1);
                {{error, _}, {channel, _}} ->
                    Connpid ! {ircmsg, {err_cannotsendtochan, host, Self, {default, Victim0}}},
                    loop(Pinfo, main, State0);
                {{error, _}, {user, _}} ->
                    Connpid ! {ircmsg, {err_nosuchnick, host, Self, {default, Victim0}}},
                    loop(Pinfo, main, State0);
                _ ->
                    loop(Pinfo, main, State0)
            end;
        %% {join, NewChannels, _} ->
        %%     NameCache1 = do_joins(Self, NameCache0, NewChannels),
        %%     State1 = State0#{name_cache => NameCache1},
        %%     loop(Pinfo, main, State1);
        {join, NewChannels, _} ->
            do_joins(Self, NameCache0, NewChannels),
            loop(Pinfo, main, State0);
        %% {part, OldChannels, Msg0} ->
        %%     Msg = case Msg0 of
        %%               [] -> none;
        %%               [X] when is_binary(X) -> X
        %%           end,
        %%     NameCache1 = do_parts(Self, NameCache0, OldChannels, Msg),
        %%     State1 = State0#{name_cache => NameCache1},
        %%     loop(Pinfo, main, State1);
        {part, OldChannels, Msg0} ->
            Msg = case Msg0 of
                      [] -> none;
                      [X] when is_binary(X) -> X
                  end,
            do_parts(Self, NameCache0, OldChannels, Msg),
            loop(Pinfo, main, State0);
        {mode, _Channel = {channel, _}, none, none} ->
            %% Connpid ! {ircmsg, {err_nochanmodes, host, Self, {default, Channel}}},
            loop(Pinfo, main, State0);
        {mode, Channel0 = {channel, _}, {list, Modelist}, none} ->
            case lists:member(ban, Modelist) of
                true ->
                    Connpid ! {ircmsg, {rpl_endofbanlist, host, Self, {default, Channel0}}};
                false ->
                    ok
            end,
            loop(Pinfo, main, State0);
        {mode, Channel0 = {channel, _}, Modes, User0} ->
            UserNameLookup = fun(OldCache, none) ->
                                     {OldCache, none};
                                (OldCache, PUser) ->
                                        case names:lookup(OldCache, PUser) of
                                            {ok, NewCache, User} -> {NewCache, User};
                                            {error, _} -> {OldCache, none}
                                        end
                                end,
            case names:lookup(NameCache0, Channel0) of
                {ok, NameCache1, Channel = {channel, _, ChanPid}} ->
                    {NameCache2, User} = UserNameLookup(NameCache1, User0),
                    State1 = State0#{name_cache => NameCache2},
                    ChanPid ! {mode, Self, Channel, Modes, User},
                    loop(Pinfo, main, State1);
                {error, _} ->
                    Connpid ! {ircmsg, {err_nochanmodes, host, Self, {default, Channel0}}},
                    loop(Pinfo, main, State0)
            end;
        {mode, Self0, {list, _}, none} ->
            loop(Pinfo, main, State0);
        {mode, Self0, Modes, none} ->
            Op2bool = fun (add) -> true;
                          (remove) -> false
                      end,
            ApplyModes = fun ApplyModes(Um, {_, []}) ->
                                 Um;
                             ApplyModes(Um, {Op, [Mode|Rest]}) ->
                                 ApplyModes(Um#{Mode => Op2bool(Op)}, {Op, Rest})
                         end,
            Usermodes = ApplyModes(Usermodes0, Modes),
            loop(Pinfo, main, State0#{user_modes => Usermodes});
        {topic, Channel0, Msg} ->
            case names:lookup(NameCache0, Channel0) of
                {ok, NameCache1, Channel = {channel, _, ChanPid}} ->
                    ChanPid ! {topic, Self, Channel, Msg},
                    loop(Pinfo, main, State0#{name_cache => NameCache1});
                {error, _} ->
                    Connpid ! {ircmsg, {err_cannotsendtochan, host, Self, {default, Channel0}}},
                    loop(Pinfo, main, State0)
            end;
        {version} ->
            Verstr = veetyircd:version_string(),
            Connpid ! {ircmsg, {rpl_version, host, any, Verstr}},
            loop(Pinfo, main, State0);
        {names, []} ->
            %% i would like to answer with ERR_TOOMANYMATCHES, but it doesn't
            %% seem to be listed in RFC2812. so idk?
            loop(Pinfo, main, State0);
        {names, Chans} ->
            NameCache1 = do_names(Self, NameCache0, Chans),
            State1 = State0#{name_cache => NameCache1},
            loop(Pinfo, main, State1);
        {list, Chans} ->
            %% i would like to do something similar here as with names, but
            %% given there are much fewer channels than users, i think a list
            %% of all the channels is fine. i might make this configurable in
            %% the future, though. LIST could be really hard on the server if
            %% there are many channels, either clogging up name_server or
            %% channel_server depending on your configuration.
            {NameCache1, Chantopics} = do_irc_list(NameCache0, Chans),
            Listmsgs = format_irc_list(Chantopics),
            Connpid ! {ircmultipart, Listmsgs},
            loop(Pinfo, main, State0#{name_cache => NameCache1});
        {kick, Victim0 = {channel, _}, Users0, Msg} ->
            case names:lookup(NameCache0, Victim0) of
                {ok, NameCache1, Victim = {channel, _, ChanPid}} ->
                    {NameCache2, Users} = names:lookup_names(NameCache1, Users0),
                    ChanPid ! {kick, Self, Victim, Users, Msg},
                    loop(Pinfo, main, State0#{name_cache => NameCache2});
                {error, _} ->
                    loop(Pinfo, main, State0)
            end;
        {motd} ->
            loop(Pinfo, motd, State0);
        {time} ->
            Tz = cfg:config(user_timezone, local),
             {{Year, Month, Day}, {Hour, Min, Sec}} = case Tz of
                                                          utc -> calendar:universal_time();
                                                          local -> calendar:local_time()
                                                      end,
            TzStr = string:uppercase(atom_to_list(Tz)),
            TimeStr = io_lib:format("~4..0B-~2..0B-~2..0B ~2..0B:~2..0B:~2..0B ~s",
                                    [Year, Month, Day, Hour, Min, Sec, TzStr]),
            TimeStr0 = list_to_binary(TimeStr),
            Connpid ! {ircmsg, {rpl_time, host, any, {default, TimeStr0}}},
            loop(Pinfo, main, State0);
        {stats, Stats} ->
            Replies = format_stats(Stats),
            Connpid ! {ircmultipart, Replies},
            loop(Pinfo, main, State0);
        {who, Channel = {channel, _}} ->
            State1 = State0#{name_cache => do_who(Self, NameCache0, Channel)},
            loop(Pinfo, main, State1);
        {who, Object} ->
            Connpid ! {ircmsg, {rpl_endofwho, host, any, {default, Object}}},
            loop(Pinfo, main, State0);

        irc_ignore ->
            loop(Pinfo, main, State0);

        %% Administrative messages
        {update_cache_cast, CacheUpdate} ->
            #{name_cache := OldCache} = State0,
            UpdatedCache = names:merge_cache(OldCache, CacheUpdate),
            loop(Pinfo, main, State0#{name_cache => UpdatedCache});
        {getnode, ReqRef, ReqPid} ->
            ReqPid ! {usernode, ReqRef, node()},
            loop(Pinfo, main, State0);
        {getmodes, ReqRef, ReqPid} ->
            ReqPid ! {usermodes, ReqRef, Usermodes0},
            loop(Pinfo, main, State0);
        {gettuple, ReqRef, ReqPid} ->
            ReqPid ! {usertuple, ReqRef, Self},
            loop(Pinfo, main, State0);
        {quit, _} ->
            Quitref = make_ref(),
            Connpid ! {quit, Quitref, self()},
            loop(Pinfo, quit, {Quitref, Connpid});
        {lost_sock, Connpid} ->
            Quitref = make_ref(),
            Connpid ! {lost_sock, Quitref, self()},
            loop(Pinfo, quit, {Quitref, Connpid});
        UnhandledMsg ->
            case cfg:config(user_unhandled_msg, silent) of
                crash ->
                    logger:error("user_worker ~p: unhandled message: ~p, state = ~p",
                                 [self(), UnhandledMsg, State0]),
                    exit(unhandled_message);
                log ->
                    logger:notice("user_worker ~p: unhandled message: ~p, state = ~p",
                                  [self(), UnhandledMsg, State0]);
                {log, Level} ->
                    logger:log(Level, "user_worker ~p: unhandled message: ~p, state = ~p",
                               [self(), UnhandledMsg, State0]);
                silent ->
                    ok
            end,
            loop(Pinfo, main, State0)
    end;

loop(_Pinfo, quit, _State = {Quitref, Connpid}) ->
    receive
        {quit, Quitref, none} ->
            Connpid ! {quit_ok, Quitref},
            exit(shutdown)
    end.

add_channel(Channel = {channel, Name, Pid}, {Chans0, Mons0}) ->
    case maps:is_key(Name, Chans0) of
        false ->
            {ok, ChanSupPid} = channel:supervisor(Pid),
            ChanMon = monitor(process, ChanSupPid),
            Chans = Chans0#{Name => {Channel, ChanMon}},
            Mons = Mons0#{ChanMon => Name},
            {Chans, Mons};
        true ->
            update_channel(Channel, {Chans0, Mons0})
    end.

update_channel_mon(Channel = {channel, Name, _Pid}, ChanSupPid, {Chans0, Mons0}) ->
    #{Name := {_, ChanMon0}} = Chans0,
    demonitor(ChanMon0, [flush]), %% there seems to be a race here
    Mons1 = maps:remove(ChanMon0, Mons0),
    ChanMon = monitor(process, ChanSupPid),
    Chans = Chans0#{Name => {Channel, ChanMon}},
    Mons = Mons1#{ChanMon => Name},
    {Chans, Mons}.

update_channel(Channel = {channel, _Name, Pid}, Channels) ->
    {ok, ChanSupPid} = channel:supervisor(Pid),
    update_channel_mon(Channel, ChanSupPid, Channels).

remove_channel_name(Channel = {channel, Name, _Pid}, {Chans0, Mons0}) ->
    #{Name := {Channel, ChanMon}} = Chans0,
    Chans = maps:remove(Name, Chans0),
    Mons = maps:remove(ChanMon, Mons0),
    demonitor(ChanMon, [flush]),
    {ok, {Chans, Mons}}.

%% there's a race where you get a DOWN from an updated channel, meaning
%% we need to check to see the ref actually exists in the map. If it
%% doesn't ignore it. The old implementation will work, but won't
%% reliably.
remove_channel_ref(ChanMon, {Chans0, Mons0}) ->
    case maps:is_key(ChanMon, Mons0) of
        true ->
            #{ChanMon := Name} = Mons0,
            #{Name := {Channel, ChanMon}} = Chans0,
            Chans = maps:remove(Name, Chans0),
            Mons = maps:remove(ChanMon, Mons0),
            demonitor(ChanMon, [flush]),
            {ok, {Chans, Mons}, Channel};
        false ->
            {error, bad_ref}
    end.

resolve_chan_names(_Parent, _Cache0, [], ResChans, Update) ->
    {Update, ResChans};
resolve_chan_names(Parent, Cache0, [Channel|Rest], ResChans0, Update0) ->
    case names:lookup(Cache0, Channel) of
        {ok, Cache1, ResChan} ->
            ResChans = [ResChan|ResChans0],
            Update = names:add_cache(Update0, ResChan),
            resolve_chan_names(Parent, Cache1, Rest, ResChans, Update);
        {error, _} ->
            Parent ! {chanmissing, Channel},
            resolve_chan_names(Parent, Cache0, Rest, ResChans0, Update0)
    end.

join_chans(_Parent, _User, []) ->
    ok;
join_chans(Parent, User, [Chan = {channel, _, Pid}|Rest]) ->
    case channel:join(Pid, User) of
        {error, user_banned} ->
            Parent ! {chanban, Chan},
            join_chans(Parent, User, Rest);
        _ ->
            join_chans(Parent, User, Rest)
    end.

do_joins_proc(Parent, User, Cache0, Chans0) ->
    {CacheUpdate, ResChans} = resolve_chan_names(Parent, Cache0, Chans0, [], names:new_cache()),
    Parent ! {update_cache_cast, CacheUpdate},
    join_chans(Parent, User, ResChans).

do_joins(User, Cache, Channels) ->
    Self = self(),
    spawn_link(fun() -> do_joins_proc(Self, User, Cache, Channels) end).

part_chans(_, Cache, [], _) ->
    Cache;
part_chans(Thisuser, Cache0, [Channel|Rest], Msg) ->
    case names:lookup(Cache0, Channel) of
        {ok, Cache1, {channel, _, Pid}} ->
            channel:part(Pid, Thisuser, Msg),
            part_chans(Thisuser, Cache1, Rest, Msg);
        {error, _} ->
            part_chans(Thisuser, Cache0, Rest, Msg)
    end.

do_parts_proc(Thisuser, Cache0, Channels, Msg) ->
    part_chans(Thisuser, Cache0, Channels, Msg).

do_parts(Thisuser, Cache, Channels, Msg) ->
    spawn_link(fun() -> do_parts_proc(Thisuser, Cache, Channels, Msg) end).

do_names(_, Cache, []) ->
    Cache;
do_names(Self, Cache0, [Channel|Rest]) ->
    case names:lookup(Cache0, Channel) of
        {ok, Cache1, Chan = {channel, _, Pid}} ->
            Pid ! {names, Self, Chan},
            do_names(Self, Cache1, Rest);
        {error, _} ->
            do_parts(Self, Cache0, Rest, none)
    end.

do_who(Self, Cache0, Channel) ->
    case names:lookup(Cache0, Channel) of
        {ok, Cache1, Chan = {channel, _, Pid}} ->
            Pid ! {who, Self, Chan},
            Cache1;
        {error, _} ->
            Cache0
    end.

get_topic({channel, _, Pid}) ->
    channel:topic(Pid).

get_nusers({channel, _, Pid}) ->
    channel:nusers(Pid).

do_irc_list(Cache, []) ->
    Foldfn = fun(Channel, Acc0) ->
                     Topic = get_topic(Channel),
                     Nusers = get_nusers(Channel),
                     [{Channel, Nusers, Topic}|Acc0]
             end,
    {ok, AllChans} = names:get_all(channel),
    {Cache, lists:foldl(Foldfn, [], AllChans)};
do_irc_list(Cache, Chans) ->
    Foldfn = fun(Chan0, {Cache0, Acc0}) ->
                     case names:lookup(Cache0, Chan0) of
                         {ok, Cache1, Chan} ->
                             Topic = get_topic(Chan),
                             Nusers = get_nusers(Chan),
                             {Cache1, [{Chan, Nusers, Topic}|Acc0]};
                         {error, _} ->
                             {Cache0, Acc0}
                     end
             end,
    lists:foldl(Foldfn, [], {Cache, Chans}).

format_irc_list(Chantopics) ->
    Foldfn = fun({Chan, Nuser, Topic}, Acc0) ->
                     Msg = {rpl_list, host, any, {default, {Chan, Nuser, Topic}}},
                     [Msg|Acc0]
             end,
    Msg0 = {rpl_listend, host, any},
    lists:foldl(Foldfn, [Msg0], Chantopics).

stat_reply(uptime) ->
    Uptime = case cfg:config(user_uptime, cluster) of
                 cluster -> ircctl:cluster_uptime();
                 node -> ircctl:uptime()
             end,
    UptimeString = ircctl:uptime_string(Uptime),
    {rpl_statsuptime, host, any, {default, UptimeString}};
stat_reply(links) ->
    {ok, Nodes} = channel_server:active_nodes(),
    Fmtfn = fun(N) ->
                    {rpl_statslinkinfo, host, any, {default, {N, 0, 0, 0, 0, 0, 0}}}
            end,
    [Fmtfn(Y) || Y <- [atom_to_binary(X) || X <- Nodes]].

format_stats([], Acc) ->
    Acc;
format_stats([Stat|Rest], Acc) ->
    format_stats(Rest, [stat_reply(Stat)|Acc]).
format_stats(Stats) ->
    RawStats = format_stats(Stats, [{rpl_endofstats, host, any, {default, Stats}}]),
    lists:flatten(RawStats).

init(Parent) ->
    Debug = sys:debug_options([]),
    proc_lib:init_ack(Parent, {ok, self()}),
    loop({Parent, Debug}, start, none).

start_link() ->
    proc_lib:start_link(?MODULE, init, [self()]).

getmodes({user, _}) ->
    {error, partial_user};
getmodes({user, _, Pid}) ->
    getmodes(Pid);
getmodes(Pid) when is_pid(Pid) ->
    ReqRef = monitor(process, Pid),
    Pid ! {getmodes, ReqRef, self()},
    receive
        {'DOWN', ReqRef, process, Pid, Reason} ->
            {error, Reason};
        {usermodes, ReqRef, Modes} ->
            demonitor(ReqRef),
            {ok, Modes}
    after
        1000 ->
            {error, timeout}
    end.

getnode({user, _, Pid}) ->
    getnode(Pid);
getnode({userhost, _, Pid}) ->
    getnode(Pid);
getnode(Pid) when is_pid(Pid) ->
    ReqRef = monitor(process, Pid),
    Pid ! {getnode, ReqRef, self()},
    receive
        {'DOWN', ReqRef, process, Pid, Reason} ->
            {error, Reason};
        {usernode, ReqRef, Node} ->
            demonitor(ReqRef),
            {ok, Node}
    after
        1000 ->
            {error, timeout}
    end.

gettuple(Pid) ->
    ReqRef = monitor(process, Pid),
    Pid ! {gettuple, ReqRef, self()},
    receive
        {'DOWN', ReqRef, process, Pid, Reason} ->
            {error, Reason};
        {usertuple, ReqRef, Tuple} ->
            demonitor(ReqRef),
            {ok, Tuple}
    after
        1000 ->
            {error, timeout}
    end.

quit(Pid) ->
    ReqRef = monitor(process, Pid),
    Pid ! {quit, ReqRef},
    receive
        {'DOWN', ReqRef, process, Pid, shutdown} ->
            ok;
        {'DOWN', ReqRef, process, Pid, noproc} ->
            ok;
        {'DOWN', ReqRef, process, Pid, Reason} ->
            {error, Reason}
    end.
