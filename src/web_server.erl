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
	{ok, Resp} = gen_tcp:recv(Socket, 0),
	io:format("~p", [Resp]),
	Resp_List = re:split(binary_to_list(Resp)," ",[{return,list}]),
	Filename = lists:nth(2, Resp_List),
	{Status, Io_Device} = file:open(Filename, read),
	case Status of
		ok ->
			io:format("file found!~n");
		error ->
			io:format("file not found!~n"),
			Status_Line = "HTTP/1.1 404 Not Found" ++ ?CRLF,
			Content_Type_Line = "Content-Type: text/html" ++ ?CRLF ++ ?CRLF,
			Entity_Body = "<HTML><HEAD><TITLE>Not Found</TITLE></HEAD><BODY>Not Found</BODY></HTML>",
			Reply = Status_Line ++ Content_Type_Line ++ Entity_Body,
			io:format("~p", [Reply]),
			gen_tcp:send(Socket, list_to_binary(Reply));
		_ ->
			io:format("error~n")
	end,
	gen_tcp:close(Socket).


format_list(L) -> %when list(L) ->
        io:format("["),
        fnl(L),
        io:format("]").

    fnl([H]) ->
        io:format("~p", [H]);
    fnl([H|T]) ->
        io:format("~p,", [H]),
        fnl(T);
    fnl([]) ->
        ok.