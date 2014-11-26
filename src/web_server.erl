-module(web_server).
-export([start_link/1, init/1, answer_http_request/1]).

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
	%io:format("~p~n~n", [Resp_List]),
	Request = re:split(lists:nth(1, Resp_List), " ", [{return,list}, trim]),
	Type = lists:nth(1, Request),
	HTML_Filename = "./html/" ++ lists:nth(2, Request),
	case Type of
		"GET" ->
			io:format("[web_server] received GET request~n"),
			File = parse_html(HTML_Filename),
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
			gen_server:cast(control_system, {new_file, Filename}),

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

parse_html(Filename) ->
	{Status, Device} = file:open(Filename, [read]),
	case Status of
		ok ->
			File = try parse_all_lines(Device)
				after file:close(Device)
			end,
			File;
		error ->
			Status
	end.

parse_all_lines(Device) ->
	case io:get_line(Device, "") of
		eof -> [];
		Line -> parse_line(Line) ++ parse_all_lines(Device)
	end.

% TODO finish parse function to swap
%   wildcards for file lines on the table
parse_line(Line) -> Line.