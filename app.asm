; app.asm - GitHub ZIP Deployer for x86-64 Linux
; NASM syntax, links with libc, libcurl, libzip, libjansson
; Build: nasm -f elf64 app.asm && gcc -no-pie -o app app.o -lcurl -lzip -ljansson

global main
extern printf, scanf, fgets, stdin, stdout, stderr, puts, getchar
extern curl_global_init, curl_easy_init, curl_easy_setopt, curl_easy_perform, curl_easy_cleanup, curl_global_cleanup
extern zip_open, zip_close, zip_stat_init, zip_stat, zip_get_name, zip_fopen, zip_fread, zip_fclose, zip_get_num_entries
extern json_object, json_string, json_integer, json_boolean, json_object_set_new, json_dumps, json_decref, json_loads
extern malloc, free, strlen, strcmp, strstr, strchr, strcspn, memset, memcpy, fopen, fread, fclose, feof
extern time, localtime, strftime, exit

section .rodata
    prompt_token db 0x1b, "[33m", "🔑 Personal Access Token (repo scope): ", 0x1b, "[0m", 0
    prompt_owner db 0x1b, "[33m", "👤 Repository owner (username or org): ", 0x1b, "[0m", 0
    prompt_repo db 0x1b, "[33m", "📁 Repository name: ", 0x1b, "[0m", 0
    prompt_branch db 0x1b, "[33m", "🌿 Branch name (default: main): ", 0x1b, "[0m", 0
    prompt_zip db 0x1b, "[33m", "🗂️  Path to ZIP file: ", 0x1b, "[0m", 0
    fmt_str db "%s", 0
    fmt_char db "%c", 0
    default_branch db "main", 0
    log_prefix db 0x1b, "[90m[", 0
    log_suffix db "] ", 0
    log_info db 0x1b, "[36m➜ ", 0
    log_success db 0x1b, "[32m✓ ", 0
    log_warn db 0x1b, "[33m⚠ ", 0
    log_error db 0x1b, "[31m✖ ", 0
    log_reset db 0x1b, "[0m", 0
    time_fmt db "%H:%M:%S", 0
    header_line db 0x0a, 0x1b, "[36m", 0x1b, "[1m🚀 GitHub ZIP Deployer — Tool by Icii White", 0x1b, "[0m", 0x0a, 0
    api_base db "https://api.github.com/repos/", 0
    git_ref_heads db "/git/ref/heads/", 0
    git_commits db "/git/commits/", 0
    git_blobs db "/git/blobs", 0
    git_trees db "/git/trees", 0
    git_commits_post db "/git/commits", 0
    git_refs_patch db "/git/refs/heads/", 0
    contents_readme db "/contents/README.md", 0
    user_agent db "GitHub-ZIP-Deployer", 0
    auth_header db "Authorization: Bearer ", 0
    accept_header db "Accept: application/vnd.github.v3+json", 0
    content_type db "Content-Type: application/json", 0
    method_get db "GET", 0
    method_post db "POST", 0
    method_put db "PUT", 0
    method_patch db "PATCH", 0
    json_content db "content", 0
    json_encoding db "encoding", 0
    json_base64 db "base64", 0
    json_tree db "tree", 0
    json_base_tree db "base_tree", 0
    json_message db "message", 0
    json_parents db "parents", 0
    json_sha db "sha", 0
    json_object db "object", 0
    json_path db "path", 0
    json_mode db "mode", 0
    json_type db "type", 0
    json_blob db "blob", 0
    mode_644 db "100644", 0
    init_readme db "# Project Repository", 0x0a, "Initialized automatically by GitHub ZIP Deployer.", 0
    init_commit_msg db "Initial commit by GitHub ZIP Deployer", 0
    commit_msg_prefix db "Upload ZIP deployment via Web Client", 0x0a, 0x0a, "Uploaded ", 0
    commit_msg_suffix db " files.", 0
    deploy_success_msg db "Successfully deployed ", 0
    deploy_url_prefix db "https://github.com/", 0
    deploy_url_mid db "/tree/", 0
    found_files_msg db "Found ", 0
    valid_files_msg db " valid files to process.", 0
    reading_zip db "Reading ZIP file in memory...", 0
    uploading_blobs db "Uploading files as blobs...", 0
    constructing_tree db "Constructing new Git tree...", 0
    creating_commit db "Creating commit...", 0
    updating_ref db "Updating branch reference to new commit...", 0
    init_attempt db "Branch '%s' not found or repository empty. Attempting initialization...", 0
    init_success db "Successfully initialized repository with README.md", 0
    zip_read_error db "Cannot read ZIP file", 0
    file_not_found db "File not found", 0
    token_required db "Token required", 0
    owner_required db "Owner required", 0
    repo_required db "Repository name required", 0
    blob_upload_failed db "Blob upload failed", 0
    git_api_error db "GitHub API error", 0
    upload_progress db "  -> Uploaded %d / %d files...", 0
    deploy_complete db "Successfully deployed %d files to %s/%s on branch '%s'! 🎉", 0
    deploy_url_fmt db "https://github.com/%s/%s/tree/%s", 0

