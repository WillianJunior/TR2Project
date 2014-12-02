-module(web_server).
-export([start_link/1, init/1, answer_http_request/1]).
-export([system_code_change/4, system_continue/3, 
	system_terminate/4, write_debug/3]).

-define (CRLF, "\r\n").

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%% Client API %%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start_link(Port) ->
	{ok, ListenSocket} = gen_tcp:listen(Port, [{active, false}, binary]),
	%Pid = spawn_link(?MODULE, init, [ListenSocket]),
	%register(?MODULE, Pid).
	proc_lib:start_link(?MODULE, init, [{self(), ListenSocket, Port}]). 

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%% Server Main Functions %%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init({Parent, Socket, Port}) -> 
	io:format("[web_server] server started~n"),
	register(?MODULE, self()),
    Debug = sys:debug_options([]),
    proc_lib:init_ack(Parent, {ok, self()}),
    loop(Parent, Debug, {Socket, Port}).
	
loop(Parent, Debug, {ListenSocket, Port}) ->
	receive
		{system, From, Request} ->
			sys:handle_system_msg(Request, From, Parent, 
				?MODULE, Debug, ListenSocket)
	after
		100 ->
			ok
	end,
	Response = gen_tcp:accept(ListenSocket, 100),
	case Response of
		{ok, AcceptSocket} ->
			io:format("[web_server] received tcp request~n"),
			spawn_link(?MODULE, answer_http_request, [{AcceptSocket, Port}]);
		_R ->
			ok
	end,
	loop(Parent, Debug, {ListenSocket, Port}).

