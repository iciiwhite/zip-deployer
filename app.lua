#!/usr/bin/env lua

local http = require("socket.http")
local ltn12 = require("ltn12")
local json = require("json")
local zip = require("zip")
local base64 = require("base64")

function log(msg, level)
    local time = os.date("%H:%M:%S")
    local color, icon
    if level == "error" then
        color = "\27[31m"
        icon = "✖"
    elseif level == "success" then
        color = "\27[32m"
        icon = "✓"
    elseif level == "warn" then
        color = "\27[33m"
        icon = "⚠"
    else
        color = "\27[36m"
        icon = "➜"
    end
    print(string.format("\27[90m[%s]\27[0m %s%s %s\27[0m", time, color, icon, msg))
end

function github_request(token, owner, repo, endpoint, method, data)
    local url = string.format("https://api.github.com/repos/%s/%s%s", owner, repo, endpoint)
    local headers = {
        ["Authorization"] = "Bearer " .. token,
        ["Accept"] = "application/vnd.github.v3+json",
        ["Content-Type"] = "application/json"
    }
    local body = data and json.encode(data) or nil
    local response_body = {}
    local res, code, response_headers = http.request {
        url = url,
        method = method or "GET",
        headers = headers,
        source = body and ltn12.source.string(body) or nil,
        sink = ltn12.sink.table(response_body)
    }
    if code < 200 or code >= 300 then
        error(string.format("HTTP %d: %s", code, table.concat(response_body)))
    end
    if code == 204 then return nil end
    return json.decode(table.concat(response_body))
end

function read_input(prompt)
    io.write(prompt)
    io.flush()
    local input = io.read()
    return input and input:match("^%s*(.-)%s*$") or ""
end

print("\n\27[36m\27[1m🚀 GitHub ZIP Deployer — Tool by Icii White\27[0m\n")

local token
repeat
    token = read_input("\27[33m🔑 Personal Access Token (repo scope): \27[0m")
until token ~= ""

local owner
repeat
    owner = read_input("\27[33m👤 Repository owner (username or org): \27[0m")
until owner ~= ""

local repo
repeat
    repo = read_input("\27[33m📁 Repository name: \27[0m")
until repo ~= ""

local branch = read_input("\27[33m🌿 Branch name (default: main): \27[0m")
if branch == "" then branch = "main" end

local zip_path
repeat
    zip_path = read_input("\27[33m🗂️  Path to ZIP file: \27[0m")
    local f = io.open(zip_path, "r")
    if not f then
        log("File not found", "error")
        zip_path = ""
    else
        f:close()
    end
until zip_path ~= ""

log(string.format("Target: %s/%s on branch '%s'", owner, repo, branch))
log("ZIP file: " .. zip_path)

log("Reading ZIP file in memory...")
local zfile = zip.open(zip_path)
local valid_files = {}
for file in zfile:files() do
    if not file:is_dir() then
        local name = file:get_name()
        if not name:match("__MACOSX") and not name:match("%.DS_Store") then
            local content = file:read("*all")
            table.insert(valid_files, {path = name, content = content})
        end
    end
end
zfile:close()
log(string.format("Found %d valid files to process.", #valid_files))

local latest_commit_sha, base_tree_sha
local ok, err = pcall(function()
    local ref = github_request(token, owner, repo, "/git/ref/heads/" .. branch)
    latest_commit_sha = ref.object.sha
    local commit = github_request(token, owner, repo, "/git/commits/" .. latest_commit_sha)
    base_tree_sha = commit.tree.sha
end)
if not ok then
    log(string.format("Branch '%s' not found or repository empty. Attempting initialization...", branch), "warn")
    local readme_content = base64.encode("# Project Repository\nInitialized automatically by GitHub ZIP Deployer.")
    github_request(token, owner, repo, "/contents/README.md", "PUT", {
        message = "Initial commit by GitHub ZIP Deployer",
        content = readme_content,
        branch = branch
    })
    log("Successfully initialized repository with README.md", "success")
    local ref = github_request(token, owner, repo, "/git/ref/heads/" .. branch)
    latest_commit_sha = ref.object.sha
    local commit = github_request(token, owner, repo, "/git/commits/" .. latest_commit_sha)
    base_tree_sha = commit.tree.sha
end

log("Uploading files as blobs...")
local tree_entries = {}
local batch_size = 10
local total = #valid_files
for i = 1, total, batch_size do
    local batch = {}
    for j = i, math.min(i + batch_size - 1, total) do
        table.insert(batch, valid_files[j])
    end
    local threads = {}
    for _, file in ipairs(batch) do
        local co = coroutine.create(function()
            local blob = github_request(token, owner, repo, "/git/blobs", "POST", {
                content = base64.encode(file.content),
                encoding = "base64"
            })
            return {path = file.path, sha = blob.sha}
        end)
        table.insert(threads, co)
    end
    for _, co in ipairs(threads) do
        coroutine.resume(co)
        local ok, res = coroutine.resume(co)
        if ok then
            table.insert(tree_entries, {
                path = res.path,
                mode = "100644",
                type = "blob",
                sha = res.sha
            })
        end
    end
    local processed = math.min(i + batch_size - 1, total)
    log(string.format("  -> Uploaded %d / %d files...", processed, total))
end

log("Constructing new Git tree...")
local new_tree = github_request(token, owner, repo, "/git/trees", "POST", {
    base_tree = base_tree_sha,
    tree = tree_entries
})
local new_tree_sha = new_tree.sha

log("Creating commit...")
local commit_msg = string.format("Upload ZIP deployment via Web Client\n\nUploaded %d files.", total)
local new_commit = github_request(token, owner, repo, "/git/commits", "POST", {
    message = commit_msg,
    tree = new_tree_sha,
    parents = {latest_commit_sha}
})
local new_commit_sha = new_commit.sha

log("Updating branch reference to new commit...")
github_request(token, owner, repo, "/git/refs/heads/" .. branch, "PATCH", {
    sha = new_commit_sha,
    force = false
})

log(string.format("Successfully deployed %d files to %s/%s on branch '%s'! 🎉", total, owner, repo, branch), "success")
log(string.format("https://github.com/%s/%s/tree/%s", owner, repo, branch))