section .bss
    token resb 512
    owner resb 256
    repo resb 256
    branch resb 256
    zip_path resb 1024
    log_time resb 64
    url_buffer resb 2048
    auth_header_buf resb 1024
    response_body resb 65536
    curl_error resb 256
    zip_stat_buf resb 128
    filename_buf resb 1024
    content_buf resb 1048576
    json_response resb 524288
    tree_entry_buf resb 4096
    tmp_str resb 4096
    int_buf resb 32

section .data
    curl_handle dq 0
    zip_handle dq 0
    latest_commit_sha dq 0
    base_tree_sha dq 0
    total_files dq 0
    processed_files dq 0

section .text

log_message:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov [rbp-8], rdi   ; msg
    mov [rbp-12], sil  ; level

    mov rdi, log_time
    mov rsi, time_fmt
    xor rax, rax
    call get_time_str

    mov rdi, log_prefix
    call printf
    mov rdi, log_time
    call printf
    mov rdi, log_suffix
    call printf

    cmp byte [rbp-12], 'e'
    je .error
    cmp byte [rbp-12], 's'
    je .success
    cmp byte [rbp-12], 'w'
    je .warn
    mov rdi, log_info
    call printf
    jmp .print_msg
.error:
    mov rdi, log_error
    call printf
    jmp .print_msg
.success:
    mov rdi, log_success
    call printf
    jmp .print_msg
.warn:
    mov rdi, log_warn
    call printf
.print_msg:
    mov rdi, [rbp-8]
    call printf
    mov rdi, log_reset
    call printf
    mov rdi, 0x0a
    call putchar
    leave
    ret

get_time_str:
    push rbp
    mov rbp, rsp
    sub rsp, 16
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    xor rdi, rdi
    call time
    mov rdi, rax
    call localtime
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    mov rdx, rax
    call strftime
    leave
    ret

read_input:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-24], rdi   ; prompt
    mov [rbp-28], rsi   ; buffer
    mov rdi, [rbp-24]
    call printf
    mov rdi, [rbp-28]
    mov rsi, 512
    mov rdx, stdin
    call fgets
    mov rdi, [rbp-28]
    call strlen
    dec rax
    mov byte [rdi+rax], 0
    leave
    ret

