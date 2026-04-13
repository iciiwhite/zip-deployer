#!/usr/bin/env io

Color := Object clone
Color red := "\e[31m"
Color green := "\e[32m"
Color yellow := "\e[33m"
Color cyan := "\e[36m"
Color dim := "\e[90m"
Color reset := "\e[0m"
Color bold := "\e[1m"

log := method(msg, type,
    t := Date now asLocal formatted("%H:%M:%S")
    icon := ""
    col := ""
    if(type == "error", col = Color red; icon = "✖")
    if(type == "success", col = Color green; icon = "✓")
    if(type == "warn", col = Color yellow; icon = "⚠")
    if(type == "info", col = Color cyan; icon = "➜")
    writeln(Color dim .. "[" .. t .. "]" .. Color reset .. " " .. col .. icon .. " " .. msg .. Color reset)
)

readInput := method(prompt,
    write(prompt)
    File standardInput readLine strip
)

base64Encode := method(data,
    b64 := "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    result := ""
    i := 0
    while(i < data size,
        a := if(i < data size, data at(i), 0)
        b := if(i+1 < data size, data at(i+1), 0)
        c := if(i+2 < data size, data at(i+2), 0)
        result = result .. b64 at((a >> 2) & 0x3F)
        result = result .. b64 at(((a & 0x03) << 4) | ((b >> 4) & 0x0F))
        result = result .. if(i+1 < data size, b64 at(((b & 0x0F) << 2) | ((c >> 6) & 0x03)), "=")
        result = result .. if(i+2 < data size, b64 at(c & 0x3F), "=")
        i = i + 3
    )
    result
)

githubRequest := method(token, owner, repo, endpoint, method, data,
    url := "https://api.github.com/repos/" .. owner .. "/" .. repo .. endpoint
    headers := list("Authorization: Bearer " .. token, "Accept: application/vnd.github.v3+json", "Content-Type: application/json")
    body := if(data, JSON serialize(data), nil)
    socket := Socket clone
    socket setTimeOut(30)
    if(method == "GET",
        response := socket connect(url) request("GET", nil, headers, nil)
    ,
        response := socket connect(url) request(method, nil, headers, body)
    )
    if(response statusCode < 200 or response statusCode >= 300,
        Exception raise("HTTP " .. response statusCode .. ": " .. response body)
    )
    if(response statusCode == 204, return nil)
    JSON parse(response body)
)

getRef := method(token, owner, repo, branch,
    data := githubRequest(token, owner, repo, "/git/ref/heads/" .. branch, "GET", nil)
    data at("object") at("sha")
)

getTreeSha := method(token, owner, repo, commitSha,
    data := githubRequest(token, owner, repo, "/git/commits/" .. commitSha, "GET", nil)
    data at("tree") at("sha")
)

createBlob := method(token, owner, repo, content,
    data := githubRequest(token, owner, repo, "/git/blobs", "POST", list(
        "content" -> base64Encode(content),
        "encoding" -> "base64"
    ) asMap)
    data at("sha")
)

createTree := method(token, owner, repo, baseTree, entries,
    data := githubRequest(token, owner, repo, "/git/trees", "POST", list(
        "base_tree" -> baseTree,
        "tree" -> entries
    ) asMap)
    data at("sha")
)

createCommit := method(token, owner, repo, parent, tree, message,
    data := githubRequest(token, owner, repo, "/git/commits", "POST", list(
        "message" -> message,
        "tree" -> tree,
        "parents" -> list(parent)
    ) asMap)
    data at("sha")
)

updateRef := method(token, owner, repo, branch, commitSha,
    githubRequest(token, owner, repo, "/git/refs/heads/" .. branch, "PATCH", list(
        "sha" -> commitSha,
        "force" -> false
    ) asMap)
)

