-module(veetyircd_sup).
-export([start_link/0, init/1]).

start_link() ->
    supervisor:start_link({local, veetyircd_sup}, ?MODULE, []).

init(_Args) ->
    %% This is a complete trainwreck. I need this to be configurable,
    %% but this mess really isn't what I was going for.
    %%
    %% ChildSpecs should end up like this:
    %% [ auth_server, name_server, chans_sup, users_sup, bot_authserv,
    %%   conns_sup, node_server ].
    %% Things are likely to work in a few other orders, though
    SupFlags = #{ strategy => rest_for_one
                , intensity => 5
                , period => 30
                , auto_shutdown => any_significant
                },
    Pg = #{ id => veetyircd_pg
          , start => {pg, start_link, [veetyircd_pg]}
          , type => worker
          },
    DetsAuthServer = #{ id => auth_server
                      , start => {dets_auth_server, start_link, []}
                      , type => worker
                      },
    MnesiaAuthServer = #{ id => auth_server
                        , start => {mnesia_auth_server, start_link, []}
                        , type => worker
                        },
    BotSup = #{ id => veetyircd_bot_sup
              , start => {veetyircd_bot_sup, start_link, []}
              , type => supervisor
              },
    NameServer = #{ id => name_server
                  , start => {name_server, start_link, []}
                  , type => worker
                  , restart => transient
                  , significant => true
                  },
    ExpNameServer = #{ id => name_server
                     , start => {exp_name_server, start_link, []}
                     , type => worker
                       %% This guy crashing is critical, but won't kill the
                       %% server.
                       %% , restart => transient
                       %% , significant => true
                     },
    ConnServer = #{ id => conns_sup
                  , start => {conns_sup, start_link, []}
                  , type => supervisor
                  },
    DataServer = #{ id => data_server
                  , start => {data_server, start_link, []}
                  , type => worker
                  },
    ChannelServer = #{ id => chans_sup
                     , start => {chans_sup, start_link, []}
                     , type => supervisor
                     },
    UserServer = #{ id => users_sup
                  , start => {users_sup, start_link, []}
                  , type => supervisor
                  },

    CoreChildren = case cfg:check({bots, enabled}) of
                       true -> [Pg, DataServer, ChannelServer, UserServer, BotSup];
                       false -> [Pg, DataServer, ChannelServer, UserServer]
                   end,
    ChildSpecs0 = case cfg:check({net, enabled}) of
                      true -> [CoreChildren|[ConnServer]];
                      false -> CoreChildren
                  end,
    ChildSpecs1 = case cfg:check({auth, enabled}) of
                     true ->
                         case cfg:config(auth_server, dets) of
                             dets -> [DetsAuthServer|ChildSpecs0];
                             mnesia -> [MnesiaAuthServer|ChildSpecs0];
                             enabled -> [MnesiaAuthServer|ChildSpecs0];
                             disabled -> ChildSpecs0;
                             _ -> error(bad_auth_server_version)
                         end;
                     false ->
                         ChildSpecs0
                 end,
    ChildSpecs = case cfg:config(name_server, enabled) of
                     enabled -> [NameServer|ChildSpecs1];
                     experimental -> [ExpNameServer|ChildSpecs1];
                     disabled -> ChildSpecs1
                 end,
    {ok, {SupFlags, lists:flatten(ChildSpecs)}}.