github_request:
    push rbp
    mov rbp, rsp
    sub rsp, 128
    mov [rbp-88], rdi   ; token
    mov [rbp-96], rsi   ; owner
    mov [rbp-104], rdx  ; repo
    mov [rbp-112], rcx  ; endpoint
    mov [rbp-120], r8   ; method
    mov [rbp-128], r9   ; post_data

    mov rdi, url_buffer
    mov rsi, api_base
    call strcpy
    mov rdi, url_buffer
    call strlen
    mov rdi, url_buffer
    add rdi, rax
    mov rsi, [rbp-96]
    call strcpy
    mov rdi, url_buffer
    call strlen
    mov rdi, url_buffer
    add rdi, rax
    mov byte [rdi], '/'
    inc rdi
    mov rsi, [rbp-104]
    call strcpy
    mov rdi, url_buffer
    call strlen
    mov rdi, url_buffer
    add rdi, rax
    mov rsi, [rbp-112]
    call strcpy

    mov rdi, curl_handle
    call curl_easy_init
    mov [curl_handle], rax

    mov rdi, [curl_handle]
    mov rsi, 10002
    mov rdx, url_buffer
    call curl_easy_setopt

    mov rdi, [curl_handle]
    mov rsi, 10036
    mov rdx, user_agent
    call curl_easy_setopt

    mov rdi, auth_header_buf
    mov rsi, auth_header
    call strcpy
    mov rdi, auth_header_buf
    call strlen
    mov rdi, auth_header_buf
    add rdi, rax
    mov rsi, [rbp-88]
    call strcpy
    mov rdi, [curl_handle]
    mov rsi, 10023
    mov rdx, auth_header_buf
    call curl_easy_setopt

    mov rdi, [curl_handle]
    mov rsi, 10023
    mov rdx, accept_header
    call curl_easy_setopt

    cmp qword [rbp-128], 0
    je .no_body
    mov rdi, [curl_handle]
    mov rsi, 10023
    mov rdx, content_type
    call curl_easy_setopt
    mov rdi, [curl_handle]
    mov rsi, 10015
    mov rdx, [rbp-128]
    call curl_easy_setopt
    mov rdi, [curl_handle]
    mov rsi, 10025
    mov rdx, 1
    call curl_easy_setopt

.no_body:
    mov rdi, [curl_handle]
    mov rsi, 20011
    mov rdx, response_body
    call curl_easy_setopt

    mov rdi, [curl_handle]
    call curl_easy_perform
    mov rdi, [curl_handle]
    call curl_easy_cleanup
    mov qword [curl_handle], 0
    leave
    ret

get_ref:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], rdi   ; token
    mov [rbp-16], rsi  ; owner
    mov [rbp-24], rdx  ; repo
    mov [rbp-32], rcx  ; branch

    mov rdi, tmp_str
    mov rsi, git_ref_heads
    call strcpy
    mov rdi, tmp_str
    call strlen
    mov rdi, tmp_str
    add rdi, rax
    mov rsi, [rbp-32]
    call strcpy

    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    mov rdx, [rbp-24]
    mov rcx, tmp_str
    mov r8, method_get
    xor r9, r9
    call github_request

    mov rdi, response_body
    call json_loads
    mov rbx, rax
    mov rdi, rbx
    mov rsi, json_object
    call json_object_get
    mov rdi, rax
    mov rsi, json_sha
    call json_object_get
    mov rdi, rax
    call json_string_value
    mov rdi, rax
    call strdup
    push rax
    mov rdi, rbx
    call json_decref
    pop rax
    leave
    ret

get_tree_sha:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov [rbp-24], rdx
    mov [rbp-32], rcx

    mov rdi, tmp_str
    mov rsi, git_commits
    call strcpy
    mov rdi, tmp_str
    call strlen
    mov rdi, tmp_str
    add rdi, rax
    mov rsi, [rbp-32]
    call strcpy

    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    mov rdx, [rbp-24]
    mov rcx, tmp_str
    mov r8, method_get
    xor r9, r9
    call github_request

    mov rdi, response_body
    call json_loads
    mov rbx, rax
    mov rdi, rbx
    mov rsi, json_tree
    call json_object_get
    mov rdi, rax
    mov rsi, json_sha
    call json_object_get
    mov rdi, rax
    call json_string_value
    mov rdi, rax
    call strdup
    push rax
    mov rdi, rbx
    call json_decref
    pop rax
    leave
    ret

