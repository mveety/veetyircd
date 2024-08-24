-module(message).
-export([make/3, make_reply/2, send/1]).

make(From, To, Data) ->
    {message, make_ref(), From, To, Data}.

make_reply({message, _, From, To, _OldData}, NewData) ->
    make(To, From, NewData).

send(Msg = {message, MsgRef, _From, _To = {channel, _Name, Pid}, _Data}) ->
    MonRef = monitor(process, Pid),
    Pid ! Msg,
    receive
        {'DOWN', MonRef, process, Pid, Reason} ->
            {error, Reason};
        {MsgRef, Status} ->
            Status
    after
        5000 -> timeout
    end;
send(Msg = {message, _MsgRef, _From, _To = {_Type, _Name, Pid}, _Data}) ->
    Pid ! Msg,
    ok.