answer_http_request({Socket, Port}) ->
	{Raw, Resp_List} = get_request(Socket),
	%io:format("~p~n~n", [Resp_List]),
	Request = re:split(lists:nth(1, Resp_List), " ", [{return,list}, trim]),
	Type = lists:nth(1, Request),
	case Type of
		"GET" ->
			io:format("[web_server] received GET request~n"),
			Download_Token = string:chr(lists:nth(2, Request), $*),
			if
				Download_Token =:= 2 ->
					% download request
					io:format("[web_server] GET request is a download request~n"),
					Filename = string:sub_string(lists:nth(2, Request), Download_Token+1),
					{Files, _Servers} = control_system:get_state(),
				
					% check if it's here
					{_, Locations} = lists:keyfind(Filename, 1, Files),
					Here = lists:member(here, Locations),
					if
						Here ->
							{ok, File} = file:read_file("files/" ++ Filename),
							Status_Line = "HTTP/1.0 200 OK" ++ ?CRLF,
							Content_Type_Line = "Content-Type: application/octet-stream" ++ ?CRLF ++ ?CRLF,
							Reply = Status_Line ++ Content_Type_Line,
							gen_tcp:send(Socket, Reply),
							gen_tcp:send(Socket, File);
						true ->
							IP = lists:nth(random_int(length(Locations)), Locations),
							{ok, Loc_Socket} = gen_tcp:connect(IP, Port, [{active, false}, binary]),
							gen_tcp:send(Loc_Socket, Raw),
							io:format("Raw: ~p~n", [Raw]),
							{ok, New_Resp} = gen_tcp:recv(Loc_Socket, 0),
							io:format("2~n"),
							{ok, File} = gen_tcp:recv(Loc_Socket, 0),
							io:format("3~n"),
							gen_tcp:close(Loc_Socket),
							io:format("4~n"),
							gen_tcp:send(Socket, New_Resp),
							io:format("5~n"),
							gen_tcp:send(Socket, File),
							io:format("6~n")
					end;
				true ->
					% regular get html page
					io:format("[web_server] GET request is a html page request~n"),
					HTML_Filename = "./html" ++ lists:nth(2, Request),
					State = control_system:get_state(),
					File = parse_html(HTML_Filename, State),
					case File of
						error ->
							Status_Line = "HTTP/1.0 404 Not Found" ++ ?CRLF,
							Content_Type_Line = "Content-Type: text/html" ++ ?CRLF ++ ?CRLF,
							Entity_Body = "<HTML><HEAD><TITLE>Not Found</TITLE></HEAD><BODY>Not Found</BODY></HTML>",
							Reply = Status_Line ++ Content_Type_Line ++ Entity_Body,
							gen_tcp:send(Socket, list_to_binary(Reply));
						_ ->
							Status_Line = "HTTP/1.0 200 OK" ++ ?CRLF,
							Content_Type_Line = "Content-Type: text/html" ++ ?CRLF ++ ?CRLF,
							Reply = Status_Line ++ Content_Type_Line,
							gen_tcp:send(Socket, Reply),
							gen_tcp:send(Socket, File)
					end
			end,
			io:format("[web_server] finished GET request~n");
		"POST" ->
			io:format("[web_server] received POST request~n"),
			%% assuming multipart/form-data always
			% get Boundary and filename
			{Boundary, Filename, New_Resp_list, Content_Index} = get_info(Socket, Resp_List),
			% get the start of the file from the last msg
			%io:format("New_Resp_list: ~p~n~n", [New_Resp_list]),
			if
				length(New_Resp_list) > Content_Index+2 ->
					File_Start = lists:nth(Content_Index+3, New_Resp_list);
				true ->
					File_Start = []
			end,
			%io:format("Content_Index: ~p~n~n", [Content_Index]),
			%io:format("File_Start: ~p~n~n", [File_Start]),
			% get file if there is still some parts to receive
			Last_Part = lists:last(New_Resp_list),
			%io:format("Last_Part = ~p~n~n", [Last_Part]),
			End = string:str(Last_Part, Boundary),
			%io:format("End: ~p~n~n", [End]),
			if
				End =:= 0 ->
					io:format("[web_server] downloading the rest of the POST request~n"),
					File = File_Start ++ get_file(Socket, Boundary);
				true ->
					io:format("[web_server] no more parts of the POST request needed~n"),
					File = lists:reverse(tl(lists:reverse(File_Start)))
			end,
			%io:format("File: ~p~n~n", [File]),
			
			% write file to a std dir
			file:write_file("./files/" ++ Filename, list_to_binary(File)),

			% pass add file process to control_system
			control_system:new_file(Filename),

			% send response
			Status_Line = "HTTP/1.0 204 No Content" ++ ?CRLF,
			Content_Type_Line = "Content-Type: " ++ ?CRLF ++ ?CRLF,
			Entity_Body = "",
			Reply = Status_Line ++ Content_Type_Line ++ Entity_Body,
			gen_tcp:send(Socket, list_to_binary(Reply)),
			io:format("[web_server] finished POST request~n")
	end,
	gen_tcp:close(Socket),
	io:format("[web_server] request finished~n").

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
%%%%%%%%%%%%%%% Helper Functions %%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

get_request(Socket) ->
	{ok, Resp} = gen_tcp:recv(Socket, 0),
	{Resp, re:split(binary_to_list(Resp),"\r\n",[{return,list}, trim])}.

get_info(Socket, Req) ->
	if
		length(Req) < 13 ->
			%io:format("more~n~n"),
			{_, Next_Part} = get_request(Socket),
			get_info(Socket, Req ++ Next_Part);
		true ->
			{Boundary, _} = get_field(Req, "boundary="),
			%io:format("boundary: ~p~n", [Boundary]),
			{Filename_Temp, Content_Index} = get_field(Req, "filename="),
			Filename = string:sub_string(Filename_Temp, 2, length(Filename_Temp)-1),
			%io:format("filename: ~p~n", [Filename]),
			{Boundary, Filename, Req, Content_Index}
	end.

get_field(Req, Field) -> 
	Index_List = lists:map(fun (X) -> string:str(X, Field) end, Req),
	Boundary_Index = lists:max(Index_List),
	B_Temp_Index = index_of(Boundary_Index, Index_List),
	Boundary_Temp = lists:nth(B_Temp_Index, Req),
	Boundary = string:sub_string(Boundary_Temp, Boundary_Index + length(Field), length(Boundary_Temp)),
	{Boundary, B_Temp_Index}.