create_blob:
    push rbp
    mov rbp, rsp
    sub rsp, 48
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov [rbp-24], rdx
    mov [rbp-32], rcx   ; content buffer
    mov rsi, [rbp-32]
    call strlen
    mov [rbp-40], rax

    mov rdi, json_object
    call json_object
    mov rbx, rax

    mov rdi, [rbp-32]
    call base64_encode
    mov rsi, rax
    mov rdi, json_string
    call json_string
    mov rsi, rax
    mov rdi, rbx
    mov rdx, json_content
    call json_object_set_new

    mov rdi, json_string
    mov rsi, json_base64
    call json_string
    mov rsi, rax
    mov rdi, rbx
    mov rdx, json_encoding
    call json_object_set_new

    mov rdi, rbx
    call json_dumps
    mov r9, rax

    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    mov rdx, [rbp-24]
    mov rcx, git_blobs
    mov r8, method_post
    call github_request

    mov rdi, response_body
    call json_loads
    mov rbx, rax
    mov rdi, rbx
    mov rsi, json_sha
    call json_object_get
    mov rdi, rax
    call json_string_value
    mov rdi, rax
    call strdup
    push rax
    mov rdi, rbx
    call json_decref
    pop rax
    leave
    ret

base64_encode:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], rdi
    mov rdi, [rbp-8]
    call strlen
    mov [rbp-16], rax
    mov rdi, [rbp-16]
    shl rdi, 2
    shr rdi, 1
    add rdi, 4
    call malloc
    mov [rbp-24], rax
    mov rdi, [rbp-24]
    mov rsi, [rbp-8]
    mov rdx, [rbp-16]
    call __b64_encode
    mov rax, [rbp-24]
    leave
    ret

__b64_encode:
    push rbp
    mov rbp, rsp
    mov rsi, rsi
    mov rdx, rdx
    mov rcx, rdi
    mov rax, rdx
    shr rax, 2
    mov r8, 0
    mov r9, 0
.loop:
    cmp r9, rdx
    jge .done
    movzx r10, byte [rsi+r9]
    inc r9
    movzx r11, byte [rsi+r9]
    inc r9
    movzx r12, byte [rsi+r9]
    inc r9
    mov r13, r10
    shr r13, 2
    and r13, 0x3f
    mov r14, r10
    shl r14, 4
    mov r15, r11
    shr r15, 4
    and r15, 0x0f
    or r14, r15
    mov r15, r11
    shl r15, 2
    mov rbx, r12
    shr rbx, 6
    and rbx, 0x03
    or r15, rbx
    mov rbx, r12
    and rbx, 0x3f
    mov byte [rcx+r8], b64_table[r13]
    inc r8
    mov byte [rcx+r8], b64_table[r14]
    inc r8
    mov byte [rcx+r8], b64_table[r15]
    inc r8
    mov byte [rcx+r8], b64_table[rbx]
    inc r8
    jmp .loop
.done:
    mov byte [rcx+r8], 0
    pop rbp
    ret

b64_table db "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"

create_tree:
    push rbp
    mov rbp, rsp
    sub rsp, 64
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov [rbp-24], rdx
    mov [rbp-32], rcx
    mov [rbp-40], r8   ; base_tree
    mov [rbp-48], r9   ; entries array

    mov rdi, json_object
    call json_object
    mov rbx, rax

    mov rdi, json_string
    mov rsi, [rbp-40]
    call json_string
    mov rsi, rax
    mov rdi, rbx
    mov rdx, json_base_tree
    call json_object_set_new

    mov rdi, json_array
    call json_array
    mov r12, rax
    mov r13, [rbp-48]
.loop_entries:
    cmp qword [r13], 0
    je .done_entries
    mov rdi, json_object
    call json_object
    mov r14, rax
    mov rdi, json_string
    mov rsi, [r13]
    call json_string
    mov rsi, rax
    mov rdi, r14
    mov rdx, json_path
    call json_object_set_new
    add r13, 8
    mov rdi, json_string
    mov rsi, [r13]
    call json_string
    mov rsi, rax
    mov rdi, r14
    mov rdx, json_mode
    call json_object_set_new
    add r13, 8
    mov rdi, json_string
    mov rsi, [r13]
    call json_string
    mov rsi, rax
    mov rdi, r14
    mov rdx, json_type
    call json_object_set_new
    add r13, 8
    mov rdi, json_string
    mov rsi, [r13]
    call json_string
    mov rsi, rax
    mov rdi, r14
    mov rdx, json_sha
    call json_object_set_new
    add r13, 8
    mov rdi, r12
    mov rsi, r14
    call json_array_append_new
    jmp .loop_entries
