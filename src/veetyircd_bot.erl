-module(veetyircd_bot).
-export([init/3, system_continue/3, system_terminate/4, system_code_change/4,
         system_replace_state/2, system_get_state/1]).
-export([main_loop/2]).
%% the api
-export([start_link/2, control_call/2, control_cast/2, terminate/2]).

%% callbacks
%% optional:
%%     chanjoin(User, Channel, State) -> {ok, {reply, To, Data}, State}, {ok, noreply, State}, {error, Reason}
%%     chanpart(User, Channel, State) -> {ok, {reply, To, Data}, State}, {ok, noreply, State}, {error, Reason}
%%     controlmsg(Msg, Self, State) -> {ok, Result, State}, {ok, State}, fallthrough, {error, Reason}
%%     parse_message(Data, From, To, State) -> {ok, skip_message}, {ok, ParsedData}, {error, Reason}
%%     event(EventData, Self, State) -> {ok, {reply, To, Data}, State}, {ok, noreply, State}, {error, Reason}
%%     code_change(OldVsn, State, Extra) -> {ok, NewState}, {error, Reason}
%%     terminate(Reason, State) -> _
%% mandatory:
%%     init(Args) -> {ok|failover, State}, {ok|failover, Nick, State}, {stop, Reason}, {error, Reason}
%%     message(ParsedData, From, To, State) -> {ok, {reply, To, Data}, State}, {ok, noreply, State}, {error, Reason}
%% 
%% note: reply data must be a binary or a list of binaries. A list of binaries will send a message for
%%       for each element of the list.
%%
is_exported(Module, Fun, Arity) ->
    erlang:function_exported(Module, Fun, Arity).

handle_system_msg({system, From, Request}, {Parent, Debug}, State) ->
    sys:handle_system_msg(Request, From, Parent, ?MODULE, Debug, State).

