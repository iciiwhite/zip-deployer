#!/usr/bin/env rebol
REBOL []

log: func [msg level] [
    t: now/time
    ts: rejoin [t/hour ":" t/minute ":" t/second]
    col: case [
        level = 'error ["^[[31m"]
        level = 'success ["^[[32m"]
        level = 'warn ["^[[33m"]
        true ["^[[36m"]
    ]
    icon: case [
        level = 'error ["✖"]
        level = 'success ["✓"]
        level = 'warn ["⚠"]
        true ["➜"]
    ]
    print rejoin ["^[[90m[" ts "]^[[0m " col icon " " msg "^[[0m"]
]

read-input: func [prompt] [
    prin prompt
    trim to-string input
]

github-request: func [token owner repo endpoint method data] [
    url: to-url rejoin ["https://api.github.com/repos/" owner "/" repo endpoint]
    headers: reduce [
        "Authorization" rejoin ["Bearer " token]
        "Accept" "application/vnd.github.v3+json"
        "Content-Type" "application/json"
    ]
    body: either data [to-json data][none]
    result: ""
    if method = "GET" [
        result: read/custom url reduce ['GET headers]
    ]
    if method = "POST" [
        result: write/custom url body reduce ['POST headers]
    ]
    if method = "PUT" [
        result: write/custom url body reduce ['PUT headers]
    ]
    if method = "PATCH" [
        result: write/custom url body reduce ['PATCH headers]
    ]
    if error? try [result: load result] [result: none]
    if not result [return none]
    if result/status < 200 or result/status >= 300 [
        cause-error 'user 'message rejoin ["HTTP " result/status ": " result/body]
    ]
    if result/status = 204 [return none]
    from-json result/body
]

get-ref: func [token owner repo branch] [
    data: github-request token owner repo "/git/ref/heads/" branch "GET" none
    data/object/sha
]

get-tree-sha: func [token owner repo commit-sha] [
    data: github-request token owner repo "/git/commits/" commit-sha "GET" none
    data/tree/sha
]

create-blob: func [token owner repo content] [
    data: github-request token owner repo "/git/blobs" "POST" reduce [
        "content" enbase base64 content
        "encoding" "base64"
    ]
    data/sha
]

create-tree: func [token owner repo base-tree entries] [
    data: github-request token owner repo "/git/trees" "POST" reduce [
        "base_tree" base-tree
        "tree" entries
    ]
    data/sha
]

create-commit: func [token owner repo parent tree message] [
    data: github-request token owner repo "/git/commits" "POST" reduce [
        "message" message
        "tree" tree
        "parents" reduce [parent]
    ]
    data/sha
]

update-ref: func [token owner repo branch commit-sha] [
    github-request token owner repo "/git/refs/heads/" branch "PATCH" reduce [
        "sha" commit-sha
        "force" false
    ]
]

init-repo: func [token owner repo branch] [
    readme: "# Project Repository\nInitialized automatically by GitHub ZIP Deployer."
    content: enbase base64 readme
    github-request token owner repo "/contents/README.md" "PUT" reduce [
        "message" "Initial commit by GitHub ZIP Deployer"
        "content" content
        "branch" branch
    ]
]

to-json: func [obj] [
    either block? obj [
        out: make string! 100
        append out "{"
        foreach [k v] obj [
            append out rejoin [{"] k ["":"]}
            either string? v [append out rejoin [{"] v ["",]}] [
                either block? v [append out to-json v] [append out rejoin [v ","]]
            ]
        ]
        remove back tail out
        append out "}"
        out
    ][
        either block? obj/1 [
            out: "["
            foreach item obj [
                append out to-json item
                append out ","
            ]
            remove back tail out
            append out "]"
            out
        ][
            form obj
        ]
    ]
]

from-json: func [json-str] [
    load replace/all replace/all json-str ":" " " "," " "
]

main: func [] [
    print rejoin ["^n^[[36m^[[1m🚀 GitHub ZIP Deployer — Tool by Icii White^[[0m^n"]
    token: ""
    while [token = ""][
        token: read-input "^[[33m🔑 Personal Access Token (repo scope): ^[[0m"
    ]
    owner: ""
    while [owner = ""][
        owner: read-input "^[[33m👤 Repository owner (username or org): ^[[0m"
    ]
    repo: ""
    while [repo = ""][
        repo: read-input "^[[33m📁 Repository name: ^[[0m"
    ]
    branch: read-input "^[[33m🌿 Branch name (default: main): ^[[0m"
    if branch = "" [branch: "main"]
    zip-path: ""
    while [zip-path = ""][
        zip-path: read-input "^[[33m🗂️  Path to ZIP file: ^[[0m"
        if not exists? to-file zip-path [
            log "File not found" 'error
            zip-path: ""
        ]
    ]
    log rejoin ["Target: " owner "/" repo " on branch '" branch "'"] 'info
    log rejoin ["ZIP file: " zip-path] 'info
    log "Reading ZIP file in memory..." 'info
    zip-dir: to-file rejoin [zip-path "/"]
    files: read zip-dir
    valid: copy []
    foreach f files [
        if not find last f #"/" [
            if not find f "__MACOSX" [
                if not find f ".DS_Store" [
                    content: read to-file rejoin [zip-dir f]
                    append valid reduce [f content]
                ]
            ]
        ]
    ]
    total: length? valid / 2
    log rejoin ["Found " total " valid files to process."] 'info
    try [
        latest: get-ref token owner repo branch
        base-tree: get-tree-sha token owner repo latest
    ] catch [
        log rejoin ["Branch '" branch "' not found or repository empty. Attempting initialization..."] 'warn
        init-repo token owner repo branch
        log "Successfully initialized repository with README.md" 'success
        latest: get-ref token owner repo branch
        base-tree: get-tree-sha token owner repo latest
    ]
    log "Uploading files as blobs..." 'info
    tree-entries: copy []
    batch: 10
    loop total [
        for i 1 total batch [
            batch-files: copy []
            for j i min (i + batch - 1) total [
                append batch-files reduce [valid/(2 * j - 1) valid/(2 * j)]
            ]
            results: copy []
            foreach [path content] batch-files [
                sha: create-blob token owner repo content
                append results reduce [
                    "path" path
                    "mode" "100644"
                    "type" "blob"
                    "sha" sha
                ]
            ]
            foreach [a b c d] results [
                append tree-entries reduce [a b c d]
            ]
            processed: min (i + batch - 1) total
            log rejoin ["  -> Uploaded " processed " / " total " files..."] 'info
        ]
    ]
    log "Constructing new Git tree..." 'info
    new-tree-sha: create-tree token owner repo base-tree tree-entries
    log "Creating commit..." 'info
    commit-msg: rejoin ["Upload ZIP deployment via Web Client^n^nUploaded " total " files."]
    new-commit-sha: create-commit token owner repo latest new-tree-sha commit-msg
    log "Updating branch reference to new commit..." 'info
    update-ref token owner repo branch new-commit-sha
    log rejoin ["Successfully deployed " total " files to " owner "/" repo " on branch '" branch "'! 🎉"] 'success
    log rejoin ["https://github.com/" owner "/" repo "/tree/" branch] 'info
]

main
halt