get_file(Socket, Boundary) ->
	{ok, Resp} = gen_tcp:recv(Socket, 0),
	Resp_List = re:split(binary_to_list(Resp),"\r\n",[{return,list}, trim]),
	%io:format("Resp_List: ~p~n~n", [Resp_List]),
	End = string:str(lists:last(Resp_List), Boundary),
	if
		End =:= 0 ->
			lists:nth(1, Resp_List) ++ get_file(Socket, Boundary);
		true ->
			lists:nth(1, Resp_List)
	end.

index_of(Item, List) -> index_of(Item, List, 1).

index_of(_, [], _)  -> not_found;
index_of(Item, [Item|_], Index) -> Index;
index_of(Item, [_|Tl], Index) -> index_of(Item, Tl, Index+1).


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%% Parsing Functions %%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

parse_html(Filename, State) ->
	{Status, Device} = file:open(Filename, [read]),
	case Status of
		ok ->
			File = try parse_all_lines(Device, State)
				after file:close(Device)
			end,
			File;
		error ->
			Status
	end.

parse_all_lines(Device, State) ->
	case io:get_line(Device, "") of
		eof -> [];
		Line -> parse_line(Line, State) ++ parse_all_lines(Device, State)
	end.

% TODO finish parse function to swap
%   wildcards for file lines on the table
parse_line(Line, {Files, Servers}) ->
	Files_Wildcard = string:str(Line, "??"),
	Servers_Wildcard = string:str(Line, "##"),
	if
		Files_Wildcard =/= 0 ->
			loop(fun file_desc_to_html/1, Files);
		Servers_Wildcard =/= 0 ->
			loop(fun server_desc_to_html/1, Servers);
		true ->
			Line
	end.

loop(_, []) -> [];
loop(Fun, [L|LS]) ->
	Fun(L) ++ loop(Fun, LS).

server_desc_to_html({Count, IP, lo}) ->
	IP_Str = "*" ++ ip_to_string(IP),
	Status = "online",
	"<tr><td>" ++ IP_Str ++ "</td><td>" ++ num_to_string(Count) ++ 
		"</td><td>" ++ Status ++ "</td></tr>";
server_desc_to_html({Count, IP, _}) ->
	IP_Str = ip_to_string(IP),
	Status = "online",
	"<tr><td>" ++ IP_Str ++ "</td><td>" ++ num_to_string(Count) ++ 
		"</td><td>" ++ Status ++ "</td></tr>".

file_desc_to_html({Filename, Locations}) ->
	L_Temp = locations_to_string(Locations),
	Locations_String = string:substr(L_Temp, 1, length(L_Temp)-2),
	"<tr><td>" ++ Filename ++ "</td><td>" ++ Locations_String ++ 
	"</td><td> <form method=\"get\" action=\"*" ++ Filename ++ 
	"\"><button type=\"submit\">Baixar Arquivo</button></form></td></tr>".

locations_to_string([]) -> [];
locations_to_string([{A,B,C,D}|LS]) ->
	IP = ip_to_string({A,B,C,D}) ++ ", ",
	IP ++ locations_to_string(LS);
locations_to_string([here|LS]) ->
	IP = ip_to_string(transport_system:my_ip()) ++ ", ",
	"*" ++ IP ++ locations_to_string(LS).

ip_to_string({A,B,C,D}) ->
	num_to_string(A) ++ "." ++
		num_to_string(B) ++ "." ++
		num_to_string(C) ++ "." ++
		num_to_string(D).

num_to_string(Value) ->
    lists:flatten(io_lib:format("~p", [Value])).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%% File Downloading Functions %%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

% random int from 1 to N
random_int(N) -> lists:nth(1, [random:uniform(N) || _ <- lists:seq(1,1)]).