initRepo := method(token, owner, repo, branch,
    readme := "# Project Repository\nInitialized automatically by GitHub ZIP Deployer."
    content := base64Encode(readme asBytes)
    githubRequest(token, owner, repo, "/contents/README.md", "PUT", list(
        "message" -> "Initial commit by GitHub ZIP Deployer",
        "content" -> content,
        "branch" -> branch
    ) asMap)
)

main := method(
    writeln("\n" .. Color cyan .. Color bold .. "🚀 GitHub ZIP Deployer — Tool by Icii White" .. Color reset .. "\n")
    token := ""
    while(token == "",
        token = readInput(Color yellow .. "🔑 Personal Access Token (repo scope): " .. Color reset)
    )
    owner := ""
    while(owner == "",
        owner = readInput(Color yellow .. "👤 Repository owner (username or org): " .. Color reset)
    )
    repo := ""
    while(repo == "",
        repo = readInput(Color yellow .. "📁 Repository name: " .. Color reset)
    )
    branch := readInput(Color yellow .. "🌿 Branch name (default: main): " .. Color reset)
    if(branch == "", branch = "main")
    zipPath := ""
    while(zipPath == "",
        zipPath = readInput(Color yellow .. "🗂️  Path to ZIP file: " .. Color reset)
        if(File with(zipPath) exists not,
            log("File not found", "error")
            zipPath = ""
        )
    )
    log("Target: " .. owner .. "/" .. repo .. " on branch '" .. branch .. "'", "info")
    log("ZIP file: " .. zipPath, "info")
    log("Reading ZIP file in memory...", "info")
    zipData := File with(zipPath) readBytes
    zipArchive := Zip clone
    zipArchive open(zipData, "r")
    validFiles := list()
    zipArchive entries foreach(entry,
        if(entry isDir not,
            name := entry name
            if(name contains("__MACOSX") not and name contains(".DS_Store") not,
                content := entry readData
                validFiles append(list("path" -> name, "content" -> content) asMap)
            )
        )
    )
    zipArchive close
    total := validFiles size
    log("Found " .. total .. " valid files to process.", "info")
    latestCommitSha := nil
    baseTreeSha := nil
    try(
        latestCommitSha = getRef(token, owner, repo, branch)
        baseTreeSha = getTreeSha(token, owner, repo, latestCommitSha)
    ) catch(ex,
        log("Branch '" .. branch .. "' not found or repository empty. Attempting initialization...", "warn")
        initRepo(token, owner, repo, branch)
        log("Successfully initialized repository with README.md", "success")
        latestCommitSha = getRef(token, owner, repo, branch)
        baseTreeSha = getTreeSha(token, owner, repo, latestCommitSha)
    )
    log("Uploading files as blobs...", "info")
    treeEntries := list()
    batchSize := 10
    for(i, 0, total - 1, batchSize,
        batch := validFiles slice(i, i + batchSize)
        batchResults := list()
        batch foreach(file,
            sha := createBlob(token, owner, repo, file at("content"))
            batchResults append(list(
                "path" -> file at("path"),
                "mode" -> "100644",
                "type" -> "blob",
                "sha" -> sha
            ) asMap)
        )
        treeEntries appendSeq(batchResults)
        processed := if(i + batchSize > total, total, i + batchSize)
        log("  -> Uploaded " .. processed .. " / " .. total .. " files...", "info")
    )
    log("Constructing new Git tree...", "info")
    newTreeSha := createTree(token, owner, repo, baseTreeSha, treeEntries)
    log("Creating commit...", "info")
    commitMsg := "Upload ZIP deployment via Web Client\n\nUploaded " .. total .. " files."
    newCommitSha := createCommit(token, owner, repo, latestCommitSha, newTreeSha, commitMsg)
    log("Updating branch reference to new commit...", "info")
    updateRef(token, owner, repo, branch, newCommitSha)
    log("Successfully deployed " .. total .. " files to " .. owner .. "/" .. repo .. " on branch '" .. branch .. "'! 🎉", "success")
    log("https://github.com/" .. owner .. "/" .. repo .. "/tree/" .. branch, "info")
)

main