.done_entries:
    mov rsi, r12
    mov rdi, rbx
    mov rdx, json_tree
    call json_object_set_new

    mov rdi, rbx
    call json_dumps
    mov r9, rax

    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    mov rdx, [rbp-24]
    mov rcx, git_trees
    mov r8, method_post
    call github_request

    mov rdi, response_body
    call json_loads
    mov rbx, rax
    mov rdi, rbx
    mov rsi, json_sha
    call json_object_get
    mov rdi, rax
    call json_string_value
    mov rdi, rax
    call strdup
    push rax
    mov rdi, rbx
    call json_decref
    pop rax
    leave
    ret

create_commit:
    push rbp
    mov rbp, rsp
    sub rsp, 64
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov [rbp-24], rdx
    mov [rbp-32], rcx
    mov [rbp-40], r8   ; parent
    mov [rbp-48], r9   ; tree
    mov r10, [rbp+16]  ; message

    mov rdi, json_object
    call json_object
    mov rbx, rax

    mov rdi, json_string
    mov rsi, r10
    call json_string
    mov rsi, rax
    mov rdi, rbx
    mov rdx, json_message
    call json_object_set_new

    mov rdi, json_string
    mov rsi, [rbp-48]
    call json_string
    mov rsi, rax
    mov rdi, rbx
    mov rdx, json_tree
    call json_object_set_new

    mov rdi, json_array
    call json_array
    mov r12, rax
    mov rdi, json_string
    mov rsi, [rbp-40]
    call json_string
    mov rsi, rax
    mov rdi, r12
    call json_array_append_new
    mov rsi, r12
    mov rdi, rbx
    mov rdx, json_parents
    call json_object_set_new

    mov rdi, rbx
    call json_dumps
    mov r9, rax

    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    mov rdx, [rbp-24]
    mov rcx, git_commits_post
    mov r8, method_post
    call github_request

    mov rdi, response_body
    call json_loads
    mov rbx, rax
    mov rdi, rbx
    mov rsi, json_sha
    call json_object_get
    mov rdi, rax
    call json_string_value
    mov rdi, rax
    call strdup
    push rax
    mov rdi, rbx
    call json_decref
    pop rax
    leave
    ret

update_ref:
    push rbp
    mov rbp, rsp
    sub rsp, 64
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov [rbp-24], rdx
    mov [rbp-32], rcx
    mov [rbp-40], r8   ; commit_sha

    mov rdi, tmp_str
    mov rsi, git_refs_patch
    call strcpy
    mov rdi, tmp_str
    call strlen
    mov rdi, tmp_str
    add rdi, rax
    mov rsi, [rbp-32]
    call strcpy

    mov rdi, json_object
    call json_object
    mov rbx, rax
    mov rdi, json_string
    mov rsi, [rbp-40]
    call json_string
    mov rsi, rax
    mov rdi, rbx
    mov rdx, json_sha
    call json_object_set_new
    mov rdi, json_boolean
    mov rsi, 0
    call json_boolean
    mov rsi, rax
    mov rdi, rbx
    mov rdx, json_force
    call json_object_set_new

    mov rdi, rbx
    call json_dumps
    mov r9, rax

    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    mov rdx, [rbp-24]
    mov rcx, tmp_str
    mov r8, method_patch
    call github_request
    leave
    ret

