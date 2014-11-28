-module(control_system).
-behaviour(gen_server).
-export([start_link/0]).
-export([init/1, get_state/0, new_file/1, code_change/3, terminate/2, handle_info/2, 
	handle_cast/2, handle_call/3]).

-define (RED_MSGS, 3).
-define (TRANSPORT_UDP_PORT, 8678).
-define (TIMEOUT, 1000). % in milliseconds
-define (MAX_TRIES, 5).

%%%%%%%%%%%% Data Structures %%%%%%%%%%%%
% Servers = [Server]					%
% Server = {File_Count, IP, Socket}		%
% IP = {A,B,C,D}						%
%										%
% Files = [File]                      	%
% File = {Filename, Locations}        	%
% Locations = [IP]                    	%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%% Client API %%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start_link() ->
	gen_server:start_link({local, control_system}, control_system, [], []).

get_state() ->
	gen_server:call(control_system, flush).

new_file(Filename) ->
	gen_server:cast(control_system, {new_file, Filename}).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%% Server Functions %%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init(_) ->
	io:format("[control_system] server started~n"),
	{ok, {[], [{0, transport_system:my_ip(), lo}]}}.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

handle_info({tcp, _Port, Msg}, S) -> 
	gen_server:cast(control_system, binary_to_term(Msg)),
	{noreply, S};

handle_info(Other, S) ->
	io:format("[control_system] info discarted: ~p~n", [Other]),
	{noreply, S}.

handle_call(flush, _From, State) ->
	{reply, State, State};
handle_call(R, _F, S) -> 
	io:format("[control_system] call discarted: ~p~n", [R]),
	{noreply, S}.

% send terminate data to a logger later...
terminate(_Reason, _State) -> ok.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%% Client Functions Handlers %%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

%%%%%%%%%%% New Server Subprotocol %%%%%%%%%%%%

handle_cast({new_server_passive, IP}, {Files, Servers}) ->
	io:format("[control_system] new_server_passive~n"),
	
	% get a tcp connection to the new server
	Listener = transport_system:get_random_port_tcp_listen_socket([]),
	{ok, Port} = inet:port(Listener),
	transport_system:unreliable_unicast(IP, 
		{hello_ack, transport_system:my_ip(), Port}),
	Socket = transport_system:accept_tcp(Listener, ?MAX_TRIES),
	if
		Socket /= unreach->
			io:format("[control_system] accepted connection  to ~p~n", [IP]);
		true -> ok
	end,

	% balance files between servers
	io:format("[control_system] balancing files~n"),
	{Max_Count, _, _} = lists:nth(1, lists:reverse(Servers)),
	Servers_With_Files = to_server_file_list(lists:reverse(Servers), Files),
	balancer(Servers, Files, Servers_With_Files, {Socket, []}, Max_Count),

	% update servers list
	New_Servers = Servers ++ [{0, IP, Socket}],
	New_Servers_Sorted = lists:sort(New_Servers),
	{noreply, {Files, New_Servers_Sorted}};

handle_cast({new_server_active, IP, Port}, {Files, Servers}) ->
	io:format("[control_system] new_server_active"),
	Socket = transport_system:connect_tcp(IP, Port, [], ?MAX_TRIES),
	if
		Socket /= unreach->
			io:format("[control_system] new connection to ~p~n", [IP]);
		true -> ok
	end,
	New_Servers = Servers ++ [{0, IP, Socket}],
	New_Servers_Sorted = lists:sort(New_Servers),
	{noreply, {Files, New_Servers_Sorted}};

%%%%%%%%%%%% New File Subprotocol %%%%%%%%%%%%%

