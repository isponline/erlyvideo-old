%%% @author     Max Lapshin <max@maxidoors.ru>
%%% @copyright  2009 Max Lapshin
%%% @doc        ems_media handler template
%%% @reference  See <a href="http://erlyvideo.org/" target="_top">http://erlyvideo.org/</a> for more information
%%% @end
%%%
%%% This file is part of erlyvideo.
%%% 
%%% erlyvideo is free software: you can redistribute it and/or modify
%%% it under the terms of the GNU General Public License as published by
%%% the Free Software Foundation, either version 3 of the License, or
%%% (at your option) any later version.
%%%
%%% erlyvideo is distributed in the hope that it will be useful,
%%% but WITHOUT ANY WARRANTY; without even the implied warranty of
%%% MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
%%% GNU General Public License for more details.
%%%
%%% You should have received a copy of the GNU General Public License
%%% along with erlyvideo.  If not, see <http://www.gnu.org/licenses/>.
%%%
%%%---------------------------------------------------------------------------------------
-module(mpegts_media).
-author('Max Lapshin <max@maxidoors.ru>').
-behaviour(ems_media).
-include_lib("erlmedia/include/video_frame.hrl").
-include("../../include/ems_media.hrl").
-include("../log.hrl").


-define(TIMEOUT_RESTART, 1000).

-export([init/2, handle_frame/2, handle_control/2, handle_info/2]).

-record(mpegts, {
  options,
  make_request,
  timeout
}).


%%%------------------------------------------------------------------------
%%% Callback functions from ems_media
%%%------------------------------------------------------------------------

%%----------------------------------------------------------------------
%% @spec (Media::ems_media(), Options::list()) -> {ok, Media::ems_media()} |
%%                                                {stop, Reason}
%%
%% @doc Called by ems_media to initialize specific data for current media type
%% @end
%%----------------------------------------------------------------------

