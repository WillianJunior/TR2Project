-module(discovery_system).
-behaviour (gen_server).
-export([start_link/0]).
-export([create_file/2, get_file/1, flush_data/0, flush_state/0, new_server/1]).
-export([init/1, code_change/3, terminate/2, handle_cast/2
	, handle_call/3, handle_info/2]).

%%% Client API
start_link() ->
	gen_server:start_link({local, discovery_system}, discovery_system, [], []).

%%% Server Functions
init([]) ->
	{ok, []}.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

% send terminate data to a logger later...
terminate(_Reason, _State) -> ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%% Client Functions Handlers %%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

handle_call(hello_all, _From, State) ->
	transport_system:broadcast(hello)
	{noreply, State};

handle_call({hello, From_IP}, _From, State) ->
	

% currently not needed. send event to a logger later
handle_info(_Request, State) ->
	{noreply, State}.

handle_cast({unreachable_dest, _Dest}, State) ->
	io:format("Server out~n"),
	{noreply, State}.















%%%%% Messages:
%%% Control:
% flush_data
% flush_state
%%% Client File Operation
% new_local_file
% get_file
%%% Servers Coordination
% new_file
% new_file_holder
% file_query
% file_download


%%% Client API
start_link() ->
	{ok, Socket} = gen_udp:open(?DFS_SERVER_UDP_PORT, [binary, {active, false}]),
	Pid = spawn_link(?MODULE, init, [Socket]),
	register(?MODULE, Pid).

%%% Server Functions
init(Arg) -> loop(Arg).
	
loop(Socket) ->
	Message = gen_udp:recv(Socket, 0),
	case Message of
		{ok, {Addr, Port, Packet}} ->
			Payload = binary_to_term(Packet),
			gen_server:cast(dfs_server, {{Addr, Port}, Payload});
			%io:format("sent cast~sn", [atom_to_list(Payload)]);
		{error, _Reason} -> ok
			% need to log this later
	end,
	loop(Socket).