system_continue(Parent, Debug, State = #{code_change := true}) ->
    ?MODULE:main_loop({Parent, Debug}, State#{code_change => false});
system_continue(Parent, Debug, State = #{code_change := false}) ->
    main_loop({Parent, Debug}, State).

system_terminate(Reason, _Parent, _Debug, State) ->
    do_terminate(Reason, State).

system_code_change(State0 = #{callback := Callback, callback_state := CallbackState0}, _Module, OldVsn, Extra) ->
    case is_exported(Callback, code_change, 3) of
        true ->
            case Callback:code_change(OldVsn, CallbackState0, Extra) of
                {ok, CallbackState} ->
                    State = State0#{callback_state => CallbackState, code_change => true},
                    {ok, State};
                {error, Reason} ->
                    do_terminate(Reason, State0)
            end;
        _ ->
            {ok, State0#{code_change => true}}
    end.

system_replace_state(StateFun, State0) ->
    State = StateFun(State0),
    {ok, State0, State}.

system_get_state(State) ->
    {ok, State}.

make_state(Callback, CallbackState, Nick) ->
    Self = self(),
    State = #{ state => run
             , callback => Callback
             , callback_state => CallbackState
             , nick => Nick
             , server_ref => monitor(process, whereis(user_server))
             , code_change => false
             , failover => false
             , monref => none
             , conflicts_proc => spawn_link(fun() -> conflicts_proc(Self, Nick) end)
             },
    ok = pg:join(veetyircd_pg, {bot, Nick}, self()),
    {ok, State}.

filter_running([], Acc) ->
    Acc;
filter_running([H|R], Acc) ->
    case sys:get_state(H) of
        #{failover := true} ->
            filter_running(R, Acc);
        #{failover := false} ->
            filter_running(R, [H|Acc])
    end.

check_conflicts(_, []) ->
    ok;
check_conflicts(Parent, OtherPids) ->
    case filter_running(OtherPids, []) of
        [] ->
            ok;
        RunningPids ->
            Pids = [Parent|RunningPids],
            unlink(Parent),
            [erlang:send(X, conflict) || X <- Pids],
            ok
    end.

conflicts_proc(Parent, Nick) ->
    receive
        check_conflicts ->
            AllBots = pg:get_members(veetyircd_pg, {bot, Nick}),
            OtherBots = lists:delete(Parent, AllBots),
            check_conflicts(Parent, OtherBots),
            conflicts_proc(Parent, Nick)
    end.

init(Parent, Callback, Args) ->
    Debug = sys:debug_options([]),
    code:ensure_loaded(Callback),
    case Callback:init(Args) of
        {ok, CallbackState} ->
            {ok, State} = make_state(Callback, CallbackState, atom_to_binary(Callback)),
            proc_lib:init_ack(Parent, {ok, self()}),
            self() ! do_initialize_bot, % this is a hack, see below
            main_loop({Parent, Debug}, State);
        {failover, CallbackState} ->
            {ok, State} = make_state(Callback, CallbackState, atom_to_binary(Callback)),
            proc_lib:init_ack(Parent, {ok, self()}),
            self() ! do_initialize_bot, % this is a hack, see below
            main_loop({Parent, Debug}, State#{failover => true});
        {ok, Nick, CallbackState} ->
            {ok, State} = make_state(Callback, CallbackState, Nick),
            proc_lib:init_ack(Parent, {ok, self()}),
            self() ! do_initialize_bot, % this is a hack, see below
            main_loop({Parent, Debug}, State);
        {failover, Nick, CallbackState} ->
            {ok, State} = make_state(Callback, CallbackState, Nick),
            proc_lib:init_ack(Parent, {ok, self()}),
            self() ! do_initialize_bot, % this is a hack, see below
            main_loop({Parent, Debug}, State#{failover => true});
        {stop, Reason} ->
            exit(Reason)
    end.

handle_reply(noreply, _) ->
    ok;
handle_reply({reply, To, Data}, #{nick := Nick}) when is_binary(Data) ->
    Self = {user, Nick, self()},
    Msg = message:make(Self, To, Data),
    message:send(Msg),
    ok;
handle_reply({reply, To, Data}, #{nick := Nick}) when is_list(Data) ->
    Self = {user, Nick, self()},
    SendMsg = fun(M, Acc) ->
                      Msg = message:make(Self, To, M),
                      message:send(Msg),
                      Acc
              end,
    lists:foldl(SendMsg, ok, Data),
    ok.

do_terminate(Reason, #{callback := Callback, callback_state := CallbackState}) ->
    case is_exported(Callback, terminate, 2) of
        true -> Callback:terminate(Reason, CallbackState);
        false -> ok
    end,
    exit(Reason).

do_chanjoin({chanjoin, User, Channel}, State0 = #{ callback := Callback
                                                 , callback_state := CallbackState0
                                                 }) ->
    case is_exported(Callback, chanjoin, 3) of
        true ->
            case Callback:chanjoin(User, Channel, CallbackState0) of
                {ok, Reply, CallbackState} ->
                    handle_reply(Reply, State0),
                    State0#{callback_state => CallbackState};
                {error, Reason} ->
                    do_terminate(Reason, State0)
            end;
        false ->
            State0
    end.

do_chanpart({chanpart, User, Channel}, State0 = #{ callback := Callback
                                                 , callback_state := CallbackState0
                                                 }) ->
    case is_exported(Callback, chanjoin, 3) of
        true ->
            case Callback:chanpart(User, Channel, CallbackState0) of
                {ok, Reply, CallbackState} ->
                    handle_reply(Reply, State0),
                    State0#{callback_state => CallbackState};
                {error, Reason} ->
                    do_terminate(Reason, State0)
            end;
        false ->
            State0
    end.

do_parse_message({message, _MsgRef, From, To, Data}, State = #{callback := Callback, nick := Nick}) ->
    Self = {user, Nick, self()},
    case is_exported(Callback, parse_message, 4) of
        true ->
            ParsedTo = parseuser(Self, To),
            case Callback:parse_message(Data, From, ParsedTo, State) of
                {ok, ParsedData} ->
                    ParsedData;
                {error, Reason} ->
                    do_terminate(Reason, State)
            end;
        false ->
            Data
    end.

do_message({message, _MsgRef, _From, _To, skip_message}, State) ->
    State;
do_message({message, _MsgRef, From, To, Data}, State0 = #{ callback := Callback
                                                         , callback_state := CallbackState0
                                                         }) ->
    case Callback:message(Data, From, To, CallbackState0) of
        {ok, Reply, CallbackState} ->
            handle_reply(Reply, State0),
            State0#{callback_state => CallbackState};
        {error, Reason} ->
            do_terminate(Reason, State0)
    end.

do_event(EventData, State0 = #{ callback := Callback
                              , callback_state := CallbackState0}) ->
    case is_exported(Callback, event, 2) of
        true ->
            case Callback:event(EventData, CallbackState0) of
                {ok, Reply, CallbackState} ->
                    handle_reply(Reply, State0),
                    State0#{callback_state => CallbackState};
                {error, Reason} ->
                    do_terminate(Reason, State0)
            end;
        false ->
            State0
    end.

do_controlmsg(Msg, State0 = #{callback := Callback}) ->
    case is_exported(Callback, controlmsg, 3) of
        true ->
            run_controlmsg(Msg, Callback, State0);
        false ->
            run_local_controlmsg(Msg, State0)
    end.

run_controlmsg(Msg, Callback, State0 = #{nick := Nick, callback_state := CallbackState0}) ->
    Self = {user, Nick, self()},
    case Callback:controlmsg(Msg, Self, CallbackState0) of
        {ok, CallbackState} ->
            {ok, State0#{callback_state => CallbackState}};
        {ok, Result, CallbackState} ->
            {Result, State0#{callback_state => CallbackState}};
        fallthrough ->
            run_local_controlmsg(Msg, State0);
        {error, Reason} ->
            do_terminate(Reason, State0)
    end.

run_local_controlmsg(Msg, State0 = #{nick := Nick}) ->
    Self = {user, Nick, self()},
    case controlmsg(Msg, Self, State0) of
        {ok, State} ->
            {ok, State};
        {ok, Result, State} ->
            {Result, State};
        {error, Reason} ->
            do_terminate(Reason, State0)
    end.

controlmsg(crash_me, _Self, _State) ->
    exit(induced_crash);
controlmsg({Type, Chan0 = {channel, _Name}}, Self, State) ->
    case names:lookup(Chan0) of
        {ok, Chan} ->
            controlmsg({Type, Chan}, Self, State);
        {error, Result} ->
            {error, Result}
    end;
controlmsg({join, {channel, _Name, Pid}}, Self, State) ->
    Result = channel:join(Pid, Self),
    {ok, Result, State};
controlmsg({part, {channel, _Name, Pid}}, Self, State) ->
    Result = channel:part(Pid, Self),
    {ok, Result, State};
controlmsg(_, _, State) ->
    {ok, unknown_message, State}.

parseuser(Self, Self) ->
    self;
parseuser(_Self, User) ->
    User.

do_failover_register(State = #{nick := Nick, callback := Callback, monref := MonRef}) ->
    case user_server:register(Nick, self()) of
        ok ->
            case MonRef of
                none ->
                    logger:notice("starting bot ~p with nick ~p", [Callback, Nick]);
                X when is_reference(X) ->
                    logger:notice("bot ~p (~p, ~p): failing over", [Nick, Callback, self()])
            end,
            State#{failover => false};
        {error, user_exists} ->
            case names:lookup({user, Nick}) of
                {ok, {user, Nick, Pid}} ->
                    NewMonRef = monitor(process, Pid),
                    case MonRef of
                        none ->
                            logger:notice("bot ~p (~p, ~p): failing over for ~p", [Nick, Callback, self(), Pid]);
                        X when is_reference(X) ->
                            ok
                    end,
                    State#{monref => NewMonRef};
                {error, no_user} -> %% give it another shot
                    do_failover_register(State)
            end
    end.

main_loop(Pinfo = {Parent, _Debug}, State0 = #{failover := false, nick := Nick,
                                               server_ref := ServerRef, callback := Callback,
                                               conflicts_proc := ConflictsProc}) ->
    Self = {user, Nick, self()},
    receive
        SysMsg = {system, _Request, _From} ->
            handle_system_msg(SysMsg, Pinfo, State0);
        {'EXIT', Parent, Reason} ->
            do_terminate({{parent_death, Parent}, Reason}, State0);
        {'DOWN', ServerRef, process, _Pid, Reason} ->
            do_terminate({user_server_death, Reason}, State0);
        %% Control Messages
        {call, MsgRef, Pid, ControlMsg} ->
            {Result, State} = do_controlmsg(ControlMsg, State0),
            Pid ! {reply, MsgRef, Result},
            main_loop(Pinfo, State);
        {cast, _MsgRef, _Pid, ControlMsg} ->
            {_, State} = do_controlmsg(ControlMsg, State0),
            main_loop(Pinfo, State);
        %% messages from Channels and Users
        {chanjoin, Self, _} ->
            main_loop(Pinfo, State0);
        Msg = {chanjoin, _User, _Channel} ->
            State = do_chanjoin(Msg, State0),
            main_loop(Pinfo, State);
        {chanpart, Self, _} ->
            main_loop(Pinfo, State0);
        Msg = {chanpart, _User, _Channel} ->
            State = do_chanpart(Msg, State0),
            main_loop(Pinfo, State);
        {message, _MsgRef, Self, {channel, _, _}, _Data} ->
            main_loop(Pinfo, State0);
        Msg = {message, MsgRef, From, To, _Data} ->
            ParsedData = do_parse_message(Msg, State0),
            ParsedTo = parseuser(Self, To),
            ParsedMsg = {message, MsgRef, From, ParsedTo, ParsedData},
            State = do_message(ParsedMsg, State0),
            main_loop(Pinfo, State);
        {MsgRef, _} when is_reference(MsgRef) ->
            main_loop(Pinfo, State0);
        %% administrative messages
        do_initialize_bot ->
            %% this is a hack to help with startup
            %% things need time to settle and such before users can be registered.
            %% specifically the problem is user_server. likely a cast should be made,
            %% but i want assurance the nick actually gets made. this is likely an
            %% okay compromise.
            timer:sleep(1000),
            ok = user_server:register(Nick, self()),
            logger:notice("starting bot ~p with nick ~p", [Callback, Nick]),
            main_loop(Pinfo, State0);
        {getnode, ReqRef, ReqPid} ->
            ReqPid ! {usernode, ReqRef, node()},
            main_loop(Pinfo, State0);
        {getmodes, ReqRef, ReqPid} ->
            ReqPid ! {usermodes, ReqRef, #{}},
            main_loop(Pinfo, State0);
        {gettuple, ReqRef, ReqPid} ->
            ReqPid ! {usertuple, ReqRef, Self},
            main_loop(Pinfo, State0);
        conflict ->
            logger:notice("bot ~p (~p, ~p): suicide: conflict", [Nick, Callback, self()]),
            exit(conflict);
        %% other unhandled message (sent to Module:event)
        EventData ->
            State = do_event(EventData, State0),
            main_loop(Pinfo, State)
    after
        1000 ->
            ConflictsProc ! check_conflicts,
            main_loop(Pinfo, State0)
    end;

main_loop(Pinfo = {Parent, _Debug}, State0 = #{failover := true, server_ref := ServerRef,
                                               monref := MonRef}) ->
    receive
        SysMsg = {system, _Request, _From} ->
            handle_system_msg(SysMsg, Pinfo, State0);
        {'EXIT', Parent, Reason} ->
            do_terminate({{parent_death, Parent}, Reason}, State0);
        {'DOWN', ServerRef, process, _Pid, Reason} ->
            do_terminate({user_server_death, Reason}, State0);
        {'DOWN', MonRef, process, _Pid, _Reason} ->
            State = do_failover_register(State0),
            main_loop(Pinfo, State);
        %% Control Messages
        {call, MsgRef, Pid, ControlMsg} ->
            {Result, State} = do_controlmsg(ControlMsg, State0),
            Pid ! {reply, MsgRef, Result},
            main_loop(Pinfo, State);
        {cast, _MsgRef, _Pid, ControlMsg} ->
            {_, State} = do_controlmsg(ControlMsg, State0),
            main_loop(Pinfo, State);
        do_initialize_bot ->
            timer:sleep(1000),
            State = do_failover_register(State0),
            main_loop(Pinfo, State)
    end.

%% api

start_link(Callback, Args) ->
    proc_lib:start_link(?MODULE, init, [self(), Callback, Args]).

control_call(Server, ControlMsg) ->
    MsgRef = monitor(process, Server),
    Server ! {call, MsgRef, self(), ControlMsg},
    receive
        {reply, MsgRef, Result} ->
            demonitor(MsgRef),
            Result;
        {'DOWN', MsgRef, process, _Pid, Reason} ->
            {error, Reason}
    end.

control_cast(Server, ControlMsg) ->
    Server ! {cast, make_ref(), self(), ControlMsg}.

terminate(Server, Reason) ->
    sys:terminate(Server, Reason).
