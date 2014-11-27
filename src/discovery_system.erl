-module(discovery_system).
-behaviour(gen_server).
-export([start_link/0]).
-export([init/1, code_change/3, terminate/2, handle_info/2, 
	handle_cast/2, handle_call/3]).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%% Client API %%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start_link() ->
	gen_server:start_link({local, discovery_system}, discovery_system, [], []).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%% Server Main Functions %%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init(_) ->
	io:format("[discovery_system] server started~n"),
	io:format("[discovery_system] broadcasting hello~n"),
	Msg = {hello, transport_system:my_ip()},
	transport_system:broadcast(Msg),
	{ok, []}.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

% send terminate data to a logger later...
terminate(_Reason, _State) -> ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%% Client Functions Handlers %%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

handle_info(I, S) -> 
	io:format("[discovery_system] discarted info: ~p~n", [I]),
	{noreply, S}.

handle_call(R, _F, S) -> 
	io:format("[discovery_system] discarted call: ~p~n", [R]),
	{noreply, S}.

handle_cast({hello, IP}, State) ->
	io:format("[discovery_system] got hello...~n"),
	Me = transport_system:my_ip(),
	if
		IP =/= Me ->
			io:format("[discovery_system] ...from ~p~n", [IP]),
			gen_server:cast(control_system, {new_server_passive, IP});
		true -> 
			io:format("[discovery_system] ...from myself :'(~n"),
			ok
	end,
	{noreply, State};

handle_cast({hello_ack, IP, Port}, State) ->
	io:format("[discovery_system] got hello_ack~n"),
	gen_server:cast(control_system, {new_server_active, IP, Port}),
	{noreply, State};

handle_cast(Other, State) ->
	io:format("[discovery_system] discarted cast: ~p~n", [Other]),
	{noreply, State}.