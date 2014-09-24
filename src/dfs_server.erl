-module(dfs_server).
-behaviour (gen_server).
-export([start_link/1, start_link/2]).
-export([ping_all/0]).
-export([init/1, code_change/3, terminate/2, handle_cast/2
	, handle_call/3, handle_info/2]).


%%% Client API
start_link(Server_Name) ->
	net_kernel:start([Server_Name, shortnames]),
	gen_server:start_link({global, Server_Name}, dfs_server, [], []).

start_link(Server_Name, Cluster) ->
	net_kernel:start([Server_Name, shortnames]),
	net_kernel:connect_node(Cluster),
	gen_server:start_link({global, Server_Name}, dfs_server, [], []).

%% Async call

ping_all() ->
	Nodes = nodes(),
	ping(Nodes).

%%% Server Functions
init([]) ->
	{ok, []}.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

% send terminate data to a logger later...
terminate(_Reason, _State) -> ok.

%% handlers
% currently not needed. send event to a logger later
handle_call(_Request, _From, State) ->
	{noreply, State}.

% currently not needed. send event to a logger later
handle_info(_Request, State) ->
	{noreply, State}.

% Async call
handle_cast(ping, State) ->
	io:format("ping~n"),
	{noreply, State}

%%% Private Functions
ping([N|Ns]) ->
	S = string:substr(atom_to_list(N), 1, string:chr(atom_to_list(N),  $@)-1),
	io:format("pinging ~s~n", [S]),
	gen_server:cast({global, list_to_atom(S)}, ping),
	ping(Ns);
ping([]) -> ok.