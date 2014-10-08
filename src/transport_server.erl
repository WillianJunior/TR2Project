-module(transport_server).
-export([start_link/0, init/1]).

-define (DFS_SERVER_UDP_PORT, 8678).


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
		{ok, {_Addr, _Port, Packet}} ->
			Payload = binary_to_term(Packet),
			gen_server:cast(dfs_server, Payload),
			io:format("sent cast~n");
		{error, _Reason} -> ok
			% need to log this later
	end,
	loop(Socket).