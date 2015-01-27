%%------------------------------------------------------------------------------
%% Copyright (c) 2012-2015, Feng Lee <feng@emqtt.io>
%% 
%% Permission is hereby granted, free of charge, to any person obtaining a copy
%% of this software and associated documentation files (the "Software"), to deal
%% in the Software without restriction, including without limitation the rights
%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%% copies of the Software, and to permit persons to whom the Software is
%% furnished to do so, subject to the following conditions:
%% 
%% The above copyright notice and this permission notice shall be included in all
%% copies or substantial portions of the Software.
%% 
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
%% SOFTWARE.
%%------------------------------------------------------------------------------
%%
%% The Original Code is from eMQTT.
%%

-module(emqttc_packet).

-include("emqttc.hrl").

-include("emqttc_packet.hrl").

-export([initial_state/0]).

-export([parse/2, serialise/1]).

-export([dump/1]).

-define(MAX_LEN, 16#fffffff).
-define(HIGHBIT, 2#10000000).
-define(LOWBITS, 2#01111111).

initial_state() -> none.

parse(<<>>, none) ->
    {more, fun(Bin) -> parse(Bin, none) end};
parse(<<PacketType:4, Dup:1, QoS:2, Retain:1, Rest/binary>>, none) ->
    parse_remaining_len(Rest, #mqtt_packet_header{type   = PacketType,
                                                  dup    = bool(Dup),
                                                  qos    = QoS,
                                                  retain = bool(Retain) });
parse(Bin, Cont) -> Cont(Bin).

parse_remaining_len(<<>>, Header) ->
    {more, fun(Bin) -> parse_remaining_len(Bin, Header) end};
parse_remaining_len(Rest, Header) ->
    parse_remaining_len(Rest, Header, 1, 0).

parse_remaining_len(_Bin, _Header, _Multiplier, Length)
  when Length > ?MAX_LEN ->
    {error, invalid_mqtt_frame_len};
parse_remaining_len(<<>>, Header, Multiplier, Length) ->
    {more, fun(Bin) -> parse_remaining_len(Bin, Header, Multiplier, Length) end};
parse_remaining_len(<<1:1, Len:7, Rest/binary>>, Header, Multiplier, Value) ->
    parse_remaining_len(Rest, Header, Multiplier * ?HIGHBIT, Value + Len * Multiplier);
parse_remaining_len(<<0:1, Len:7, Rest/binary>>, Header,  Multiplier, Value) ->
    parse_frame(Rest, Header, Value + Len * Multiplier).

parse_frame(Bin, #mqtt_packet_header{ type = Type,
                                      qos  = Qos } = Header, Length) ->
    case {Type, Bin} of
        {?CONNACK, <<FrameBin:Length/binary, Rest/binary>>} ->
            <<_Reserved:7, SP:1, ReturnCode:8>> = FrameBin,
            wrap(Header, #mqtt_packet_connack{
                    ack_flags = SP,
                    return_code = ReturnCode }, Rest);
        {?PUBLISH, <<FrameBin:Length/binary, Rest/binary>>} ->
            {TopicName, Rest1} = parse_utf(FrameBin),
            {PacketId, Payload} = case Qos of
                                       0 -> {undefined, Rest1};
                                       _ -> <<Id:16/big, R/binary>> = Rest1,
                                            {Id, R}
                                   end,
            wrap(Header, #mqtt_packet_publish {topic_name = TopicName,
                                              packet_id = PacketId },
                 Payload, Rest);
        {?PUBACK, <<FrameBin:Length/binary, Rest/binary>>} ->
            <<PacketId:16/big>> = FrameBin,
            wrap(Header, #mqtt_packet_puback{packet_id = PacketId}, Rest);
        {?PUBREC, <<FrameBin:Length/binary, Rest/binary>>} ->
            <<PacketId:16/big>> = FrameBin,
            wrap(Header, #mqtt_packet_puback{packet_id = PacketId}, Rest);
        {?PUBREL, <<FrameBin:Length/binary, Rest/binary>>} ->
            1 = Qos,
            <<PacketId:16/big>> = FrameBin,
            wrap(Header, #mqtt_packet_puback{ packet_id = PacketId }, Rest);
        {?PUBCOMP, <<FrameBin:Length/binary, Rest/binary>>} ->
            <<PacketId:16/big>> = FrameBin,
            wrap(Header, #mqtt_packet_puback{ packet_id = PacketId }, Rest);
        {?SUBACK, <<FrameBin:Length/binary, Rest/binary>>} ->
            <<PacketId:16/big, Rest1/binary>> = FrameBin,
            wrap(Header, #mqtt_packet_suback { packet_id = PacketId, 
                                               qos_table = parse_qos(Rest1, []) }, Rest);
        {?UNSUBACK, <<FrameBin:Length/binary, Rest/binary>>} ->
            <<PacketId:16/big>> = FrameBin,
            wrap(Header, #mqtt_packet_suback { packet_id = PacketId }, Rest);
        {?PINGRESP, Rest} ->
            Length = 0,
            wrap(Header, Rest);
        {_, TooShortBin} ->
            {more, fun(BinMore) ->
                           parse_frame(<<TooShortBin/binary, BinMore/binary>>,
                                       Header, Length)
                   end}
     end.

wrap(Header, Variable, Payload, Rest) ->
    {ok, #mqtt_packet{ header = Header, variable = Variable, payload = Payload }, Rest}.
wrap(Header, Variable, Rest) ->
    {ok, #mqtt_packet { header = Header, variable = Variable }, Rest}.
wrap(Header, Rest) ->
    {ok, #mqtt_packet { header = Header }, Rest}.

parse_qos(<<>>, Acc) ->
    lists:reverse(Acc);
parse_qos(<<QoS:8, Rest/binary>>, Acc) ->
    parse_qos(Rest, [QoS | Acc]).

parse_utf(Bin, 0) ->
    {undefined, Bin};
parse_utf(Bin, _) ->
    parse_utf(Bin).

parse_utf(<<Len:16/big, Str:Len/binary, Rest/binary>>) ->
    {Str, Rest}.

parse_msg(Bin, 0) ->
    {undefined, Bin};
parse_msg(<<Len:16/big, Msg:Len/binary, Rest/binary>>, _) ->
    {Msg, Rest}.

bool(0) -> false;
bool(1) -> true.

%% serialisation

serialise(#mqtt_packet{ header = Header,
                        variable = Variable,
                        payload  = Payload }) ->
    serialise_header(Header, 
                     serialise_variable(Header, Variable, 
                                        serialise_payload(Payload))).

serialise_payload(undefined)           -> <<>>;
serialise_payload(B) when is_binary(B) -> B.

serialise_variable(#mqtt_packet_header  { type = ?CONNECT },
                   #mqtt_packet_connect { client_id   =  ClientId,
                                          proto_ver   =  ProtoVer,
                                          proto_name  =  ProtoName,
                                          will_retain =  WillRetain,
                                          will_qos    =  WillQos,
                                          will_flag   =  WillFlag,
                                          clean_sess  =  CleanSess,
                                          keep_alive  =  KeepAlive,
                                          will_topic  =  WillTopic,
                                          will_msg    =  WillMsg,
                                          username    =  Username,
                                          password    =  Password },
                   <<>>) ->
    VariableBin = <<(size(ProtoName)):16/big-unsigned-integer,
                     ProtoName/binary,
                     ProtoVer:8,
                     (opt(Username)):1,
                     (opt(Password)):1,
                     (opt(WillRetain)):1,
                     WillQos:2,
                     (opt(WillFlag)):1,
                     (opt(CleanSess)):1,
                     0:1,
                     KeepAlive:16/big-unsigned-integer>>,
     PayloadBin = serialise_utf(ClientId),
     PayloadBin1 = case WillFlag of
         true -> <<PayloadBin/binary,
                   (serialise_utf(WillTopic))/binary,
                   (size(WillMsg)):16/big-unsigned-integer,
                   WillMsg/binary>>;
         false -> PayloadBin
     end,
     PayloadBin2 = <<PayloadBin1/binary,
                   (serialise_utf(Username))/binary,
                   (serialise_utf(Password))/binary>>,
    {VariableBin, PayloadBin2};

serialise_variable(#mqtt_packet_header { type      = Subs},
                   #mqtt_packet_subscribe { packet_id   = PacketId, 
                                            topic_table = Topics },
                   <<>>)
    when Subs =:= ?SUBSCRIBE orelse Subs =:= ?UNSUBSCRIBE ->
    {<<PacketId:16/big>>, serialise_topics(Subs, Topics)};

serialise_variable(#mqtt_packet_header { type       = ?PUBLISH,
                                         qos        = Qos },
                   #mqtt_packet_publish { topic_name = TopicName,
                                          packet_id  = PacketId },
                   PayloadBin) ->
    TopicBin = serialise_utf(TopicName),
    PacketIdBin = case Qos of
                       0 -> <<>>;
                       1 -> <<PacketId:16/big>>;
                       2 -> <<PacketId:16/big>>
                   end,
    {<<TopicBin/binary, PacketIdBin/binary>>, PayloadBin};

serialise_variable(#mqtt_packet_header { type      = PubAck },
                   #mqtt_packet_puback { packet_id = PacketId },
                   <<>> = _Payload) 
  when PubAck =:= ?PUBACK; PubAck =:= ?PUBREC; 
       PubAck =:= ?PUBREL; PubAck =:= ?PUBCOMP ->
    {<<PacketId:16/big>>, <<>>};

serialise_variable(#mqtt_packet_header { },
                   undefined,
                   <<>> = _PayloadBin) ->
    {<<>>, <<>>}.

serialise_header(#mqtt_packet_header{ type   = Type,
                                     dup    = Dup,
                                     qos    = Qos,
                                     retain = Retain }, 
                {VariableBin, PayloadBin})
  when is_integer(Type) andalso ?CONNECT =< Type andalso Type =< ?DISCONNECT ->
    Len = size(VariableBin) + size(PayloadBin),
    true = (Len =< ?MAX_LEN),
    LenBin = serialise_len(Len),
    <<Type:4, (opt(Dup)):1, (opt(Qos)):2, (opt(Retain)):1,
      LenBin/binary, VariableBin/binary, PayloadBin/binary>>.

serialise_topics(?SUBSCRIBE, Topics) ->
    << <<(serialise_utf(Name))/binary, ?RESERVED:6, Qos:2>> || #mqtt_topic{name = Name, qos = Qos} <- Topics >>;

serialise_topics(?UNSUBSCRIBE, Topics) ->
    << <<(serialise_utf(Name))/binary>> || #mqtt_topic{name = Name, qos = undefined} <- Topics >>.

serialise_utf(String) ->
    StringBin = unicode:characters_to_binary(String),
    Len = size(StringBin),
    true = (Len =< 16#ffff),
    <<Len:16/big, StringBin/binary>>.

serialise_len(N) when N =< ?LOWBITS ->
    <<0:1, N:7>>;
serialise_len(N) ->
    <<1:1, (N rem ?HIGHBIT):7, (serialise_len(N div ?HIGHBIT))/binary>>.

opt(undefined)            -> ?RESERVED;
opt(false)                -> 0;
opt(true)                 -> 1;
opt(X) when is_integer(X) -> X;
opt(B) when is_binary(B)  -> 1.

protocol_name_approved(Ver, Name) ->
    lists:member({Ver, Name}, ?PROTOCOL_NAMES).

dump(#mqtt_packet{header = Header, variable = Variable, payload = Payload}) when
     Payload =:= undefined orelse Payload =:= <<>>  ->
    dump_header(Header, dump_variable(Variable));

dump(#mqtt_packet{header = Header, variable = Variable, payload = Payload}) ->
    dump_header(Header, dump_variable(Variable, Payload)).

dump_header(#mqtt_packet_header{type = Type, dup = Dup, qos = QoS, retain = Retain}, S) ->
    S1 = 
    if 
        S == undefined -> <<>>;
        true -> [", ", S]
    end,
    io_lib:format("~s(Qos=~p, Retain=~s, Dup=~s~s)", [dump_type(Type), QoS, Retain, Dup, S1]).

dump_variable( #mqtt_packet_connect { 
                  proto_ver     = ProtoVer, 
                  proto_name    = ProtoName,
                  will_retain   = WillRetain, 
                  will_qos      = WillQoS, 
                  will_flag     = WillFlag, 
                  clean_sess    = CleanSess, 
                  keep_alive    = KeepAlive, 
                  client_id     = ClientId, 
                  will_topic    = WillTopic, 
                  will_msg      = WillMsg, 
                  username      = Username, 
                  password      = Password} ) ->
    Format =  "ClientId=~s, ProtoName=~s, ProtoVsn=~p, CleanSess=~s, KeepAlive=~p, Username=~s, Password=~s",
    Args = [ClientId, ProtoName, ProtoVer, CleanSess, KeepAlive, Username, dump_password(Password)],
    {Format1, Args1} = if 
                        WillFlag -> { Format ++ ", Will(Qos=~p, Retain=~s, Topic=~s, Msg=~s)",
                                      Args ++ [ WillQoS, WillRetain, WillTopic, WillMsg ] };
                        true -> {Format, Args}
                       end,
    io_lib:format(Format1, Args1);

dump_variable( #mqtt_packet_connack { 
                  ack_flags = AckFlags, 
                  return_code = ReturnCode } ) ->
    io_lib:format("AckFlags=~p, RetainCode=~p", [AckFlags, ReturnCode]);

dump_variable( #mqtt_packet_publish {
                 topic_name = TopicName,
                 packet_id  = PacketId} ) ->
    io_lib:format("TopicName=~s, PacketId=~p", [TopicName, PacketId]);

dump_variable( #mqtt_packet_puback { 
                  packet_id = PacketId } ) ->
    io_lib:format("PacketId=~p", [PacketId]);

dump_variable( #mqtt_packet_subscribe {
                  packet_id = PacketId, 
                  topic_table = TopicTable }) ->
    L =  [{Name, QoS} || #mqtt_topic{name = Name, qos = QoS} <- TopicTable],
    io_lib:format("PacketId=~p, TopicTable=~p", [PacketId, L]);

dump_variable( #mqtt_packet_suback {
                 packet_id = PacketId,
                 qos_table = QosTable} ) ->
    io_lib:format("PacketId=~p, QosTable=~p", [PacketId, QosTable]);

