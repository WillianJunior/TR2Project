-module(transport_system).
-export([start_link/0, init/1, broadcast/1, get_random_port_udp_socket/0, 
	unreliable_unicast/2, get_random_port_tcp_listen_socket/0, my_ip/0, 
	multicast_tcp_list/2, accept_tcp/2, connect_tcp/3]).

-define (TRANSPORT_UDP_PORT, 8678).
-define (RED_MSGS, 3).
-define (TIMEOUT, 1000). % in milliseconds
-define (MAX_TRIES, 5).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%% Client API %%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start_link() ->
	{ok, Socket} = gen_udp:open(?TRANSPORT_UDP_PORT, [binary, {active, false}, 
		{broadcast, true}]),
	Pid = spawn_link(?MODULE, init, [Socket]),
	register(?MODULE, Pid).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%% Server Functions %%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init(Socket) -> loop(Socket).

loop(Socket) ->
	Message = gen_udp:recv(Socket, 0),
	case Message of
		{ok, {_Addr, _Port, Packet}} ->
			Payload = binary_to_term(Packet),
			gen_server:cast(discovery_system, Payload);
			%io:format("sent cast~sn", [atom_to_list(Payload)]);
		{error, _Reason} -> ok
			% need to log this later
	end,
	loop(Socket).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%% Transport Helper Functions %%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

get_random_port() -> 
	random:uniform(48127) + 1024.

my_ip() -> 
	{ok, [{addr, IP}]} = inet:ifget("eth0", [addr]),
	IP.


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%% UDP Helper Functions %%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

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

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%% TCP Helper Functions %%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

multicast_tcp_list([], _) -> ok;
multicast_tcp_list([lo|SL], Msg) ->
	multicast_tcp_list(SL, Msg);
multicast_tcp_list([Socket|SL], Msg) ->
	gen_tcp:send(Socket, Msg),
	multicast_tcp_list(SL, Msg).

get_random_port_tcp_listen_socket() ->
	Ans = gen_tcp:listen(get_random_port(), [binary]),
	case Ans of
		{ok, Socket} ->
			Socket;
		_Error ->
			get_random_port_tcp_listen_socket()
	end.	

accept_tcp(_, 0) -> unreach;
accept_tcp(Listener, Try) ->
	R = gen_tcp:accept(Listener, ?TIMEOUT),
	case R of
		{ok, Socket} ->
			Socket;
		_Otherwise ->
			accept_tcp(Listener, Try-1)
	end.

connect_tcp(_, _, 0) -> unreach;
connect_tcp(IP, Port, Try) ->
	R = gen_tcp:connect(IP, Port, [binary], ?TIMEOUT),
	case R of
		{ok, Socket} ->
			Socket;
		_Otherwise ->
			connect_tcp(IP, Port, Try-1)
	end.