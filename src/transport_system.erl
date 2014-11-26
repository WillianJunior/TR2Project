-module(transport_system).
-export([start_link/0, init/1, broadcast/1, get_random_port_udp_socket/0, 
	unreliable_unicast/2, get_random_port_tcp_listen_socket/0, my_ip/0, 
	multicast_tcp_list/2]).

-define (TRANSPORT_UDP_PORT, 8678).

%%% Client API
start_link() ->
	{ok, Socket} = gen_udp:open(?TRANSPORT_UDP_PORT, [binary, {active, false}, 
		{broadcast, true}]),
	Pid = spawn_link(?MODULE, init, [Socket]),
	register(?MODULE, Pid).

%%% Server Functions
init(Socket) -> loop(Socket).
	
loop(Socket) ->
	Message = gen_udp:recv(Socket, 0),
	case Message of
		{ok, {_Addr, _Port, Packet}} ->
			Payload = binary_to_term(Packet),
			gen_server:cast(discovery_system, Payload),
			gen_server:cast(control_system, Payload);
			%io:format("sent cast~sn", [atom_to_list(Payload)]);
		{error, _Reason} -> ok
			% need to log this later
	end,
	loop(Socket).

multicast_tcp_list([], _) -> ok;
multicast_tcp_list([lo|SL], Msg) ->
	multicast_tcp_list(SL, Msg);
multicast_tcp_list([Socket|SL], Msg) ->
	gen_tcp:send(Socket, term_to_binary(Msg)),
	multicast_tcp_list(SL, Msg).

broadcast(Msg) ->
	Socket = get_random_port_udp_socket(),
	gen_udp:send(Socket, {255,255,255,255}, ?TRANSPORT_UDP_PORT, 
		term_to_binary(Msg)),
	gen_udp:close(Socket).

unreliable_unicast(IP, Msg) ->
	Socket = get_random_port_udp_socket(),
	gen_udp:send(Socket, IP, ?TRANSPORT_UDP_PORT, term_to_binary(Msg)),
	gen_udp:close(Socket).

get_random_port_udp_socket() -> 
	Ans = gen_udp:open(get_random_port(), [binary, {active, false}, 
		{broadcast, true}]),
	case Ans of
		{ok, Socket} ->
			Socket;
		_Error ->
			get_random_port_udp_socket()
	end.

get_random_port_tcp_listen_socket() ->
	Ans = gen_tcp:listen(get_random_port(), []),
	case Ans of
		{ok, Socket} ->
			Socket;
		_Error ->
			get_random_port_tcp_listen_socket()
	end.	

get_random_port() -> 
	random:uniform(48127) + 1024.

my_ip() -> 
	{ok, [{addr, IP}]} = inet:ifget("eth0", [addr]),
	IP.