init_repo:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov [rbp-24], rdx
    mov [rbp-32], rcx

    mov rdi, init_readme
    call strlen
    mov rsi, rax
    mov rdi, init_readme
    call base64_encode
    mov r12, rax

    mov rdi, json_object
    call json_object
    mov rbx, rax
    mov rdi, json_string
    mov rsi, init_commit_msg
    call json_string
    mov rsi, rax
    mov rdi, rbx
    mov rdx, json_message
    call json_object_set_new
    mov rdi, json_string
    mov rsi, r12
    call json_string
    mov rsi, rax
    mov rdi, rbx
    mov rdx, json_content
    call json_object_set_new
    mov rdi, json_string
    mov rsi, [rbp-32]
    call json_string
    mov rsi, rax
    mov rdi, rbx
    mov rdx, json_branch
    call json_object_set_new

    mov rdi, rbx
    call json_dumps
    mov r9, rax

    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    mov rdx, [rbp-24]
    mov rcx, contents_readme
    mov r8, method_put
    call github_request
    leave
    ret

main:
    push rbp
    mov rbp, rsp
    sub rsp, 4096

    mov rdi, header_line
    call printf

    mov rdi, prompt_token
    mov rsi, token
    call read_input
    cmp byte [token], 0
    jne .have_token
    mov rdi, token_required
    mov sil, 'e'
    call log_message
    mov rdi, 1
    call exit
.have_token:

    mov rdi, prompt_owner
    mov rsi, owner
    call read_input
    cmp byte [owner], 0
    jne .have_owner
    mov rdi, owner_required
    mov sil, 'e'
    call log_message
    mov rdi, 1
    call exit
.have_owner:

    mov rdi, prompt_repo
    mov rsi, repo
    call read_input
    cmp byte [repo], 0
    jne .have_repo
    mov rdi, repo_required
    mov sil, 'e'
    call log_message
    mov rdi, 1
    call exit
.have_repo:

    mov rdi, prompt_branch
    mov rsi, branch
    call read_input
    cmp byte [branch], 0
    jne .have_branch
    mov rsi, default_branch
    mov rdi, branch
    call strcpy
.have_branch:

.zip_loop:
    mov rdi, prompt_zip
    mov rsi, zip_path
    call read_input
    cmp byte [zip_path], 0
    je .zip_loop
    mov rdi, zip_path
    mov rsi, 'r'
    call fopen
    cmp rax, 0
    jne .zip_ok
    mov rdi, file_not_found
    mov sil, 'e'
    call log_message
    jmp .zip_loop
.zip_ok:
    mov rdi, rax
    call fclose

    mov rdi, token
    mov rsi, owner
    mov rdx, repo
    mov rcx, branch
    call build_target_log
    mov rdi, tmp_str
    mov sil, 'i'
    call log_message

    mov rdi, zip_path
    mov rsi, tmp_str
    call build_zip_log
    mov rdi, tmp_str
    mov sil, 'i'
    call log_message

    mov rdi, reading_zip
    mov sil, 'i'
    call log_message

    mov rdi, zip_path
    mov rsi, 0
    call zip_open
    cmp rax, 0
    je .zip_error
    mov [zip_handle], rax

    mov rdi, [zip_handle]
    call zip_get_num_entries
    mov r15, rax
    xor r14, r14
    xor r13, r13
.file_loop:
    cmp r14, r15
    jge .file_loop_done
    mov rdi, [zip_handle]
    mov rsi, r14
    mov rdx, 0
    call zip_get_name
    mov r12, rax
    mov rdi, r12
    call strlen
    mov r11, rax
    cmp byte [r12+rax-1], '/'
    je .skip_file
    mov rdi, r12
    mov rsi, __MACOSX
    call strstr
    cmp rax, 0
    jne .skip_file
    mov rdi, r12
    mov rsi, ds_store
    call strstr
    cmp rax, 0
    jne .skip_file
    inc r13
.skip_file:
    inc r14
    jmp .file_loop
