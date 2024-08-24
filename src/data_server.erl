%%% this guy is kind of a catch all server
-module(data_server).
-behaviour(gen_server).
-export([init/1, handle_call/3, handle_cast/2, handle_info/2, code_change/3,
         terminate/2, start_link/0]).
-export([get_motd/0, reload_motd/0, change_motd/1, get_formatted_motd/2]).

load_lines(Filename, IoDevice, Datalist) ->
    case file:read_line(IoDevice) of
        {ok, Data} ->
            load_lines(Filename, IoDevice, [Data|Datalist]);
        eof ->
            {ok, Datalist};
        {error, Reason} ->
            logger:error("data_server: unable to read file ~s: ~p", [Filename, Reason]),
            {error, Reason}
    end.

load_lines(Filename, IoDevice) ->
    {ok, Senil} = load_lines(Filename, IoDevice, []),
    Senil.

%% do note this will return the lines backwards. it's exactly what we want,
%% but just be warned.
load_motd_file(Filename) ->
    {ok, MotdFile} = file:open(Filename, [read, raw, binary, read_ahead, {encoding, utf8}]),
    Senil = load_lines(Filename, MotdFile),
    ok = file:close(MotdFile),
    {ok, Senil}.

format_motd(_From, _To, [], Formatted) ->
    {ircmultipart, Formatted};
format_motd(From, To, [Line|Rest], Formatted) ->
    Msg = {rpl_motd, From, To, {default, Line}},
    format_motd(From, To, Rest, [Msg|Formatted]).

start_link() ->
    gen_server:start_link({local, data_server}, ?MODULE, [], []).

init(_Args) ->
    MotdFile = cfg:config(data_motd_file, none),
    StoreMotd = cfg:config(data_store_motd, false),
    State = #{motd_file => MotdFile, store_motd => StoreMotd, motd => []},
    gen_server:cast(self(), initialize_motd),
    {ok, State}.

handle_cast(initialize_motd, State = #{motd_file := none}) ->
    {noreply, State};
handle_cast(initialize_motd, State = #{store_motd := false}) ->
    {noreply, State};
handle_cast(initialize_motd, State = #{motd_file := MotdFile, store_motd := true}) ->
    {ok, Lines} = load_motd_file(MotdFile),
    logger:notice("data_server: motd file loaded"),
    {noreply, State#{have_motd => true, motd => Lines}};

handle_cast(Msg, State) ->
    case cfg:config(data_unhandled_msg, log) of
        log ->
            logger:notice("data_server cast: unhandled message: ~p", [Msg]);
        {log, Level} ->
            logger:log(Level, "data_server cast: unhandled message: ~p", [Msg]);
        crash ->
            logger:error("data_server cast: unhandled message: ~p", [Msg]),
            exit(unhandled_message);
        silent ->
            ok
    end,
    {noreply, State}.

handle_call(get_motd, _From, State = #{have_motd := true, motd := Motd}) ->
    {reply, {ok, Motd}, State};
handle_call(get_motd, _From, State = #{have_motd := false}) ->
    {reply, {error, no_motd}, State};

handle_call(reload_motd, _From, State = #{have_motd := true, motd_file := MotdFile}) ->
    try load_motd_file(MotdFile) of
        {ok, Lines} ->
            {reply, ok, State#{motd => Lines}}
    catch
        error:Reason ->
            logger:error("data_server: unable to read file ~s: ~p", [MotdFile, Reason]),
            {reply, {error, Reason}, State}
    end;
handle_call(reload_motd, _From, State = #{have_motd := false}) ->
    {reply, {error, no_motd}, State};

handle_call({change_motd, NewFile}, _From, State) ->
    try load_motd_file(NewFile) of
        {ok, Lines} ->
            {reply, ok, State#{have_motd => true, motd_file => NewFile, motd => Lines}}
    catch
    error:Reason ->
            logger:error("data_server: unable to read file ~s: ~p", [NewFile, Reason]),
            {reply, {error, Reason}, State}
    end;

handle_call(Msg, From, State) ->
    case cfg:config(data_unhandled_msg, log) of
        log ->
            logger:notice("data_server call: unhandled message: ~p, from: ~p", [Msg, From]);
        {log, Level} ->
            logger:log(Level, "data_server call: unhandled message: ~p, from: ~p", [Msg, From]);
        crash ->
            logger:error("data_server call: unhandled message: ~p, from: ~p", [Msg, From]),
            exit(unhandled_message);
        silent ->
            ok
    end,
    {noreply, State}.

handle_info(Msg, State) ->
    case cfg:config(data_unhandled_msg, log) of
        log ->
            logger:notice("data_server info: unhandled message: ~p", [Msg]);
        {log, Level} ->
            logger:log(Level, "data_server info: unhandled message: ~p", [Msg]);
        crash ->
            logger:error("data_server info: unhandled message: ~p", [Msg]),
            exit(unhandled_message);
        silent ->
            ok
    end,
    {noreply, State}.

code_change(_, State, _) ->
    {ok, State}.

terminate(_, _) ->
    ok.

get_motd() ->
    gen_server:call(data_server, get_motd).

reload_motd() ->
    gen_server:call(data_server, reload_motd).

change_motd(File) ->
    gen_server:call(data_server, {change_motd, File}).

get_formatted_motd(From, To) ->
    case get_motd() of
        {ok, Dotm} ->
            Motd = format_motd(From, To, Dotm, [{rpl_endofmotd, From, To}]),
            {ok, Motd};
        Err ->
            Err
    end.
