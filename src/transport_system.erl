-module(transport_system).
-export([start_link/0, init/1, broadcast/1, get_random_port_udp_socket/0, 
	unreliable_unicast/2, get_random_port_tcp_listen_socket/1, my_ip/0, 
	multicast_tcp_list/2, accept_tcp/2, connect_tcp/4]).
-export([system_code_change/4, system_continue/3, 
	system_terminate/4, write_debug/3]).  

-define (TRANSPORT_UDP_PORT, 8678).
-define (RED_MSGS, 3).
-define (TIMEOUT, 2000). % in milliseconds
-define (MAX_TRIES, 5).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%% Client API %%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start_link() ->
	{ok, Socket} = gen_udp:open(?TRANSPORT_UDP_PORT, [binary, {active, false}, 
		{broadcast, true}]),
	%Pid = spawn_link(?MODULE, init, [Socket]),
	%register(?MODULE, Pid).
	proc_lib:start_link(?MODULE, init, [{self(), Socket}]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%% Server Functions %%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init({Parent, Socket}) -> 
	io:format("[transport_system] server started~n"),
	register(?MODULE, self()),  
    Debug = sys:debug_options([]),  
    proc_lib:init_ack(Parent, {ok, self()}),  
    loop(Parent, Debug, Socket).

loop(Parent, Debug, Socket) ->
	receive
		{system, From, Request} ->
			sys:handle_system_msg(Request, From, Parent, 
				?MODULE, Debug, Socket)
	after
		100 ->
			ok
	end,

	Message = gen_udp:recv(Socket, 0, 100),
	case Message of
		{ok, {_Addr, _Port, Packet}} ->
			Payload = binary_to_term(Packet),
			gen_server:cast(discovery_system, Payload);
			%io:format("sent cast~sn", [atom_to_list(Payload)]);
		{error, _Reason} -> ok
			% need to log this later
	end,
	loop(Parent, Debug, Socket).

%% @doc Called by sys:handle_debug().  
write_debug(Dev, Event, Name) ->  
    io:format(Dev, "~p event = ~p~n", [Name, Event]).  
  
%% @doc http://www.erlang.org/doc/man/sys.html#Mod:system_continue-3  
system_continue(Parent, Debug, State) ->  
    io:format("Continue!~n"),  
    loop(Parent, Debug, State).  
  
%% @doc http://www.erlang.org/doc/man/sys.html#Mod:system_terminate-4  
system_terminate(Reason, _Parent, _Debug, _State) ->  
    io:format("Terminate!~n"),  
    exit(Reason).  
  
%% @doc http://www.erlang.org/doc/man/sys.html#Mod:system_code_change-4  
system_code_change(State, _Module, _OldVsn, _Extra) ->  
    io:format("Changed code!~n"),  
    {ok, State}. 

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

get_random_port_tcp_listen_socket(Args) ->
	Ans = gen_tcp:listen(get_random_port(), [binary] ++ Args),
	case Ans of
		{ok, Socket} ->
			Socket;
		_Error ->
			get_random_port_tcp_listen_socket(Args)
	end.	

accept_tcp(_, 0) -> unreach;
accept_tcp(Listener, Try) ->
	R = gen_tcp:accept(Listener, ?TIMEOUT),
	case R of
		{ok, Socket} ->
			Socket;
		_Otherwise ->
			io:format("trying accept ~p more times~n", [Try]),
			accept_tcp(Listener, Try-1)
	end.

connect_tcp(_, _, _, 0) -> unreach;
connect_tcp(IP, Port, Args, Try) ->
	R = gen_tcp:connect(IP, Port, [binary] ++ Args, ?TIMEOUT),
	case R of
		{ok, Socket} ->
			Socket;
		_Otherwise ->
			io:format("trying connect ~p more times~n", [Try]),
			connect_tcp(IP, Port, Args, Try-1)
	end.