handle_cast({new_file, Filename}, {Files, Servers}) ->
	io:format("[control_system] new_file~n"),
	% send new descriptors to all servers
	Desc_Msg = term_to_binary({new_descriptor, Filename}),
	Desc_Sockets_Temp = lists:map(fun ({_A,_B,C}) -> C end, Servers),
	Desc_Sockets = lists:delete(lo, Desc_Sockets_Temp),
	lists:map(fun (Socket) -> gen_tcp:send(Socket, Desc_Msg) end, 
		Desc_Sockets),

	% upload files
	Upload_Sockets_Temp = lists:map(fun ({_A,_B,C}) -> C end, Servers),
	Upload_Sockets = [lists:nth(1, Upload_Sockets_Temp), 
		lists:nth(2, Upload_Sockets_Temp)],
	Lo_List = lists:map(fun (Socket) -> upload_file(Socket, Filename) end, 
		Upload_Sockets),
	Got_Lo = lists:foldr(fun (A,B) -> A or B end, false, Lo_List),
	{New_Servers, New_Location} = if
		not Got_Lo ->
			file:delete("./files/" ++ Filename),
			{Servers, []};
		true -> 
			% send update message to network
			Update_Msg = term_to_binary({update_file_ref, Filename, 
			transport_system:my_ip()}),
			Update_Sockets = lists:map(fun ({_A,_B,C}) -> C end, Servers),
			transport_system:multicast_tcp_list(Update_Sockets, Update_Msg),

			% update self counter of files
			{Count, IP, Socket} = lists:keyfind(transport_system:my_ip(), 2, Servers),
			New_S = lists:keyreplace(IP, 2, Servers, {Count+1, IP, Socket}),

			% set updated location
			{New_S, [here]}
	end,

	% add new descriptor locally
	New_Files = Files ++ [{Filename, New_Location}],

	{noreply, {New_Files, lists:sort(New_Servers)}};

handle_cast({new_descriptor, Filename}, {Files, Servers}) ->
	io:format("[control_system] new_descriptor~n"),
	New_Files = Files ++ [{Filename, []}],
	{noreply, {New_Files, Servers}};

%%%%%%%%%%%%% File Related Casts %%%%%%%%%%%%%%

handle_cast({upload_file, Filename, IP, Port}, {Files, Servers}) ->
	io:format("[control_system] upload_file~n"),
	% open a tcp connection for file transfer
	Socket = transport_system:connect_tcp(IP, Port, [{active,false}], ?MAX_TRIES),

	% add self location to the file descriptors' list
	{_, Locations} = lists:keyfind(Filename, 1, Files),
	New_Files = lists:keyreplace(Filename, 1, Files, {Filename, Locations ++ [here]}),

	% update file count
	{Count, My_IP, lo} = lists:keyfind(transport_system:my_ip(), 2, Servers),
	New_Servers = lists:keyreplace(My_IP, 2, Servers, {Count+1, My_IP, lo}),

	% download file
	{ok, File} = gen_tcp:recv(Socket, 0),
	gen_tcp:send(Socket, term_to_binary(ok)),
	file:write_file("./files/" ++ Filename, File),

	% close file transfer socket
	gen_tcp:close(Socket),

	% send update to network
	Update_Msg = term_to_binary({update_file_ref, Filename, 
		transport_system:my_ip()}),
	Update_Sockets = lists:map(fun ({_A,_B,C}) -> C end, Servers),
	transport_system:multicast_tcp_list(Update_Sockets, Update_Msg),
	{noreply, {New_Files, lists:sort(New_Servers)}};

handle_cast({update_file_ref, Filename, IP}, {Files, Servers}) ->
	io:format("[control_system] update_file_ref~n"),
	% add self location to the file descriptors' list
	{Filename, Locations} = lists:keyfind(Filename, 1, Files),
	New_Files = lists:keyreplace(Filename, 1, Files, {Filename, Locations ++ [IP]}),

	% increment file counter
	{Count, IP, Socket} = lists:keyfind(IP, 2, Servers),
	New_Servers = lists:keyreplace(IP, 2, Servers, {Count+1, IP, Socket}),

	{noreply, {New_Files, lists:sort(New_Servers)}};

%%%%%%%% Servers Balancer Subprotocol %%%%%%%%%

handle_cast({remove_file_ref, Filename, IP}, {Files, Servers}) ->
	io:format("[control_system] remove_file_ref~n"),
	
	% remove IP from the file location list
	{Filename, Locations} = lists:keyfind(Filename, 1, Files),
	New_Locations = lists:delete(IP, Locations),
	New_Files = lists:keyreplace(Filename, 1, Files, {Filename, New_Locations}),

	% decrement file counter
	{Count, IP, Socket} = lists:keyfind(IP, 2, Servers),
	New_Servers = lists:keyreplace(IP, 2, Servers, {Count-1, IP, Socket}),

	{noreply, {New_Files, lists:sort(New_Servers)}};


%%%%%%%%%%% Discard other messages %%%%%%%%%%%%