.file_loop_done:
    mov [total_files], r13
    mov rdi, found_files_msg
    call printf
    mov rdi, [total_files]
    mov rsi, int_buf
    call sprint_int
    mov rdi, int_buf
    call printf
    mov rdi, valid_files_msg
    call printf
    mov rdi, 0x0a
    call putchar

    mov rdi, token
    mov rsi, owner
    mov rdx, repo
    mov rcx, branch
    call get_initial_refs
    cmp rax, 0
    je .init_repo
    mov [latest_commit_sha], rax
    mov rdi, token
    mov rsi, owner
    mov rdx, repo
    mov rcx, [latest_commit_sha]
    call get_tree_sha
    mov [base_tree_sha], rax
    jmp .upload_blobs
.init_repo:
    mov rdi, branch
    mov rsi, tmp_str
    call sprintf_branch_warn
    mov rdi, tmp_str
    mov sil, 'w'
    call log_message
    mov rdi, token
    mov rsi, owner
    mov rdx, repo
    mov rcx, branch
    call init_repo
    mov rdi, init_success
    mov sil, 's'
    call log_message
    mov rdi, token
    mov rsi, owner
    mov rdx, repo
    mov rcx, branch
    call get_ref
    mov [latest_commit_sha], rax
    mov rdi, token
    mov rsi, owner
    mov rdx, repo
    mov rcx, [latest_commit_sha]
    call get_tree_sha
    mov [base_tree_sha], rax

.upload_blobs:
    mov rdi, uploading_blobs
    mov sil, 'i'
    call log_message
    mov rdi, token
    mov rsi, owner
    mov rdx, repo
    mov rcx, [total_files]
    call upload_all_blobs
    mov r12, rax   ; tree_entries array pointer

    mov rdi, constructing_tree
    mov sil, 'i'
    call log_message
    mov rdi, token
    mov rsi, owner
    mov rdx, repo
    mov rcx, [base_tree_sha]
    mov r8, r12
    call create_tree
    mov r13, rax   ; new_tree_sha

    mov rdi, creating_commit
    mov sil, 'i'
    call log_message
    mov rdi, token
    mov rsi, owner
    mov rdx, repo
    mov rcx, [latest_commit_sha]
    mov r8, r13
    mov r9, commit_msg_prefix
    mov r10, [total_files]
    call build_commit_message
    push rax
    mov r9, [rbp-8]
    call create_commit
    mov r14, rax   ; new_commit_sha
    add rsp, 8

    mov rdi, updating_ref
    mov sil, 'i'
    call log_message
    mov rdi, token
    mov rsi, owner
    mov rdx, repo
    mov rcx, branch
    mov r8, r14
    call update_ref

    mov rdi, deploy_complete
    mov rsi, [total_files]
    mov rdx, owner
    mov rcx, repo
    mov r8, branch
    call printf
    mov rdi, 0x0a
    call putchar
    mov rdi, deploy_url_fmt
    mov rsi, owner
    mov rdx, repo
    mov rcx, branch
    call printf
    mov rdi, 0x0a
    call putchar
    jmp .exit

.zip_error:
    mov rdi, zip_read_error
    mov sil, 'e'
    call log_message
    mov rdi, 1
    call exit

.exit:
    xor rdi, rdi
    call exit

build_target_log:
    push rbp
    mov rbp, rsp
    mov rdi, tmp_str
    mov rsi, fmt_target
    mov rdx, [rbp+16]
    mov rcx, [rbp+24]
    mov r8, [rbp+32]
    call sprintf
    leave
    ret

fmt_target db "Target: %s/%s on branch '%s'", 0

build_zip_log:
    push rbp
    mov rbp, rsp
    mov rdi, tmp_str
    mov rsi, fmt_zip
    mov rdx, [rbp+16]
    call sprintf
    leave
    ret

fmt_zip db "ZIP file: %s", 0

sprint_int:
    push rbp
    mov rbp, rsp
    mov rdi, rsi
    mov rax, rdi
    mov rcx, 10
    mov rbx, rsi
    add rbx, 10
    mov byte [rbx], 0
