-module(web_server).
-export([start_link/1, init/1, answer_http_request/1]).
-compile(export_all).
-define (WEB_SERVER_PORT, 81).
-define (CRLF, "\r\n").

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%% Client API %%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

start_link(Port) ->
	{ok, ListenSocket} = gen_tcp:listen(Port, [{active, false}, binary]),
	Pid = spawn_link(?MODULE, init, [ListenSocket]),
	register(?MODULE, Pid).

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%% Server Main Functions %%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

init(Arg) -> 
	loop(Arg).
	
loop(ListenSocket) ->
	{ok, AcceptSocket} = gen_tcp:accept(ListenSocket),
	io:format("[web_server] received tcp request~n"),
	spawn_link(?MODULE, answer_http_request, [AcceptSocket]),
	loop(ListenSocket).

answer_http_request(Socket) ->
	Resp_List = get_request(Socket),
	io:format("~p~n~n", [Resp_List]),
	Request = re:split(lists:nth(1, Resp_List), " ", [{return,list}, trim]),
	Type = lists:nth(1, Request),
	case Type of
		"GET" ->
			io:format("[web_server] received GET request~n"),
			Download_Token = string:chr(lists:nth(2, Request), $*),
			if
				Download_Token =:= 2 ->
					% download request
					io:format("[web_server] GET request is a download request~n");
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
			% get boundery and filename
			{Boundery, Filename, New_Resp_list} = get_info(Socket, Resp_List),
			
			% get the start of the file from the last msg
			if
				length(New_Resp_list) > 19 ->
					File_Start = lists:sublist(New_Resp_list,20,length(New_Resp_list)-19);
				true ->
					File_Start = []
			end,

			% get file if there is still some parts to receive
			Last_Part = lists:last(New_Resp_list),
			%io:format("Last_Part = ~p~n~n", [Last_Part]),
			End = string:str(Last_Part, Boundery),
			if
				End =:= 0 ->
					io:format("[web_server] downloading the rest of the POST request~n"),
					File = File_Start ++ get_file(Socket, Boundery);
				true ->
					io:format("[web_server] no more parts of the POST request needed~n"),
					File = lists:reverse(tl(lists:reverse(File_Start)))
			end,
			
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

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%%%%%%%%%%%%%%% Helper Functions %%%%%%%%%%%%%%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

get_request(Socket) ->
	{ok, Resp} = gen_tcp:recv(Socket, 0),
	re:split(binary_to_list(Resp),"\r\n",[{return,list}, trim]).

get_info(Socket, Req) ->
	%io:format("~p~n~n", [Req]),
	if
		length(Req) < 19 ->
			%io:format("more~n~n"),
			Next_Part = get_request(Socket),
			get_info(Socket, Req ++ Next_Part);
		true ->
			{get_boundery(Req), get_filename(Req), Req}
	end.

get_boundery(Req) -> 
	Bound_all = re:split(lists:nth(9,Req), ";", [{return,list}, trim]),
	Bound_F = lists:nth(2, Bound_all),
	Eq_Index = string:chr(Bound_F, $=),
	string:substr(Bound_F, Eq_Index+1).

get_filename(Req) ->
	Temp = lists:nth(3, re:split(lists:nth(17,Req), ";", [{return,list}, trim])),
	lists:nth(2, re:split(Temp, "\"", [{return,list},trim])).

get_file(Socket, Boundery) ->
	{ok, Resp} = gen_tcp:recv(Socket, 0),
	Resp_List = re:split(binary_to_list(Resp),"\r\n",[{return,list}, trim]),
	%io:format("post~n~p~n~n", [Resp_List]),
	End = string:str(lists:last(Resp_List), Boundery),
	if
		End =:= 0 ->
			lists:nth(1, Resp_List) ++ get_file(Socket, Boundery);
		true ->
			lists:nth(1, Resp_List)
	end.

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

server_desc_to_html({Count, lo, _}) ->
	IP_Str = "*" ++ ip_to_string(transport_system:my_ip()),
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
	"</td><td> <form method=\"get\" action=\"*1" ++ Filename ++ 
	"\"><button type=\"submit\">Baixar Arquivo</button></form></td></tr>".

locations_to_string([]) -> [];
locations_to_string([{A,B,C,D}|LS]) ->
	IP = ip_to_string({A,B,C,D}) ++ ", ",
	IP ++ locations_to_string(LS);
locations_to_string([here|LS]) ->
	IP = ip_to_string(transport_system:my_ip()) ++ ", ",
	"*" ++ IP ++ ", " ++ locations_to_string(LS).

ip_to_string({A,B,C,D}) ->
	num_to_string(A) ++ "." ++
		num_to_string(B) ++ "." ++
		num_to_string(C) ++ "." ++
		num_to_string(D).

num_to_string(Value) ->
    lists:flatten(io_lib:format("~p", [Value])).