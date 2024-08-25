-module(user_server).
-behavour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3,
         terminate/2, start_link/0]).
-export([create/0, register/2, unregister/1, lookup/1, get_all/0,
         worker_code_change/0, quit_all/0]).
-include("records.hrl").

lookup_user_ref(Ref, Users) ->
    Pred = fun
               (_K, #user{ref = R}) when R == Ref -> true;
               (_, _) -> false
           end,
    [#user{name = Name, pid = Pid}] = maps:values(maps:filter(Pred, Users)),
    {user, Name, Pid}.

user_exists(Name, Users) ->
    case names:alive() of
        false ->
            maps:is_key(Name, Users);
        true ->
            case names:server_lookup({user, Name}, infinity) of
                {ok, _} -> true;
                {error, _} -> false
            end
    end.

do_users_code_change(Users, Module, OldVsn, Extra) ->
    FoldFn = fun(_, #user{pid = Pid}, Acc0) -> [Pid|Acc0] end,
    CodeChange = fun(Pid) ->
                         sys:suspend(Pid),
                         sys:change_code(Pid, Module, OldVsn, Extra),
                         sys:resume(Pid)
                 end,
    UserPids = maps:fold(FoldFn, [], Users),
    lists:foreach(CodeChange, UserPids).

do_users_quit_all(Users) ->
    FoldFn = fun(_, #user{pid = Pid, ref = Ref}, Acc0) ->
                     demonitor(Ref),
                     user_worker:quit(Pid),
                     Acc0
             end,
    maps:fold(FoldFn, ok, Users),
    #{}.

start_link() ->
    gen_server:start_link({local, user_server}, ?MODULE, [], []).

init(_Args) ->
    Ref = make_ref(),
    logger:notice("user_server: starting",[]),
    gen_server:cast(self(), {initialize, Ref}),
    {ok, Ref}.

handle_cast({initialize, Ref}, Ref) ->
    ParentSibs = supervisor:which_children(veetyircd_sup),
    {_, UsersSup, _, _} = lists:keyfind(users_sup, 1, ParentSibs),
    Siblings = supervisor:which_children(UsersSup),
    {_, UserWorkSup, _, _} = lists:keyfind(user_worker_sup, 1, Siblings),
    State = #{worksup => UserWorkSup,
              users => #{}},
    {noreply, State};

handle_cast({register_user, Name, Pid}, State0 = #{users := Users}) ->
    case user_exists(Name, Users) of
        true ->
            {noreply, State0};
        false ->
            Ref = monitor(process, Pid),
            names:register({user, Name, Pid}),
            UserRec = #user{name = Name, ref = Ref, pid = Pid},
            State = State0#{users => Users#{Name => UserRec}},
            {noreply, State}
    end;

handle_cast(Msg, State) ->
    case cfg:config(user_unhandled_msg, log) of
        log ->
            logger:notice("user_server cast: unhandled message: ~p", [Msg]);
        {log, Level} ->
            logger:log(Level, "user_server cast: unhandled message: ~p", [Msg]);
        crash ->
            logger:error("user_server cast: unhandled message: ~p", [Msg]),
            exit(unhandled_message);
        silent ->
            ok
    end,
    {noreply, State}.

handle_call(create_user, _From, State = #{worksup := Worksup}) ->
    Res = supervisor:start_child(Worksup, []),
    {reply, Res, State};

handle_call({register_user, Name, Pid}, _From, State0 = #{users := Users}) ->
    case user_exists(Name, Users) of
        true ->
            {reply, {error, user_exists}, State0};
        false ->
            Ref = monitor(process, Pid),
            names:register({user, Name, Pid}),
            UserRec = #user{name = Name, ref = Ref, pid = Pid},
            State = State0#{users => Users#{Name => UserRec}},
            {reply, ok, State}
    end;

handle_call({unregister_user, Name}, _From, State0 = #{users := Users}) ->
    case user_exists(Name, Users) of
        true ->
            #{Name := UserRec} = Users,
            names:unregister({user, Name, UserRec#user.pid}),
            demonitor(UserRec#user.pid, [flush]),
            State = State0#{users => maps:remove(Name, Users)},
            {reply, ok, State};
        false ->
            {reply, {error, no_user}, State0}
    end;

handle_call({lookup_user, Name}, _From, State = #{users := Users}) ->
    case maps:is_key(Name, Users) of
        true ->
            #{Name := #user{pid = Pid}} = Users,
            {reply, {ok, {user, Name, Pid}}, State};
        false ->
            {reply, {error, no_user}, State}
    end;

handle_call(stats, _From, State = #{users := Users}) ->
    NUsers = length(maps:keys(Users)),
    {reply, {ok, NUsers}, State};

handle_call(get_all, _From, State = #{users := Users}) ->
    FoldFn = fun(_, #user{name = Name, pid = Pid}, Acc0) ->
                     [{user, Name, Pid}|Acc0]
             end,
    AllUsers = maps:fold(FoldFn, [], Users),
    {reply, {ok, AllUsers}, State};

handle_call(users_code_change, _From, State = #{users := Users}) ->
    {reply, do_users_code_change(Users, user_worker, undefined, undefined), State};

handle_call(quit_all, _From, State = #{users := Users0}) ->
    Users = do_users_quit_all(Users0),
    {reply, ok, State#{users => Users}};

handle_call(Msg, From, State) ->
    case cfg:config(user_unhandled_msg, log) of
        log ->
            logger:notice("user_server call: unhandled message: ~p, from: ~p", [Msg, From]);
        {log, Level} ->
            logger:log(Level, "user_server call: unhandled message: ~p, from: ~p", [Msg, From]);
        crash ->
            logger:error("user_server call: unhandled message: ~p, from: ~p", [Msg, From]),
            exit(unhandled_message);
        silent ->
            ok
    end,
    {noreply, State}.

handle_info({'DOWN', Ref, process, _, _}, State0 = #{users := Users}) ->
    {user, Name, _} = lookup_user_ref(Ref, Users),
    State = State0#{users => maps:remove(Name, Users)},
    {noreply, State};

handle_info(Msg, State) ->
    case cfg:config(user_unhandled_msg, log) of
        log ->
            logger:notice("user_server info: unhandled message: ~p", [Msg]);
        {log, Level} ->
            logger:log(Level, "user_server info: unhandled message: ~p", [Msg]);
        crash ->
            logger:error("user_server info: unhandled message: ~p", [Msg]),
            exit(unhandled_message);
        silent ->
            ok
    end,
    {noreply, State}.

code_change(OldVsn, State = #{users := Users}, Extra) ->
    do_users_code_change(Users, user_worker, OldVsn, Extra),
    {ok, State}.

terminate(_, _) ->
    ok.

create() ->
    gen_server:call(user_server, create_user).

register(Name, Pid) ->
    gen_server:call(user_server, {register_user, Name, Pid}).

unregister(Name) ->
    gen_server:call(user_server, {unregister_user, Name}).

lookup(Name) ->
    gen_server:call(user_server, {lookup_user, Name}).

get_all() ->
    gen_server:call(user_server, get_all).

worker_code_change() ->
    gen_server:call(user_server, users_code_change).

quit_all() ->
    gen_server:call(user_server, quit_all).