.loop:
    xor rdx, rdx
    div rcx
    add dl, '0'
    dec rbx
    mov [rbx], dl
    test rax, rax
    jnz .loop
    mov rsi, rbx
    mov rdi, rdi
    call strcpy
    leave
    ret

sprintf_branch_warn:
    push rbp
    mov rbp, rsp
    mov rdi, tmp_str
    mov rsi, init_attempt
    mov rdx, [rbp+16]
    call sprintf
    leave
    ret

upload_all_blobs:
    push rbp
    mov rbp, rsp
    sub rsp, 256
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov [rbp-24], rdx
    mov [rbp-32], rcx   ; total
    mov rdi, [zip_handle]
    call zip_get_num_entries
    mov r14, rax
    xor r13, r13   ; file index
    xor r12, r12   ; valid index
    mov r15, 0     ; tree entries array pointer (malloc later)
    mov rdi, 8
    imul rdi, [rbp-32]
    call malloc
    mov r15, rax
    mov [rbp-40], r15
    mov r11, r15   ; current entry pointer
    xor r10, r10   ; uploaded count
.blob_loop:
    cmp r13, r14
    jge .blob_done
    mov rdi, [zip_handle]
    mov rsi, r13
    mov rdx, 0
    call zip_get_name
    mov rbx, rax
    mov rdi, rbx
    call strlen
    cmp byte [rbx+rax-1], '/'
    je .skip_blob
    mov rdi, rbx
    mov rsi, __MACOSX
    call strstr
    cmp rax, 0
    jne .skip_blob
    mov rdi, rbx
    mov rsi, ds_store
    call strstr
    cmp rax, 0
    jne .skip_blob
    mov rdi, [zip_handle]
    mov rsi, r13
    mov rdx, 0
    call zip_fopen
    mov r12, rax
    mov rdi, content_buf
    mov rsi, 1
    mov rdx, 1048576
    mov rcx, r12
    call fread
    push rax
    mov rdi, r12
    call zip_fclose
    pop rcx
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    mov rdx, [rbp-24]
    mov r8, content_buf
    call create_blob
    mov [r11], rbx      ; path
    add r11, 8
    mov [r11], mode_644
    add r11, 8
    mov [r11], json_blob
    add r11, 8
    mov [r11], rax      ; sha
    add r11, 8
    inc r10
    mov rdi, upload_progress
    mov rsi, r10
    mov rdx, [rbp-32]
    call printf
    mov rdi, 0x0a
    call putchar
.skip_blob:
    inc r13
    jmp .blob_loop
.blob_done:
    mov rax, [rbp-40]
    leave
    ret

build_commit_message:
    push rbp
    mov rbp, rsp
    sub rsp, 256
    mov rdi, tmp_str
    mov rsi, commit_msg_prefix
    call strcpy
    mov rdi, tmp_str
    call strlen
    mov rdi, tmp_str
    add rdi, rax
    mov rsi, r10
    call sprint_int
    mov rdi, tmp_str
    call strlen
    mov rdi, tmp_str
    add rdi, rax
    mov rsi, commit_msg_suffix
    call strcpy
    mov rdi, tmp_str
    call strdup
    leave
    ret

get_initial_refs:
    push rbp
    mov rbp, rsp
    sub rsp, 32
    mov [rbp-8], rdi
    mov [rbp-16], rsi
    mov [rbp-24], rdx
    mov [rbp-32], rcx
    mov rdi, [rbp-8]
    mov rsi, [rbp-16]
    mov rdx, [rbp-24]
    mov rcx, [rbp-32]
    call get_ref
    cmp rax, 0
    je .error
    mov rdi, rax
    mov rsi, [rbp-8]
    mov rdx, [rbp-16]
    mov rcx, [rbp-24]
    call get_tree_sha
    cmp rax, 0
    je .error
    mov rax, [rbp-8]  ; dummy non-zero
    leave
    ret
.error:
    xor rax, rax
    leave
    ret

section .data
__MACOSX db "__MACOSX", 0
ds_store db ".DS_Store", 0
json_force db "force", 0
json_branch db "branch", 0