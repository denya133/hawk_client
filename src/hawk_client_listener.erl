%% @author Barulin Maxim <mbarulin@gmail.com>
%% @copyright 2016 Barulin Maxim
%% @version 0.0.3
%% @title hawk_client_listener
%% @doc Модуль, для обработки ranch-запросов и запуска процессов hawk_client_chat_worker.


-module(hawk_client_listener).
-behaviour(gen_server).
-behaviour(ranch_protocol).

-include("env.hrl").
-include("mac.hrl").

-export([start_link/4]).
-export([init/4]).
-export([init/1]).
-export([handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-record(state, {socket, transport, headers}).

%% @doc Запуск модуля
start_link(Ref, Socket, Transport, Opts) ->
	proc_lib:start_link(?MODULE, init, [Ref, Socket, Transport, Opts]).

%% @doc Подключение к модулю, запускаемое из ranch
init(Ref, Socket, Transport, _Opts = []) ->
	ok = proc_lib:init_ack({ok, self()}),
	ok = ranch:accept_ack(Ref),
	ok = Transport:setopts(Socket, [{active, once}]),
	gen_server:enter_loop(?MODULE, [],
		#state{socket=Socket, transport=Transport}).

%% @doc Иинициализация модуля
init([]) -> {ok, undefined}.

%% @doc Оработчик нового подключения
handle_info({?PROTOCOL, Socket, Data}, State=#state{socket=Socket, transport=Transport}) ->
	Transport:setopts(Socket, [{active, once}]),
 	
	{ok, {http_request,Method,{abs_path, _URL},_}, H} = erlang:decode_packet(http, Data, []),
	[Headers, {body, _Body}] = hawk_client_lib:parse_header(H),
	case set_client({Method, Headers}) of
		{ok, false} ->
			hawk_client_chat_worker:handle_req_by_type(get, Data, Socket, Transport),
			hawk_client_lib:send_message(
				true, hawk_client_lib:get_server_message(<<"handshake">>, ?ERROR_DOMAIN_NOT_REGISTER), Socket, Transport
			);
		{ok, Client, Host} ->
			Transport:setopts(Socket, [{active, once}]),
			Transport:controlling_process(Socket, Client),
			gen_fsm:send_event(Client, {socket_ready, Socket, binary_to_list(Host), Transport}),
 			gen_fsm:send_event(Client, {data, Data})
	end,

	{stop, normal, State};

handle_info({?PROTOCOL_CLOSE, _Socket}, State)   -> {stop, normal, State};
handle_info({?PROTOCOL_ERROR, _, Reason}, State) -> {stop, Reason, State};
handle_info(timeout, State)                      -> {stop, normal, State};
handle_info(_Info, State)                        -> {stop, normal, State}.

handle_call(_Request, _From, State) -> {reply, ok, State}.
handle_cast(_Msg, State) -> {noreply, State}.
terminate(_Reason, _State) -> ok.
code_change(_OldVsn, State, _Extra) -> {ok, State}.

%% @doc Возвращает процесс корневого полльзователя-супервизора
get_supervisor_by_name(Name) ->
	case gproc:where({n, l, Name}) of
		undefined -> supervisor:start_child(hawk_client_clients, [Name]);
		Pid -> {ok, Pid}
	end.

%% @doc Возвращает супервизора в зависимости от типа запроса
set_client({'GET', Headers}) ->
	Origin = proplists:get_value(<<"Origin">>, Headers),

	if
		Origin /= undefined ->
			Host = binary:replace(Origin ,[<<"https://">>, <<"http://">>],<<"">>),
			{ok, Login} = gen_server:call(
				{global, hawk_server_api_manager},
				{add_user, hawk_client_app:get_app_env(api_key, undefined)},
				30000
			),

			{ok, Sup} = get_supervisor_by_name(Login),
			{ok, Client} = supervisor:start_child(Sup, [Login]),

			{ok, Client, Host};
		true ->
			{ok, false}
	end;

set_client({'POST', Headers}) ->
	{ok, Sup} = get_supervisor_by_name(<<"post_sup">>),
	{ok, Client} = supervisor:start_child(Sup, [<<"post_sup">>]),
	Host = binary:replace(
		proplists:get_value(<<"Origin">>, Headers) ,[<<"https://">>, <<"http://">>],<<"">>
	),
	{ok, Client, Host}.



