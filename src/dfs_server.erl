-module(dfs_server).
-behaviour (gen_server).
-export([start_link/1, start_link/2]).
-export([ping_all/0, new_file/2, flush_data/0]).
-export([init/1, code_change/3, terminate/2, handle_cast/2
	, handle_call/3, handle_info/2]).

%%%% Files Structures
% Data = {filename, here, {file, consistent, versions}}
% versions = [{location, version}]


%%% Client API
start_link(Server_Name) ->
	net_kernel:start([Server_Name, shortnames]),
	gen_server:start_link({global, Server_Name}, dfs_server, [], []).

start_link(Server_Name, Cluster) ->
	net_kernel:start([Server_Name, shortnames]),
	net_kernel:connect_node(Cluster),
	gen_server:start_link({global, Server_Name}, dfs_server, [], []).

%% Sync call
new_file(Filename, File) ->
	gen_server:call({global, get_server_name(node())}, {new_file, Filename, File}).

flush_data() ->
	gen_server:call({global, get_server_name(node())}, flush_data).

%% Async call
ping_all() ->
	Nodes = nodes(),
	ping(Nodes).

%%% Server Functions
init([]) ->
	{ok, {[],[]}}.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

% send terminate data to a logger later...
terminate(_Reason, _State) -> ok.

%% handlers
% New file sync call
handle_call({new_file, Filename, File}, _From, {Servers, Data}) ->
	New_Data = {Filename, true, {File, true, [{get_server_name(node()), 1}]}},
	{reply, ok, {Servers, lists:keymerge(1, Data, [New_Data])}};

% Get file list
handle_call(flush_data, _From, {Servers, Data}) ->
	{reply, Data, {Servers, Data}};

handle_call(_Reason, _From, State) ->
	{noreply, State}.

% currently not needed. send event to a logger later
handle_info(_Request, State) ->
	{noreply, State}.

% Async call
handle_cast({ping, Server}, {Servers, Data}) ->
	io:format("ping~n"),
	Exists = lists:member(Server, Servers),
	if
		not Exists ->
			New_Servers = lists:merge([Server], Servers);
		true ->
			New_Servers = Servers
	end,
	{noreply, {New_Servers, Data}}.


%%% Private Functions
ping([N|Ns]) ->
	io:format("pinging ~s~n", [atom_to_list(get_server_name(N))]),
	gen_server:cast({global, get_server_name(N)}, ping),
	ping(Ns);
ping([]) -> ok.

get_server_name(Full_Name) ->
	S = string:substr(atom_to_list(Full_Name), 1, string:chr(atom_to_list(Full_Name),  $@)-1),
	list_to_atom(S).