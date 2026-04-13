#!/usr/bin/env escript
%% -*- erlang -*-
%%! -sname zip_deployer -noshell

main(_) ->
    io:setopts([{encoding, unicode}]),
    io:format("\n\033[36m\033[1m🚀 GitHub ZIP Deployer — Tool by Icii White\033[0m\n\n"),
    inets:start(),
    ssl:start(),
    
    Token = get_input("\033[33m🔑 Personal Access Token (repo scope): \033[0m", true),
    Owner = get_input("\033[33m👤 Repository owner (username or org): \033[0m", false),
    Repo = get_input("\033[33m📁 Repository name: \033[0m", false),
    Branch = case get_input("\033[33m🌿 Branch name (default: main): \033[0m", false) of
                 "" -> "main";
                 B -> B
             end,
    ZipPath = get_input("\033[33m🗂️  Path to ZIP file: \033[0m", false),
    
    log("Target: " ++ Owner ++ "/" ++ Repo ++ " on branch '" ++ Branch ++ "'", info),
    log("ZIP file: " ++ ZipPath, info),
    
    {ok, ZipBin} = file:read_file(ZipPath),
    log("Reading ZIP file in memory...", info),
    
    ValidFiles = extract_zip(ZipBin),
    log("Found " ++ integer_to_list(length(ValidFiles)) ++ " valid files to process.", info),
    
    {LatestCommitSha, BaseTreeSha} = get_initial_refs(Token, Owner, Repo, Branch),
    
    log("Uploading files as blobs...", info),
    TreeEntries = upload_blobs(Token, Owner, Repo, ValidFiles),
    
    log("Constructing new Git tree...", info),
    NewTreeSha = create_tree(Token, Owner, Repo, BaseTreeSha, TreeEntries),
    
    log("Creating commit...", info),
    CommitMsg = "Upload ZIP deployment via Web Client\n\nUploaded " ++ integer_to_list(length(ValidFiles)) ++ " files.",
    NewCommitSha = create_commit(Token, Owner, Repo, LatestCommitSha, NewTreeSha, CommitMsg),
    
    log("Updating branch reference to new commit...", info),
    update_ref(Token, Owner, Repo, Branch, NewCommitSha),
    
    log("Successfully deployed " ++ integer_to_list(length(ValidFiles)) ++ " files to " ++ Owner ++ "/" ++ Repo ++ " on branch '" ++ Branch ++ "'! 🎉", success),
    log("https://github.com/" ++ Owner ++ "/" ++ Repo ++ "/tree/" ++ Branch, info),
    halt(0).

get_input(Prompt, Secret) ->
    io:format(Prompt),
    case Secret of
        true -> 
            io:get_line("")  % no hidden input for simplicity
        false ->
            io:get_line("")
    end,
    Line = io:get_line(""),
    string:trim(Line).

log(Msg, Type) ->
    {Hour, Minute, Second} = time(),
    Timestamp = io_lib:format("[~2..0B:~2..0B:~2..0B]", [Hour, Minute, Second]),
    {Color, Icon} = case Type of
                        error -> {"\033[31m", "✖"};
                        success -> {"\033[32m", "✓"};
                        warn -> {"\033[33m", "⚠"};
                        _ -> {"\033[36m", "➜"}
                    end,
    io:format("\033[90m~s\033[0m ~s~s ~s\033[0n", [Timestamp, Color, Icon, Msg]),
    io:nl().

extract_zip(Bin) ->
    {ok, Zip} = zip:open(Bin, [memory]),
    {ok, FileList} = zip:list_dir(Zip),
    Valid = lists:foldl(fun(FileName, Acc) ->
        case lists:last(FileName) == $/ of
            true -> Acc;
            false ->
                case string:str(FileName, "__MACOSX") > 0 orelse string:str(FileName, ".DS_Store") > 0 of
                    true -> Acc;
                    false ->
                        {ok, Content} = zip:read(Zip, FileName),
                        [{FileName, Content} | Acc]
                end
        end
    end, [], FileList),
    zip:close(Zip),
    lists:reverse(Valid).

