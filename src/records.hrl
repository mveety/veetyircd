%% from channel.erl and user_server.erl
-record(user, { name %% user's nick
              , ref  %% user's process monitor reference
              , pid   %% user's process pid
              }).

%% from channel_server.erl
-record(channel, {name, topic, ref, pid, flags}).
-record(permachan, {name, topic, node, aux = none}).
-record(nodeinfo, {name, node, value}).

%% from conn_server.erl
-record(conn, { ref
              , sock
              , pid
              , status
              , type
              , userproc
              }).

%% from *_auth_server.erl
-record(account, { name      %% account username
                 , pass      %% account password
                 , salt      %% salt for the password
                 , hash      %% algorithm used to hash the password
                 , group     %% user's group
                 , enabled   %% is the account enabled
                 , flags     %% global account flags
                 , chanflags %% channel specific flags
                 , aux       %% for any extras in the future
                 }).

%% from exp_name_server.erl
-record(objectinfo, {name, node, pid, ref, aux = none}).

%% from name_server.erl
-record(userinfo, {name, node, pid, ref, aux = none}).
-record(chaninfo, {name, node, pid, ref, aux = none}).

