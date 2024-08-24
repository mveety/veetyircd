-module(irc_verify).
-export([msg/2, msg/3, reply/1, reply/2]).

%% poor man's gen_server:call/2
%% verified messages take the form of {verify, Rts, Body}
%% to reply to one do irc_verify:reply(Rts)

msg(Pid, Body) ->
    MsgRef = monitor(process, Pid),
    Msg = {verify, {rts, self(), MsgRef}, Body},
    Pid ! Msg,
    receive
        {verified, MsgRef} ->
            demonitor(MsgRef),
            ok;
        {'DOWN', MsgRef, process, Pid, Reason} ->
            {error, Reason}
    end.

msg(Pid, Body, Timeout) ->
    MsgRef = monitor(process, Pid),
    Msg = {verify, {rts, self(), MsgRef}, Body},
    Pid ! Msg,
    receive
        {verified, MsgRef} ->
            demonitor(MsgRef),
            ok;
        {'DOWN', MsgRef, process, Pid, Reason} ->
            {error, Reason}
    after
        Timeout ->
            {error, timeout}
    end.

reply({verify, Rts, _Body}) ->
    reply(Rts);
reply({rts, Sender, MsgRef}) ->
    reply(Sender, MsgRef).

reply(Sender, MsgRef) ->
    Sender ! {verified, MsgRef},
    ok.
