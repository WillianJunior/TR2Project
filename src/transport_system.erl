-module(transport_system).
-export([start_link/0, init/1, broadcast/1]).

-define (TRANSPORT_UDP_PORT, 8678).

%%% Client API
start_link() ->
	{ok, Socket} = gen_udp:open(?TRANSPORT_UDP_PORT, [binary, {active, false}]),
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

broadcast(Msg) ->
	{ok, Socket} = gen_udp:open(?TRANSPORT_UDP_PORT, [binary, {active, false}]),
	gen_udp:close(Socket).
