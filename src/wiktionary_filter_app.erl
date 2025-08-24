-module(wiktionary_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([init/2, terminate/3]).

%% Wiktionary API endpoint for French
-define(DICT_URL, "https://fr.wiktionary.org/w/api.php?action=query&titles=").

%%----------------------------------------------------------------
%% Application start callback
%%----------------------------------------------------------------
start(_Type, _Args) ->
    {ok, Port} = em_filter:find_port(),
    em_filter_sup:start_link(wiktionary_filter, ?MODULE, Port).

%%----------------------------------------------------------------
%% Application stop callback
%%----------------------------------------------------------------
stop(_State) -> ok.

%%----------------------------------------------------------------
%% Cowboy init handler
%%----------------------------------------------------------------
init(Req0, State) ->
    try
        {ok, Body, Req} = cowboy_req:read_body(Req0),
        io:format("Received JSON body: ~p~n", [Body]),
        EmbryoList = safe_generate_embryo_list(Body),
        ResponseJson = jsone:encode(#{embryo_list => EmbryoList}),
        Req2 = cowboy_req:reply(200,
                    #{<<"content-type">> => <<"application/json">>},
                    ResponseJson,
                    Req),
        {ok, Req2, State}
    catch
        _:Error ->
            io:format("Error in init: ~p~n", [Error]),
            EmptyJson = jsone:encode(#{embryo_list => []}),
            ReqErr = cowboy_req:reply(200,
                         #{<<"content-type">> => <<"application/json">>},
                         EmptyJson,
                         Req0),
            {ok, ReqErr, State}
    end.

terminate(_Reason, _Req, _State) -> ok.

%%----------------------------------------------------------------
%% Safe JSON decode / embryo generator
%%----------------------------------------------------------------
safe_generate_embryo_list(JsonBin) ->
    try generate_embryo_list(JsonBin)
    catch
        _:Err ->
            io:format("Error generating embryo list: ~p~n", [Err]),
            []
    end.

generate_embryo_list(JsonBin) ->
    case jsone:decode(JsonBin, [{keys, atom}]) of
        Map when is_map(Map) ->
            Word = binary_to_list(maps:get(value, Map, <<"">>)),
            Timeout =
                case maps:get(timeout, Map, <<"10">>) of
                    Bin when is_binary(Bin) -> list_to_integer(binary_to_list(Bin));
                    N when is_integer(N) -> N;
                    _ -> 10
                end,
            fetch_definitions(Word, Timeout);
        _ -> []
    end.

%%----------------------------------------------------------------
%% Fetch Wiktionary Data
%%----------------------------------------------------------------
fetch_definitions("", _) -> [];
fetch_definitions(Word, Timeout) ->
    try
        Url = io_lib:format("~s~s&prop=revisions&rvprop=content&format=json", [?DICT_URL, Word]),
        Headers = [{"User-Agent", "wiktionary_filter/1.0"}],
        case httpc:request(get,
                {list_to_binary(Url), Headers},
                [{timeout, Timeout * 1000}, {ssl, [{verify, verify_none}]}],
                [{body_format, binary}]) of
            {ok, {{_, 200, _}, _, Body}} ->
                safe_extract_definitions(Word, Body);
            {ok, {{_, Status, _}, _, _}} ->
                io:format("Wiktionary API returned status ~p for word ~s~n", [Status, Word]),
                [];
            {error, Reason} ->
                io:format("HTTP error ~p for word ~s~n", [Reason, Word]),
                []
        end
    catch
        _:Err ->
            io:format("Exception during fetch_definitions: ~p~n", [Err]),
            []
    end.

%%----------------------------------------------------------------
%% Extract Definitions
%%----------------------------------------------------------------
safe_extract_definitions(Word, JsonBin) ->
    try extract_definitions(Word, JsonBin)
    catch
        _:Err ->
            io:format("Exception during extract_definitions: ~p~n", [Err]),
            []
    end.

extract_definitions(Word, JsonBin) ->
    case jsone:decode(JsonBin) of
        #{<<"query">> := #{<<"pages">> := Pages}} when is_map(Pages) ->
            case maps:values(Pages) of
                [Page | _] ->
                    Content = get_page_content(Page),
                    Text = safe_binary_to_list(Content),
                    Lines = safe_split_lines(Text),
                    DefLines = extract_all_definitions(Lines),
                    build_embryos(Word, DefLines);
                _ -> []
            end;
        _ -> []
    end.

get_page_content(Page) ->
    case maps:get(<<"revisions">>, Page, undefined) of
        [Rev | _] ->
            case Rev of
                #{<<"*">> := Content} -> Content;
                #{<<"slots">> := #{<<"main">> := #{<<"*">> := Content}}} -> Content;
                _ -> <<"">>
            end;
        _ -> <<"">>
    end.

%%----------------------------------------------------------------
%% Helpers
%%----------------------------------------------------------------
safe_binary_to_list(B) when is_binary(B) ->
    try binary_to_list(B) catch _:_ -> "" end;
safe_binary_to_list(_) -> "".

safe_split_lines(Text) ->
    try string:split(Text, "\n", all) catch _:_ -> [] end.

%%----------------------------------------------------------------
%% Extract only real definitions (ignore examples '#*' and usage '#:')
%%----------------------------------------------------------------
extract_all_definitions(Lines) ->
    extract_all_definitions(Lines, []).

extract_all_definitions([], Acc) ->
    lists:reverse(Acc);
extract_all_definitions([Line|Rest], Acc) ->
    LineStr = safe_line_to_string(Line),
    case is_definition_line(LineStr) of
        true ->
            Clean = clean_wikicode(LineStr),
            case Clean of
                "" -> extract_all_definitions(Rest, Acc);
                _  -> extract_all_definitions(Rest, [Clean | Acc])
            end;
        false ->
            extract_all_definitions(Rest, Acc)
    end.

safe_line_to_string(Line) when is_binary(Line) -> safe_binary_to_list(Line);
safe_line_to_string(Line) when is_list(Line) -> Line;
safe_line_to_string(_) -> "".

%% Only "# ..." definitions, not "#:" notes, not "#*" examples
is_definition_line([]) -> false;
is_definition_line([$#, Next | _]) when Next == $:; Next == $* -> false;
is_definition_line([$# | _]) -> true;
is_definition_line(_) -> false.

%%----------------------------------------------------------------
%% Clean wiki markup
%%----------------------------------------------------------------
clean_wikicode(Line) ->
    %% remove templates {{...}}
    L1 = re:replace(Line, "\\{\\{[^\\}]+\\}\\}", "", [global, {return, list}]),
    %% convert [[a|b]] to "b"
    L2 = re:replace(L1, "\\[\\[([^\\]|]+)\\|([^\\]]+)\\]\\]", "\\2", [global, {return, list}]),
    %% convert [[c]] to "c"
    L3 = re:replace(L2, "\\[\\[([^\\]]+)\\]\\]", "\\1", [global, {return, list}]),
    %% remove leading "#..."
    L4 = re:replace(L3, "^#+\\s*", "", [{return, list}]),
    %% delete leftover example/usage markers
    L5 = re:replace(L4, "^[*:].*", "", [global, {return, list}]),
    string:trim(L5).

%%----------------------------------------------------------------
%% Build embryos
%%----------------------------------------------------------------

build_embryos(Word, Defs) ->
    build_embryos(Word, Defs, []).

%% Worker with accumulator
build_embryos(_Word, [], Acc) ->
    lists:reverse(Acc);
build_embryos(Word, [Def | Rest], Acc) ->
    try
        Index = length(Acc) + 1,
        Url = lists:flatten(io_lib:format(
                  "https://fr.wiktionary.org/wiki/~s#.E2.91.A~p",
                  [Word, Index])),
        Embryo = #{
            properties => #{
                <<"resume">> => list_to_binary(Def),
                <<"url">> => list_to_binary(Url),
                <<"word">> => list_to_binary(Word),
                <<"source">> => <<"fr.wiktionary.org">>
            }
        },
        build_embryos(Word, Rest, [Embryo | Acc])
    catch
        _:_ -> build_embryos(Word, Rest, Acc)
    end.

