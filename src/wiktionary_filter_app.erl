%%%-------------------------------------------------------------------
%%% @doc French Wiktionary definition agent.
%%%
%%% Deduplication by URL is handled upstream by the Emquest pipeline.
%%%
%%% === Capability cascade ===
%%%
%%%   base_capabilities/0 extends em_filter:base_capabilities().
%%%
%%% Handler contract: handle/2 (Body, Memory) -> {RawList, Memory}.
%%% @end
%%%-------------------------------------------------------------------
-module(wiktionary_filter_app).
-behaviour(application).

-export([start/2, stop/1]).
-export([handle/2, base_capabilities/0]).

-define(DICT_URL, "https://fr.wiktionary.org/w/api.php?action=query&titles=").

%%====================================================================
%% Capability cascade
%%====================================================================

-spec base_capabilities() -> [binary()].
base_capabilities() ->
    em_filter:base_capabilities() ++ [<<"wiktionary">>, <<"french">>,
                                      <<"dictionary">>, <<"definition">>,
                                      <<"etymology">>].

%%====================================================================
%% Application lifecycle
%%====================================================================

start(_Type, _Args) ->
    case wiktionary_filter_sup:start_link() of
        {ok, Pid} ->
            ok = start_pop_and_http(),
            {ok, Pid};
        Error ->
            Error
    end.

stop(_State) ->
    catch cowboy:stop_listener(wiktionary_filter_query_listener),
    catch em_pop_sup:stop_node(wiktionary_filter),
    ok.

%%====================================================================
%% Internal
%%====================================================================

start_pop_and_http() ->
    PopPort   = application:get_env(wiktionary_filter, pop_port,   9506),
    QueryPort = application:get_env(wiktionary_filter, query_port, 9507),
    Seeds     = application:get_env(wiktionary_filter, pop_seeds,  []),
    Vec = em_filter_vec:from_capabilities(base_capabilities()),
    catch em_pop_sup:stop_node(wiktionary_filter),
    catch cowboy:stop_listener(wiktionary_filter_query_listener),
    {ok, PopPid} = em_pop_sup:start_node(wiktionary_filter, #{
        port            => PopPort,
        query_port      => QueryPort,
        vector          => Vec,
        max_peers       => 100,
        gossip_interval => 5_000
    }),
    lists:foreach(
        fun({H, P}) -> catch em_pop_node:add_peer(PopPid, H, P) end,
        Seeds),
    Dispatch = cowboy_router:compile([
        {'_', [{"/agent/query", em_filter_http,
                #{server => wiktionary_filter_server}}]}
    ]),
    {ok, _} = cowboy:start_clear(wiktionary_filter_query_listener,
                                  [{port, QueryPort}],
                                  #{env => #{dispatch => Dispatch}}),
    logger:notice("[wiktionary_filter] gossip port ~w  query port ~w",
                  [PopPort, QueryPort]),
    ok.

handle(Body, Memory) when is_binary(Body) ->
    {generate_embryo_list(Body), Memory};
handle(_Body, Memory) ->
    {[], Memory}.

%%====================================================================
%% Search and processing
%%====================================================================

generate_embryo_list(JsonBinary) ->
    {Word, Timeout} = extract_params(JsonBinary),
    fetch_definitions(Word, Timeout).

extract_params(JsonBinary) ->
    try json:decode(JsonBinary) of
        Map when is_map(Map) ->
            Word    = binary_to_list(maps:get(<<"value">>, Map,
                          maps:get(<<"query">>, Map, <<"">>))),
            Timeout = case maps:get(<<"timeout">>, Map, undefined) of
                undefined            -> 10;
                T when is_integer(T) -> T;
                T when is_binary(T)  -> binary_to_integer(T)
            end,
            {Word, Timeout};
        _ ->
            {binary_to_list(JsonBinary), 10}
    catch
        _:_ -> {binary_to_list(JsonBinary), 10}
    end.

fetch_definitions("", _) -> [];
fetch_definitions(Word, Timeout) ->
    Url = lists:flatten(io_lib:format(
        "~s~s&prop=revisions&rvprop=content&format=json",
        [?DICT_URL, uri_string:quote(Word)])),
    Headers = [{"User-Agent", "wiktionary_filter/1.0"}],
    case httpc:request(get, {Url, Headers},
                       [{timeout, Timeout * 1000},
                        {ssl, [{verify, verify_none}]}],
                       [{body_format, binary}]) of
        {ok, {{_, 200, _}, _, Body}} ->
            extract_definitions(Word, Body);
        _ ->
            []
    end.

extract_definitions(Word, JsonBin) ->
    try json:decode(JsonBin) of
        #{<<"query">> := #{<<"pages">> := Pages}} when is_map(Pages) ->
            case maps:values(Pages) of
                [Page | _] ->
                    Content = page_content(Page),
                    Lines   = string:split(binary_to_list(Content), "\n", all),
                    Defs    = extract_def_lines(Lines),
                    build_embryos(Word, Defs, []);
                _ -> []
            end;
        _ -> []
    catch
        _:_ -> []
    end.

page_content(Page) ->
    case maps:get(<<"revisions">>, Page, undefined) of
        [Rev | _] ->
            case Rev of
                #{<<"*">>     := C} -> C;
                #{<<"slots">> := #{<<"main">> := #{<<"*">> := C}}} -> C;
                _                   -> <<"">>
            end;
        _ -> <<"">>
    end.

extract_def_lines(Lines) ->
    lists:filtermap(fun(Line) ->
        Str = if is_binary(Line) -> binary_to_list(Line);
                 is_list(Line)   -> Line;
                 true            -> ""
              end,
        case Str of
            [$#, Next | _] when Next =:= $:; Next =:= $* -> false;
            [$# | _] ->
                Clean = clean_wikicode(Str),
                case Clean of
                    "" -> false;
                    _  -> {true, Clean}
                end;
            _ -> false
        end
    end, Lines).

clean_wikicode(Line) ->
    L1 = re:replace(Line, "\\{\\{[^\\}]+\\}\\}",               "",    [global, {return, list}]),
    L2 = re:replace(L1,   "\\[\\[([^\\]|]+)\\|([^\\]]+)\\]\\]", "\\2", [global, {return, list}]),
    L3 = re:replace(L2,   "\\[\\[([^\\]]+)\\]\\]",             "\\1", [global, {return, list}]),
    L4 = re:replace(L3,   "^#+\\s*",                            "",    [{return, list}]),
    L5 = re:replace(L4,   "^[*:].*",                            "",    [global, {return, list}]),
    string:trim(L5).

build_embryos(_Word, [], Acc) ->
    lists:reverse(Acc);
build_embryos(Word, [Def | Rest], Acc) ->
    Index = length(Acc) + 1,
    Url   = lists:flatten(io_lib:format(
                "https://fr.wiktionary.org/wiki/~s#.E2.91.A~p",
                [Word, Index])),
    Embryo = #{
        <<"properties">> => #{
            <<"url">>    => list_to_binary(Url),
            <<"resume">> => list_to_binary(Def),
            <<"word">>   => list_to_binary(Word),
            <<"source">> => <<"fr.wiktionary.org">>
        }
    },
    build_embryos(Word, Rest, [Embryo | Acc]).