dump_variable(PacketId) when is_integer(PacketId) ->
    io_lib:format("PacketId=~p", [PacketId]);

dump_variable(undefined) -> undefined.

dump_variable(undefined, undefined) -> 
    undefined;
dump_variable(undefined, <<>>) -> 
    undefined;
dump_variable(Variable, Payload) ->
    io_lib:format("~s, Payload=~p", [dump_variable(Variable), Payload]).

dump_password(undefined) -> undefined;
dump_password(_) -> <<"******">>.

dump_type(?CONNECT)     -> "CONNECT"; 
dump_type(?CONNACK)     -> "CONNACK";
dump_type(?PUBLISH)     -> "PUBLISH";
dump_type(?PUBACK)      -> "PUBACK";
dump_type(?PUBREC)      -> "PUBREC";
dump_type(?PUBREL)      -> "PUBREL";
dump_type(?PUBCOMP)     -> "PUBCOMP";
dump_type(?SUBSCRIBE)   -> "SUBSCRIBE";
dump_type(?SUBACK)      -> "SUBACK";
dump_type(?UNSUBSCRIBE) -> "UNSUBSCRIBE";
dump_type(?UNSUBACK)    -> "UNSUBACK";
dump_type(?PINGREQ)     -> "PINGREQ";
dump_type(?PINGRESP)    -> "PINGRESP";
dump_type(?DISCONNECT)  -> "DISCONNECT".