handle_cast(Other, State) ->
	io:format("[control_system] discarting: ~p~n", [Other]),
	{noreply, State}.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%% Balancing Functions %%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

balancer(Servers_State, Files_State, Servers, {Newbee_Socket, Newbee_Files}, Dif) ->
	if
		Dif > 1 ->
			% take first server (ie, server with most files)
			{Count, Server_Name, Files} = lists:nth(1,Servers),
			
			% take its first non-present on Newbee file
			File = take_first_non_repeated(Files, Newbee_Files),
			New_Files = lists:delete(File, Files),
			
			% remove file from server and sort servers list (more files before)
			New_Servers_Temp = lists:keyreplace(Server_Name, 2, Servers, {Count-1, Server_Name, New_Files}),
			New_Servers = lists:reverse(lists:sort(New_Servers_Temp)),
			
			% add file to new server
			New_Newbee_Files = [File|Newbee_Files],

			% calculate current unbalance factor
			{Count2, _, _} = lists:nth(1,New_Servers),
			Diff = Count2 - length(New_Newbee_Files),
			
			% transfer file if it comes from this server
			{New_Servers_State, New_Files_State} = if
				Server_Name =:= here ->
					io:format("[balancer] transfering file: ~p~n", [File]),
					
					% send the actual file and delete locally
					transfer_file(Newbee_Socket, File, Servers_State),

					% remove self reference from the file location list
					{File, Locations} = lists:keyfind(File, 1, Files_State),
					IP = transport_system:my_ip(),
					New_Locations = lists:delete(IP, Locations),
					New_F_State = lists:keyreplace(File, 1, Files_State, {File, New_Locations}),

					% decrement self file counter
					{Count2, IP, Socket} = lists:keyfind(IP, 2, Servers_State),
					New_S_State = lists:keyreplace(IP, 2, Servers_State, {Count2-1, IP, Socket}),

					{New_S_State, New_F_State};
				true ->
					{Servers_State, Files_State}
			end,
			balancer(New_Servers_State, New_Files_State, New_Servers, {Newbee_Socket, New_Newbee_Files}, Diff);
		Dif =< 1 ->
			{Servers_State, Files_State, {{Servers, Newbee_Files}}}
	end.

transfer_file(TCP_Socket, Filename, Servers) ->
	% send file to the new destination
	upload_file(TCP_Socket, Filename),

	% remove file locally
	file:delete("./files/" ++ Filename),

	% notify removal of file
	Update_Msg = term_to_binary({remove_file_ref, Filename, 
		transport_system:my_ip()}),
	Update_Sockets = lists:map(fun ({_A,_B,C}) -> C end, Servers),
	transport_system:multicast_tcp_list(Update_Sockets, Update_Msg).


take_first_non_repeated([], _) -> [];
take_first_non_repeated([F|FS], Files) ->
	Member = lists:member(F, Files),
	if
		Member ->
			take_first_non_repeated(FS, Files);
		true ->
			F
	end.

to_server_file_list([], _) -> [];
to_server_file_list([{_, IP, Socket}|Servers], Files) ->
	S_Name = if
		Socket =:= lo ->
			here;
		true ->
			IP
	end,
	Server_Files = lists:foldr(fun (X,Acc) -> 
		take_if_server(S_Name, X,Acc) end, [], Files),
	[{length(Server_Files), S_Name, Server_Files}|to_server_file_list(Servers, Files)].

take_if_server(IP, {Filename, Locations}, Acc) ->
	Have = lists:member(IP, Locations),
	if
		Have ->
			[Filename|Acc];
		true ->
			Acc
	end.

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%% TCP Helper Functions %%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

upload_file(Socket, Filename) ->
	case Socket of
		lo ->
			true;
		_S ->
			% get a tcp listener for file transfer
			Listener = transport_system:get_random_port_tcp_listen_socket([{active, false}]),
			
			% send call for destination
			{ok, Port} = inet:port(Listener),
			gen_tcp:send(Socket, term_to_binary({upload_file, 
				Filename, transport_system:my_ip(), Port})),
			_Ok = gen_tcp:recv(Socket, 0),

			% wait for file transfer connection
			File_Socket = transport_system:accept_tcp(Listener, ?MAX_TRIES),
			
			% transfer file
			{ok, File} = file:read_file("./files/" ++ Filename),
			gen_tcp:send(File_Socket, File),
			gen_tcp:close(File_Socket),
			false
	end.
