-module(dfs_server).
-behaviour (gen_server).
-export([start_link/1, start_link/2]).
-export([ping_all/0, hail_all/0, create_file/2, flush_data/0, flush_state/0]).
-export([init/1, code_change/3, terminate/2, handle_cast/2
	, handle_call/3, handle_info/2]).
-export([get_server_name/1]).

-define (TIMEOUT_MULTICAST_MS, 10000).

%%%% Files Structures
% Data = {filename, here, {file, consistent, versions}}
% versions = [{location, version}]


%%% Client API
start_link(Server_Name) ->
	net_kernel:start([Server_Name, shortnames]),
	gen_server:start_link({global, Server_Name}, dfs_server, [], []).

start_link(Server_Name, Group) ->
	net_kernel:start([Server_Name, shortnames]),
	net_kernel:connect_node(Group),
	Server_List = lists:map(fun get_server_name/1, nodes()),
	gen_server:start_link({global, Server_Name}, dfs_server, Server_List, []),
	hail_all(). %% hailing but not getting the answers

%% Sync call
create_file(Filename, File) ->
	gen_server:call({global, get_server_name(node())}, {new_local_file, Filename, File}).

flush_data() ->
	gen_server:call({global, get_server_name(node())}, flush_data).

flush_state() ->
	gen_server:call({global, get_server_name(node())}, flush_state).

%% Async call
ping_all() ->
	Nodes = nodes(),
	ping(Nodes).

%%% Server Functions
init([]) ->
	{ok, {[],[]}};

init(Server_List) ->
	{ok, {Server_List, []}}.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

% send terminate data to a logger later...
terminate(_Reason, _State) -> ok.

%% handlers
% New file sync call
handle_call({new_local_file, Filename, File}, _From, {Servers, Data}) ->
	New_Data = {Filename, true, {File, true, [{get_server_name(node()), 1}]}},
	reliable_multicast({new_file, Filename}, Servers),
	{reply, ok, {Servers, lists:keymerge(1, Data, [New_Data])}};

% Get file list
handle_call(flush_data, _From, {Servers, Data}) ->
	{reply, Data, {Servers, Data}};

handle_call(flush_state, _From, State) ->
	{reply, State, State};

handle_call({new_file, Filename}, _From, {Servers, Data}) ->
	New_Data = lists:keymerge(1, Data, [{Filename, false, {}}]),
	{reply, ok, {Servers, New_Data}};

handle_call(_Reason, _From, State) ->
	{noreply, State}.

% currently not needed. send event to a logger later
handle_info(_Request, State) ->
	{noreply, State}.

% Async call
handle_cast({hello, From}, {Servers, Data}) ->
	io:format("hello from ~s~n", [atom_to_list(From)]),
	Exists = lists:member(From, Servers),
	if
		not Exists ->
			New_Servers = lists:merge([From], Servers);
		true ->
			New_Servers = Servers
	end,
	{noreply, {New_Servers, Data}};

handle_cast(ping, State) ->
	io:format("ping~n"),
	{noreply, State}.


%%% Private Functions
hail_all() ->
	Nodes = nodes(),
	hail_group(Nodes).

hail_group([N|Ns]) ->
	Server = get_server_name(N),
	Me = get_server_name(node()),
	io:format("hailing ~s~n", [atom_to_list(Server)]),
	gen_server:cast({global, Server}, {hello, Me}),
	hail_group(Ns);
hail_group([]) -> ok.

ping([N|Ns]) ->
	Me = get_server_name(N),
	io:format("pinging ~s~n", [atom_to_list(Me)]),
	gen_server:cast({global, Me}, ping),
	ping(Ns);
ping([]) -> ok.

get_server_name(Full_Name) ->
	S = string:substr(atom_to_list(Full_Name), 1, string:chr(atom_to_list(Full_Name),  $@)-1),
	list_to_atom(S).

reliable_multicast(Message, [Dest|Group]) ->
	io:format("multicasting to ~s~n", [atom_to_list(Dest)]),
	try gen_server:call({global, Dest}, Message, ?TIMEOUT_MULTICAST_MS) of
		ok ->
			ok
	catch
		_Error ->
			gen_server:cast({global, get_server_name(node())}, {unreachable_dest, Dest})
	end,
	reliable_multicast(Message, Group);

reliable_multicast(_Message, []) -> ok.