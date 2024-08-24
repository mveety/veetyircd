-module(echobot).
-export([start_link/0, init/1, message/4]).

start_link() ->
    veetyircd_bot:start_link(?MODULE, []).

init(_Args) ->
    {failover, []}.

message(Data, From = {user, Nick, _}, To, State) ->
    ReplyData = <<"I got \"", Data/binary, "\" from user ", Nick/binary>>,
    logger:info("echobot: got message ~p to ~p from ~p", [Data, To, From]),
    logger:info("echobot: sending reply ~p", [ReplyData]),
    {ok, {reply, From, ReplyData}, State};
message(Data, From, To, State) ->
    logger:info("echobot: got message ~p to ~p from ~p", [Data, To, From]),
    {ok, noreply, State}.
