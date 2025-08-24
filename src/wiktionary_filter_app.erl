-module(wiktionary_filter_app).
-behaviour(application).

%% Application lifecycle callbacks
-export([start/2, stop/1]).

%% Cowboy HTTP handler callbacks
-export([init/2, terminate/3]).

%% Wiktionary API endpoint for French
-define(DICT_URL, "https://fr.wiktionary.org/w/api.php?action=query&titles=").

%%----------------------------------------------------------------
%% Application start callback
%%
%% Starts the filter supervision tree with the found port
%%----------------------------------------------------------------
start(_Type, _Args) ->
    {ok, Port} = em_filter:find_port(),
    em_filter_sup:start_link(wiktionary_filter, ?MODULE, Port).

%%----------------------------------------------------------------
%% Application stop callback (no cleanup required)
%%----------------------------------------------------------------
stop(_State) -> ok.

%%----------------------------------------------------------------
%% Cowboy init handler for each incoming HTTP request
%%
%% Reads JSON body, extracts requested word, fetches definitions,
%% and returns JSON with all parsed definitions.
%%----------------------------------------------------------------
init(Req0, State) ->
    try
        %% Read HTTP request body assumed to be JSON binary
        {ok, Body, Req} = cowboy_req:read_body(Req0),
        io:format("Received JSON body: ~p~n", [Body]),

        %% Generate list of definition embryos, handle any errors gracefully
        EmbryoList = safe_generate_embryo_list(Body),

        %% Encode response JSON containing the embryo list
        ResponseJson = jsone:encode(#{embryo_list => EmbryoList}),

        %% Send HTTP response with JSON content
        Req2 = cowboy_req:reply(200,
                    #{<<"content-type">> => <<"application/json">>},
                    ResponseJson,
                    Req),
        {ok, Req2, State}
    catch
        _:Error ->
            io:format("Error in init: ~p~n", [Error]),
            %% On error, reply with empty embryo list JSON
            EmptyJson = jsone:encode(#{embryo_list => []}),
            ReqErr = cowboy_req:reply(200,
                         #{<<"content-type">> => <<"application/json">>},
                         EmptyJson,
                         Req0),
            {ok, ReqErr, State}
    end.

%%----------------------------------------------------------------
%% Cowboy terminate callback (no cleanup needed)
%%----------------------------------------------------------------
terminate(_Reason, _Req, _State) -> ok.

%%----------------------------------------------------------------
%% Safely decode incoming JSON and generate embryo list of definitions
%%----------------------------------------------------------------
safe_generate_embryo_list(JsonBin) ->
    try generate_embryo_list(JsonBin)
    catch
        _:Err ->
            io:format("Error generating embryo list: ~p~n", [Err]),
            []
    end.

%% Decode JSON input, extract 'value' (word) and optional 'timeout', then fetch definitions
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
        _ ->
            []
    end.

%%----------------------------------------------------------------
%% Fetch the Wiktionary API JSON content for the given word, with a timeout.
%% Handles HTTP request errors gracefully.
%%----------------------------------------------------------------
fetch_definitions("", _) -> [];
fetch_definitions(Word, Timeout) ->
    try
        %% Construct URL for Wiktionary API request with full content prop
        Url = io_lib:format("~s~s&prop=revisions&rvprop=content&format=json", [?DICT_URL, Word]),
        Headers = [{"User-Agent", "wiktionary_filter/1.0"}],

        %% Perform HTTP GET with given timeout and disable SSL verification for simplicity
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
%% Safely extract definitions from Wiktionary API JSON response
%%----------------------------------------------------------------
safe_extract_definitions(Word, JsonBin) ->
    try extract_definitions(Word, JsonBin)
    catch
        _:Err ->
            io:format("Exception during extract_definitions: ~p~n", [Err]),
            []
    end.

%% Parse the JSON response to find the page content, then extract all definition lines
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

%% Helper to extract page content string from revision or slots structure
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
%% Additional text processing helpers
%%----------------------------------------------------------------

safe_binary_to_list(B) when is_binary(B) ->
    try binary_to_list(B) catch _:_ -> "" end;
safe_binary_to_list(_) -> "".

safe_split_lines(Text) ->
    try string:split(Text, "\n", all) catch _:_ -> [] end.

%% Extract all lines starting with one or more '#' characters, cleaning them
extract_all_definitions(Lines) ->
    extract_all_definitions(Lines, []).

extract_all_definitions([], Acc) ->
    lists:reverse(Acc);
extract_all_definitions([Line|Rest], Acc) ->
    LineStr = safe_line_to_string(Line),
    case starts_with_hash(LineStr) of
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

starts_with_hash([]) -> false;
starts_with_hash([H|_]) -> H == $#.

%% Clean common wiki markup including:
%% - Remove templates {{...}}
%% - Convert [[a|b]] links to "b"
%% - Convert [[c]] links to "c"
%% - Remove leading '#' characters and spaces
clean_wikicode(Line) ->
    L1 = re:replace(Line, "{{[^}]+}}", "", [global, {return, list}]),
    L2 = re:replace(L1, "\\[\\[([^\\]|]+)\\|([^\\]]+)\\]\\]", "\\2", [global, {return, list}]),
    L3 = re:replace(L2, "\\[\\[([^\\]]+)\\]\\]", "\\1", [global, {return, list}]),
    L4 = re:replace(L3, "^#+\\s*", "", [{return, list}]),
    string:trim(L4).

%%----------------------------------------------------------------
%% Build the JSON embryo list structure from the cleaned definitions
%%----------------------------------------------------------------
build_embryos(_Word, [], Acc) -> lists:reverse(Acc);
build_embryos(Word, [Def | Rest], Acc) ->
    try
        Embryo = #{
            properties => #{
                <<"resume">> => list_to_binary(Def),
                <<"url">> => list_to_binary(
                    io_lib:format("https://fr.wiktionary.org/wiki/~s", [Word])
                ),
                <<"word">> => list_to_binary(Word),
                <<"source">> => <<"fr.wiktionary.org">>
            }
        },
        build_embryos(Word, Rest, [Embryo | Acc])
    catch
        _:_ -> build_embryos(Word, Rest, Acc)
    end.
build_embryos(Word, Defs) -> build_embryos(Word, Defs, []).