get_initial_refs(Token, Owner, Repo, Branch) ->
    case github_api_get(Token, Owner, Repo, "/git/ref/heads/" ++ Branch) of
        {ok, RefJson} ->
            LatestCommitSha = proplists:get_value(<<"sha">>, proplists:get_value(<<"object">>, RefJson, [])),
            {ok, CommitJson} = github_api_get(Token, Owner, Repo, "/git/commits/" ++ binary_to_list(LatestCommitSha)),
            BaseTreeSha = proplists:get_value(<<"sha">>, proplists:get_value(<<"tree">>, CommitJson, [])),
            {binary_to_list(LatestCommitSha), binary_to_list(BaseTreeSha)};
        {error, _} ->
            log("Branch '" ++ Branch ++ "' not found or repository empty. Attempting initialization...", warn),
            InitReadme = base64:encode_to_string("# Project Repository\nInitialized automatically by GitHub ZIP Deployer."),
            InitBody = io_lib:format(~s, [{<<"message">>, <<"Initial commit by GitHub ZIP Deployer">>},
                                         {<<"content">>, list_to_binary(InitReadme)},
                                         {<<"branch">>, list_to_binary(Branch)}]),
            case github_api_put(Token, Owner, Repo, "/contents/README.md", InitBody) of
                {ok, _} ->
                    log("Successfully initialized repository with README.md", success),
                    get_initial_refs(Token, Owner, Repo, Branch);
                {error, InitErr} ->
                    log("Failed to initialize empty repository: " ++ InitErr, error),
                    halt(1)
            end
    end.

github_api_get(Token, Owner, Repo, Endpoint) ->
    Url = "https://api.github.com/repos/" ++ Owner ++ "/" ++ Repo ++ Endpoint,
    Headers = [{"Authorization", "Bearer " ++ Token},
               {"Accept", "application/vnd.github.v3+json"}],
    case httpc:request(get, {Url, Headers}, [], []) of
        {ok, {{_, 200, _}, _, Body}} -> {ok, jsx:decode(list_to_binary(Body))};
        {ok, {{_, 204, _}, _, _}} -> {ok, []};
        {ok, {{_, Code, _}, _, Body}} -> {error, io_lib:format("HTTP ~B: ~s", [Code, Body])};
        {error, Reason} -> {error, io_lib:format("~p", [Reason])}
    end.

github_api_post(Token, Owner, Repo, Endpoint, JsonBody) ->
    Url = "https://api.github.com/repos/" ++ Owner ++ "/" ++ Repo ++ Endpoint,
    Headers = [{"Authorization", "Bearer " ++ Token},
               {"Accept", "application/vnd.github.v3+json"},
               {"Content-Type", "application/json"}],
    Body = jsx:encode(JsonBody),
    case httpc:request(post, {Url, Headers, "application/json", Body}, [], []) of
        {ok, {{_, 200, _}, _, Resp}} -> {ok, jsx:decode(list_to_binary(Resp))};
        {ok, {{_, 201, _}, _, Resp}} -> {ok, jsx:decode(list_to_binary(Resp))};
        {ok, {{_, Code, _}, _, Resp}} -> {error, io_lib:format("HTTP ~B: ~s", [Code, Resp])};
        {error, Reason} -> {error, io_lib:format("~p", [Reason])}
    end.

github_api_patch(Token, Owner, Repo, Endpoint, JsonBody) ->
    Url = "https://api.github.com/repos/" ++ Owner ++ "/" ++ Repo ++ Endpoint,
    Headers = [{"Authorization", "Bearer " ++ Token},
               {"Accept", "application/vnd.github.v3+json"},
               {"Content-Type", "application/json"}],
    Body = jsx:encode(JsonBody),
    case httpc:request(patch, {Url, Headers, "application/json", Body}, [], []) of
        {ok, {{_, 200, _}, _, Resp}} -> {ok, jsx:decode(list_to_binary(Resp))};
        {ok, {{_, 204, _}, _, _}} -> {ok, []};
        {ok, {{_, Code, _}, _, Resp}} -> {error, io_lib:format("HTTP ~B: ~s", [Code, Resp])};
        {error, Reason} -> {error, io_lib:format("~p", [Reason])}
    end.

