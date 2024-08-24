-module(veetyircd_bot_sup).
-export([start_link/0, init/1, start_bot/3]).

start_link() ->
    supervisor:start_link({local, ?MODULE}, ?MODULE, []).

init(_Args) ->
    SupFlags = #{strategy => one_for_one,
                 intensity => 10,
                 period => 5},
    Authserv = #{
                 id => bot_authserv,
                 start => {authserv, start_link, []},
                 type => worker
                },
    Opserv = #{
               id => bot_opserv,
               start => {opserv, start_link, []},
               type => worker
              },
    Echobot = #{
                id => echobot,
                start => {echobot, start_link, []},
                type => worker
               },
    ChildSpecs0 = case cfg:check([{bots_authserv, enabled},{auth, enabled}]) of
                      true -> [Authserv];
                      false -> []
                  end,
    ChildSpecs1 = case cfg:check({bots_echobot, enabled}) of
                      true -> [Echobot|ChildSpecs0];
                      false -> ChildSpecs0
                  end,
    ChildSpecs2 = case cfg:check([{bots_opserv, enabled}, {auth, enabled}]) of
                      true -> [Opserv|ChildSpecs1];
                      false -> ChildSpecs1
                  end,
    {ok, {SupFlags, ChildSpecs2}}.

start_bot(Name, Module, Args) ->
    Bot = #{id => Name,
            start => {Module, start_link, Args},
            type => worker},
    supervisor:start_child(veetyircd_bot_sup, Bot).
