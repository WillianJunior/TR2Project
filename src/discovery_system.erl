-module(discovery_system).
-behaviour(gen_server).
-export([start_link/1]).
-export([init/1, code_change/3, terminate/2, handle_info/2, 
	handle_cast/2, handle_call/3]).

-define (RED_MSGS, 3).
-define (TRANSPORT_UDP_PORT, 8678).
-define (TIMEOUT, 1000). % in milliseconds
-define (MAX_TRIES, 20).

%%% Client API
start_link(Arg) ->
	gen_server:start_link({local, discovery_system}, discovery_system, [Arg], []).

%%% Server Functions
init(Arg) ->
	F = lists:nth(1, Arg),
	if
		F /= first ->
			Msg = {hello, transport_system:my_ip()},
			transport_system:broadcast(Msg);
		true -> ok
	end,
	{ok, []}.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

% send terminate data to a logger later...
terminate(_Reason, _State) -> ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%% Client Functions Handlers %%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

handle_info(_I, S) -> {noreply, S}.

handle_call(_R, _F, S) -> {noreply, S}.

handle_cast({hello, IP}, State) ->
	Me = transport_system:my_ip(),
	if
		IP =/= Me ->
			io:format("got hello~n"),
			gen_server:cast(control_system, {new_server_passive, IP});
		true -> ok
	end,
	{noreply, State};

handle_cast({hello_ack, IP, Port}, State) ->
	io:format("got hello_ack~n"),
	gen_server:cast(control_system, {new_server_active, IP, Port}),
	{noreply, State};

handle_cast(_Other, State) ->
	{noreply, State}.