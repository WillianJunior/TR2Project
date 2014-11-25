-module(discovery_system).
-behaviour (gen_fsm).
-export([start_link/0]).
%-export([create_file/2, get_file/1, flush_data/0, flush_state/0, new_server/1]).
-export([init/1, code_change/4, terminate/3, handle_event/3, handle_info/3, handle_sync_event/4]).
-export ([active/2]).

-define (RED_MSGS, 3).
-define (TRANSPORT_UDP_PORT, 8678).
-define (TIMEOUT, 1000). % in milliseconds
-define (MAX_TRIES, 5).

%%% Client API
start_link() ->
	gen_server:start_link({local, discovery_system}, discovery_system, [], []).

%%% Server Functions
init([]) ->
	Msg = {hello, my_ip()},
	transport_system:broadcast(Msg),
	{ok, active, []}.

code_change(_OldVsn, S, State, _Extra) ->
	{ok, S, State}.

handle_event(_E, S, SS) -> {next_state, S, SS}.

handle_info(_I, S, SS) -> {next_state, S, SS}.

handle_sync_event(_E, _F, S, SS) -> {next_state, S, SS}.

% send terminate data to a logger later...
terminate(_Reason, _S, _State) -> ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%% Client Functions Handlers %%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

active({hello, IP}, State) ->
	Listener = transport_system:get_random_port_tcp_listen_socket(),
	{ok, Port} = inet:port(Listener),
	transport_system:unreliable_unicast(IP, {hello_ack, my_ip(), Port}),
	Socket = accept_tcp(Listener, ?MAX_TRIES),
	if
		Socket /= unreach->
			io:format("[discovery_system] accepted ~p~n", [IP])
	end,
	% need to send Socket up
	{next_state, active, State};

active({hello_ack, IP, Port}, State) ->
	Socket = connect_tcp(IP, Port, ?MAX_TRIES),
	if
		Socket /= unreach->
			io:format("[discovery_system] new connection to ~p~n", [IP])
	end,
	% need to send Socket up
	{next_state, active, State}.	



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
	R = gen_tcp:connect(IP, Port, [], ?TIMEOUT),
	case R of
		{ok, Socket} ->
			Socket;
		_Otherwise ->
			connect_tcp(IP, Port, Try-1)
	end.

my_ip() -> 
	{ok, [{addr, IP}]} = inet:ifget("wlan0", [addr]),
	IP.