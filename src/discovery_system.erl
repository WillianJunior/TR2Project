-module(discovery_system).
-behaviour (gen_server).
-export([start_link/1]).
%-export([create_file/2, get_file/1, flush_data/0, flush_state/0, new_server/1]).
-export([init/1, code_change/3, terminate/2, handle_info/2, handle_cast/2, handle_call/3]).

-define (RED_MSGS, 3).
-define (TRANSPORT_UDP_PORT, 8678).
-define (TIMEOUT, 1000). % in milliseconds
-define (MAX_TRIES, 5).

%%% Client API
start_link(Arg) ->
	gen_server:start_link({local, discovery_system}, discovery_system, [Arg], []).

%%% Server Functions
init(Arg) ->
	F = lists:nth(1, Arg),
	if
		F /= first ->
			Msg = {hello, my_ip()},
			transport_system:broadcast(Msg);
		true -> ok
	end,
	{ok, []}.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

handle_info(_I, S) -> {noreply, S}.

handle_call(_R, _F, S) -> {noreply, S}.

% send terminate data to a logger later...
terminate(_Reason, _State) -> ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%% Client Functions Handlers %%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

handle_cast({hello, IP}, State) ->
	io:format("got hello~n"),
	Me = my_ip(),
	if
		IP =/= Me ->
			Listener = transport_system:get_random_port_tcp_listen_socket(),
			{ok, Port} = inet:port(Listener),
			transport_system:unreliable_unicast(IP, {hello_ack, my_ip(), Port}),
			Socket = accept_tcp(Listener, ?MAX_TRIES),
			if
				Socket /= unreach->
					io:format("[discovery_system] accepted ~p~n", [IP]);
				true -> ok
			end;
			% need to send Socket up
		true ->
			ok
	end,
	{noreply, State};

handle_cast({hello_ack, IP, Port}, State) ->
	io:format("got hello_ack~n"),
	Socket = connect_tcp(IP, Port, ?MAX_TRIES),
	if
		Socket /= unreach->
			io:format("[discovery_system] new connection to ~p~n", [IP]);
		true -> ok
	end,
	% need to send Socket up
	{noreply, State}.	

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
	{ok, [{addr, IP}]} = inet:ifget("eth1", [addr]),
	IP.