github_api_put(Token, Owner, Repo, Endpoint, JsonBody) ->
    Url = "https://api.github.com/repos/" ++ Owner ++ "/" ++ Repo ++ Endpoint,
    Headers = [{"Authorization", "Bearer " ++ Token},
               {"Accept", "application/vnd.github.v3+json"},
               {"Content-Type", "application/json"}],
    Body = jsx:encode(JsonBody),
    case httpc:request(put, {Url, Headers, "application/json", Body}, [], []) of
        {ok, {{_, 200, _}, _, Resp}} -> {ok, jsx:decode(list_to_binary(Resp))};
        {ok, {{_, 201, _}, _, Resp}} -> {ok, jsx:decode(list_to_binary(Resp))};
        {ok, {{_, Code, _}, _, Resp}} -> {error, io_lib:format("HTTP ~B: ~s", [Code, Resp])};
        {error, Reason} -> {error, io_lib:format("~p", [Reason])}
    end.

upload_blobs(Token, Owner, Repo, Files) ->
    Total = length(Files),
    upload_blobs_parallel(Token, Owner, Repo, Files, 1, Total, []).

upload_blobs_parallel(_Token, _Owner, _Repo, [], _Processed, _Total, Acc) ->
    lists:reverse(Acc);
upload_blobs_parallel(Token, Owner, Repo, Files, Processed, Total, Acc) ->
    BatchSize = 10,
    {Batch, Rest} = if length(Files) >= BatchSize -> lists:split(BatchSize, Files);
                       true -> {Files, []}
                    end,
    Pids = [spawn_link(fun() ->
        {Path, Content} = File,
        B64 = base64:encode_to_string(Content),
        Body = [{<<"content">>, list_to_binary(B64)}, {<<"encoding">>, <<"base64">>}],
        case github_api_post(Token, Owner, Repo, "/git/blobs", Body) of
            {ok, Json} -> Sha = proplists:get_value(<<"sha">>, Json, <<"">>),
                          self() ! {ok, Path, binary_to_list(Sha)};
            {error, Err} -> self() ! {error, Err}
        end
    end) || File <- Batch],
    Results = [receive R -> R end || _ <- Batch],
    NewAcc = lists:foldl(fun({ok, Path, Sha}, AccIn) ->
        Entry = [{<<"path">>, list_to_binary(Path)},
                 {<<"mode">>, <<"100644">>},
                 {<<"type">>, <<"blob">>},
                 {<<"sha">>, list_to_binary(Sha)}],
        [Entry | AccIn];
        ({error, Err}, AccIn) ->
            log("Blob upload failed: " ++ Err, error),
            AccIn
    end, Acc, Results),
    NewProcessed = Processed + length(Batch),
    log("  -> Uploaded " ++ integer_to_list(NewProcessed) ++ " / " ++ integer_to_list(Total) ++ " files...", info),
    upload_blobs_parallel(Token, Owner, Repo, Rest, NewProcessed, Total, NewAcc).

create_tree(Token, Owner, Repo, BaseTreeSha, TreeEntries) ->
    Body = [{<<"base_tree">>, list_to_binary(BaseTreeSha)},
            {<<"tree">>, TreeEntries}],
    {ok, Json} = github_api_post(Token, Owner, Repo, "/git/trees", Body),
    binary_to_list(proplists:get_value(<<"sha">>, Json)).

create_commit(Token, Owner, Repo, ParentSha, TreeSha, Message) ->
    Body = [{<<"message">>, list_to_binary(Message)},
            {<<"tree">>, list_to_binary(TreeSha)},
            {<<"parents">>, [list_to_binary(ParentSha)]}],
    {ok, Json} = github_api_post(Token, Owner, Repo, "/git/commits", Body),
    binary_to_list(proplists:get_value(<<"sha">>, Json)).

update_ref(Token, Owner, Repo, Branch, CommitSha) ->
    Body = [{<<"sha">>, list_to_binary(CommitSha)},
            {<<"force">>, false}],
    {ok, _} = github_api_patch(Token, Owner, Repo, "/git/refs/heads/" ++ Branch, Body),
    ok.
