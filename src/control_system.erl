-module(control_system).
-behaviour(gen_server).
-export([start_link/0]).
-export([init/1, code_change/3, terminate/2, handle_info/2, 
	handle_cast/2, handle_call/3]).

%%% Client API
start_link() ->
	gen_server:start_link({local, control_system}, control_system, [], []).

%%% Server Functions
init(_) ->
	{ok, {[], [{0, transport_system:my_ip(), lo}]}}.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

handle_info({tcp, _Port, Msg}, S) -> 
	io:format("received: ~p~n", [Msg]),
	gen_server:cast(control_system, Msg),
	{noreply, S}.

handle_call(flush, _From, State) ->
	{reply, State, State};
handle_call(_R, _F, S) -> {noreply, S}.

% send terminate data to a logger later...
terminate(_Reason, _State) -> ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%% Client Functions Handlers %%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%%%%%%%%% New Server Subprotocol %%%%%%%%%%%%

handle_cast({new_server_passive, IP}, {Files, Servers}) ->
	io:format("[control_system] new_server_passive"),
	Listener = transport_system:get_random_port_tcp_listen_socket(),
	{ok, Port} = inet:port(Listener),
	transport_system:unreliable_unicast(IP, 
		{hello_ack, transport_system:my_ip(), Port}),
	Socket = transport_system:accept_tcp(Listener, ?MAX_TRIES),
	if
		Socket /= unreach->
			io:format("[control_system] accepted connection  to ~p~n", [IP]);
		true -> ok
	end,
	New_Servers = Servers ++ [{0, IP, Socket}],
	New_Servers_Sorted = lists:sort(New_Servers),
	{noreply, {Files, New_Servers_Sorted}};

handle_cast({new_server_active, IP, Port}, {Files, Servers}) ->
	io:format("[control_system] new_server_active"),
	Socket = transport_system:connect_tcp(IP, Port, ?MAX_TRIES),
	if
		Socket /= unreach->
			io:format("[control_system] new connection to ~p~n", [IP]),
			gen_server:cast(control_system, {new_server, Socket, IP});
		true -> ok
	end,
	New_Servers = Servers ++ [{0, IP, Socket}],
	New_Servers_Sorted = lists:sort(New_Servers),
	{noreply, {Files, New_Servers_Sorted}};

%%%%%%%%%%%% New File Subprotocol %%%%%%%%%%%%%

handle_cast({new_file, Filename}, {Files, Servers}) ->
	io:format("[control_system] new_file~n"),
	% send new descriptors to all servers
	Desc_Msg = {new_descriptor, Filename},
	Desc_Sockets_Temp = lists:map(fun ({_A,_B,C}) -> C end, Servers),
	Desc_Sockets = lists:delete(lo, Desc_Sockets_Temp),
	Out = lists:map(fun (Socket) -> gen_tcp:send(Socket, Desc_Msg) end, 
		Desc_Sockets),
	io:format("out: ~p~n~n", [Out]),

	% upload files
	% TODO: support 1 live server
	Upload_Sockets_Temp = lists:map(fun ({_A,_B,C}) -> C end, Servers),
	Upload_Sockets = [lists:nth(1, Upload_Sockets_Temp), 
		lists:nth(2, Upload_Sockets_Temp)],
	Lo_List = lists:map(fun (Socket) -> upload_file(Socket, Filename) end, 
		Upload_Sockets),
	Got_Lo = lists:foldr(fun (A,B) -> A or B end, false, Lo_List),
	if
		not Got_Lo ->
			file:delete("./files/" ++ Filename),
			New_Location = [];
		true -> 
			New_Location = [here]
	end,

	% add new descriptor locally
	New_Files = Files ++ [{Filename, New_Location}],

	{noreply, {New_Files, Servers}};

handle_cast({new_descriptor, Filename}, {Files, Servers}) ->
	io:format("[control_system] new_descriptor~n"),
	New_Files = Files ++ [{Filename, []}],
	{noreply, {New_Files, Servers}};

handle_cast({upload_file, Filename, From}, {Files, Servers}) ->
	io:format("[control_system] upload_file~n"),
	% add self location to the file descriptors' list
	{_, Locations} = lists:keyfind(Filename, 1, Files),
	New_Files = lists:keyreplace(Filename, 1, Files, {Filename, Locations ++ [here]}),

	% update file count
	{Count, My_IP, lo} = lists:keyfind(transport_system:my_ip(), 2, Servers),
	New_Servers = lists:keyreplace(My_IP, 2, Servers, {Count+1, My_IP, lo}),

	% download file
	{_Count, From, Socket} = lists:keyfind(From, 2, Servers),
	File = gen_tcp:recv(Socket, 0),
	file:write_file("./files/" ++ Filename, File),

	% send update to network
	Update_Msg = {update_file_ref, Filename, transport_system:my_ip()},
	Update_Sockets = lists:map(fun ({_A,_B,C}) -> C end, Servers),
	transport_system:multicast_tcp_list(Update_Sockets, Update_Msg),
	{noreply, {New_Servers, New_Files}};

handle_cast({update_file_ref, Filename, IP}, {Files, Servers}) ->
	io:format("[control_system] update_file_ref~n"),
	% add self location to the file descriptors' list
	{_, Locations} = lists:keyfind(Filename, 1, Files),
	New_Files = lists:keyreplace(Filename, 1, Files, {Filename, Locations ++ [IP]}),

	% increment file counter

	{noreply, {New_Files, Servers}};

%%%%%%%%%%% Discard other messages %%%%%%%%%%%%

handle_cast(_Other, State) ->
	io:format("[control_system] discarting~n"),
	{noreply, State}.


upload_file(Socket, Filename) ->
	case Socket of
		lo ->
			true;
		_S ->
			Out = gen_tcp:send(Socket, {upload_file, 
				Filename, transport_system:my_ip()}),
			io:format("out2: ~p~n", [Out]),
			{ok, File} = file:read_file("./files/" ++ Filename),
			gen_tcp:send(Socket, File),
			false
	end.