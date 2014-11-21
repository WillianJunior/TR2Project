-module(web_server).
-export([start_link/1, init/1, answer_http_request/1]).

-define (WEB_SERVER_PORT, 81).
-define (CRLF, "\r\n").


%%% Client API
start_link(Port) ->
	{ok, ListenSocket} = gen_tcp:listen(Port, [{active, false}, binary]),
	Pid = spawn_link(?MODULE, init, [ListenSocket]),
	register(?MODULE, Pid).

%%% Server Functions
init(Arg) -> 
	loop(Arg).
	
loop(ListenSocket) ->
	{ok, AcceptSocket} = gen_tcp:accept(ListenSocket),
	io:format("received tcp connect~n"),
	spawn_link(?MODULE, answer_http_request, [AcceptSocket]),
	loop(ListenSocket).

answer_http_request(Socket) ->
	Resp_List = get_request(Socket),
	io:format("~p~n~n", [Resp_List]),
	Request = re:split(lists:nth(1, Resp_List), " ", [{return,list}, trim]),
	Type = lists:nth(1, Request),
	HTML_Filename = "./html/" ++ lists:nth(2, Request),
	case Type of
		"GET" ->
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
				end;
		"POST" ->
			io:format("post"),
			%% assuming multipart/form-data always
			% get boundery
			Boundery = get_boundery(Resp_List),
			
			% get second header
			Snd_Header = get_request(Socket),

			% get filename
			Filename = get_filename(Snd_Header),
			
			% get file
			File_Bin = lists:nth(10, Snd_Header) ++ get_file(Socket, Boundery),
			file:write_file(Filename, File_Bin),

			% send response
			Status_Line = "HTTP/1.0 204 No Content" ++ ?CRLF,
			Content_Type_Line = "Content-Type: " ++ ?CRLF ++ ?CRLF,
			Entity_Body = "",
			Reply = Status_Line ++ Content_Type_Line ++ Entity_Body,
			gen_tcp:send(Socket, list_to_binary(Reply))
	end,
	gen_tcp:close(Socket),
	io:format("closed~n").

get_request(Socket) ->
	{ok, Resp} = gen_tcp:recv(Socket, 0),
	re:split(binary_to_list(Resp),"\r\n",[{return,list}, trim]).

get_boundery(Req) -> 
	Bound_all = re:split(lists:nth(9,Req), ";", [{return,list}, trim]),
	Bound_F = lists:nth(2, Bound_all),
	Eq_Index = string:chr(Bound_F, $=),
	string:substr(Bound_F, Eq_Index+1).

get_filename(Req) ->
	re:split(lists:nth(9,Req), ";", [{return,list}, trim]).

get_file(Socket, Boundery) ->
	{ok, Resp} = gen_tcp:recv(Socket, 0),
	Resp_List = re:split(binary_to_list(Resp),"\r\n",[{return,list}, trim]),
	io:format("post~n~p~n~n", [Resp_List]),
	End = string:equal(lists:last(Resp), Boundery),
	if
		End ->
			lists:first(Resp_List);
		true ->
			lists:first(Resp_List) ++ get_file(Socket, Boundery)
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

parse_line(Line) -> Line.