init(#ems_media{type = Type} = Media, Options) ->
  MakeRequest = case {Type, proplists:get_value(make_request, Options, true)} of
    {mpegts_passive, _} -> false;
    {_, true} -> self() ! make_request, true;
    _ -> false
  end,
  State = #mpegts{options = Options, make_request = MakeRequest, timeout = proplists:get_value(timeout, Options, 4000)},
  Media1 = Media#ems_media{state = State},
  Media2 = case Type of
    mpegts_passive -> Media1#ems_media{clients_timeout = false};
    _ -> Media1
  end,  
  {ok, Media2}.


% connect_http(URL, Timeout) ->
%   try connect_http_raw(URL, Timeout) of
%     {ok, Socket} -> {ok, Socket}
%   catch
%     Class:Error -> {Class, Error}
%   end.
%   
% connect_http_raw(URL, Timeout) ->
%   {_, _, Host, Port, Path, Query} = http_uri:parse(URL),
%   {ok, Socket} = gen_tcp:connect(Host, Port, [binary, {packet, line}, {active, false}], Timeout),
%   ?D({Host, Path, Query, "GET "++Path++" HTTP/1.1\r\nHost: "++Host++":"++integer_to_list(Port)++"\r\nAccept: */*\r\n\r\n"}),
%   ok = gen_tcp:send(Socket, "GET "++Path++" HTTP/1.1\r\nHost: "++Host++":"++integer_to_list(Port)++"\r\nAccept: */*\r\n\r\n"),
%   ok = inet:setopts(Socket, [{active, once}]),
%   {ok, Socket}.

%%----------------------------------------------------------------------
%% @spec (ControlInfo::tuple(), State) -> {ok, State}       |
%%                                        {ok, State, tick} |
%%                                        {error, Reason}
%%
%% @doc Called by ems_media to handle specific events
%% @end
%%----------------------------------------------------------------------
handle_control({subscribe, _Client, _Options}, State) ->
  %% Subscribe returns:
  %% {ok, State} -> client is subscribed as active receiver
  %% {ok, State, tick} -> client requires ticker (file reader)
  %% {error, Reason} -> client receives {error, Reason}
  {noreply, State};

handle_control({source_lost, _Source}, State) ->
  %% Source lost returns:
  %% {ok, State, Source} -> new source is created
  %% {stop, Reason, State} -> stop with Reason
  {stop, source_lost, State};

handle_control({set_source, _Source}, State) ->
  %% Set source returns:
  %% {reply, Reply, State}
  %% {stop, Reason, State}
  {noreply, State};
  
handle_control({set_socket, Socket}, #ems_media{source = Reader, type = Type} = Media) ->
  case Type of
    mpegts_passive -> mpegts_reader:set_socket(Reader, Socket);
    mpegts -> mpegts_reader:set_socket(Reader, Socket);
    _ -> ok
  end,
  {noreply, Media};

handle_control(timeout, State) ->
  ?D({"Timeout in MPEG-TS", State#ems_media.type}),
  {noreply, State};

handle_control(no_clients, #ems_media{type = mpegts_passive, source = undefined, clients_timeout = LifeTimeout} = Media) ->
  ?D("MPEG-TS passive doesn't have clients and socket"),
  {reply, LifeTimeout, Media};

handle_control(no_clients, #ems_media{type = mpegts_passive} = Media) ->
  ?D("MPEG-TS passive doesn't have clients, but have socket"),
  {noreply, Media};

handle_control(no_clients, State) ->
  %% no_clients returns:
  %% {reply, ok, State}      => wait forever till clients returns
  %% {reply, Timeout, State} => wait for Timeout till clients returns
  %% {noreply, State}        => just ignore and live more
  %% {stop, Reason, State}   => stops. This should be default
  {stop, normal, State};

handle_control(_Control, State) ->
  {noreply, State}.

%%----------------------------------------------------------------------
%% @spec (Frame::video_frame(), State) -> {reply, Frame, State} |
%%                                        {noreply, State}   |
%%                                        {stop, Reason, State}
%%
%% @doc Called by ems_media to parse frame.
%% @end
%%----------------------------------------------------------------------
handle_frame(Frame, State) ->
  {reply, Frame, State}.


%%----------------------------------------------------------------------
%% @spec (Message::any(), State) ->  {noreply, State}   |
%%                                   {stop, Reason, State}
%%
%% @doc Called by ems_media to parse incoming message.
%% @end
%%----------------------------------------------------------------------
handle_info(make_request, #ems_media{retry_count = Count, host = Host, type = Type, retry_limit = Limit, state = State, url = URL} = Media) ->
  if
    is_number(Count) andalso is_number(Limit) andalso Count > Limit ->
      {stop, normal, Media};
    State#mpegts.make_request == false ->
      {noreply, Media#ems_media{retry_count = Count + 1}};
    true ->
      ems_event:stream_source_requested(Host, URL, []),
      Module = case Type of
        shoutcast -> ems_shoutcast;
        Else -> Else
      end,
      ?D({"Reconnecting MPEG-TS/Shoutcast socket in mode", Module, Count, URL}),
      case Module:read(URL, []) of
        {ok, Reader} ->
          ems_media:set_source(self(), Reader),
          {noreply, Media#ems_media{retry_count = 0}};
        {error, _Error} ->
          {noreply, Media#ems_media{retry_count = Count + 1}}
      end    
  end;
  

% handle_info({tcp_closed, _Socket}, #ems_media{type = mpegts_passive, state = State} = Media) ->
%   ?D({"MPEG-TS passive lost socket"}),
%   ems_event:stream_source_lost(proplists:get_value(host,Media#ems_media.options), Media#ems_media.name, self()),
%   State1 = State#mpegts{socket = undefined},
%   {noreply, Media#ems_media{state = State1}};
% 
% 
% handle_info({tcp_closed, _Socket}, #ems_media{} = Media) ->
%   ems_event:stream_source_lost(proplists:get_value(host,Media#ems_media.options), Media#ems_media.name, self()),
%   self() ! make_request,
%   {noreply, Media};
handle_info(_Msg, State) ->
  {noreply, State}.

