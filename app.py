#!/usr/bin/env python3

import base64
import json
import sys
import zipfile
from concurrent.futures import ThreadPoolExecutor
from io import BytesIO
from pathlib import Path

try:
    import requests
except ImportError:
    print("Error: 'requests' library is required. Install with: pip install requests")
    sys.exit(1)

try:
    from colorama import init, Fore, Style
    init(autoreset=True)
    COLORS = True
except ImportError:
    COLORS = False
    Fore = Style = type('Mock', (), {'RESET_ALL': '', 'GREEN': '', 'RED': '', 'YELLOW': '', 'CYAN': ''})()

def log(message, level="info"):
    if level == "error":
        color = Fore.RED
        icon = "✖"
    elif level == "success":
        color = Fore.GREEN
        icon = "✓"
    elif level == "warn":
        color = Fore.YELLOW
        icon = "⚠"
    else:
        color = Fore.CYAN
        icon = "➜"
    timestamp = __import__('datetime').datetime.now().strftime("%H:%M:%S")
    print(f"{Style.DIM}[{timestamp}]{Style.RESET_ALL} {color}{icon} {message}{Style.RESET_ALL}")

def github_api(token, owner, repo, path, method="GET", data=None):
    url = f"https://api.github.com/repos/{owner}/{repo}{path}"
    headers = {
        "Authorization": f"Bearer {token}",
        "Accept": "application/vnd.github.v3+json",
        "Content-Type": "application/json"
    }
    kwargs = {"headers": headers}
    if data is not None:
        kwargs["json"] = data
    resp = requests.request(method, url, **kwargs)
    if not resp.ok:
        try:
            err = resp.json()
            msg = err.get("message", resp.text)
        except:
            msg = resp.text
        raise Exception(f"GitHub API error {resp.status_code}: {msg}")
    if resp.status_code == 204:
        return None
    return resp.json()

def main():
    print(f"\n{Fore.CYAN}{Style.BRIGHT}GitHub ZIP Deployer — Tool by Icii White{Style.RESET_ALL}\n")
    
    token = input(f"{Fore.YELLOW}🔑 Personal Access Token (repo scope): {Style.RESET_ALL}").strip()
    while not token:
        token = input(f"{Fore.RED}Token is required: {Style.RESET_ALL}").strip()
    
    owner = input(f"{Fore.YELLOW}👤 Repository owner (username or org): {Style.RESET_ALL}").strip()
    while not owner:
        owner = input(f"{Fore.RED}Owner is required: {Style.RESET_ALL}").strip()
    
    repo = input(f"{Fore.YELLOW}📁 Repository name: {Style.RESET_ALL}").strip()
    while not repo:
        repo = input(f"{Fore.RED}Repository name is required: {Style.RESET_ALL}").strip()
    
    branch = input(f"{Fore.YELLOW}🌿 Branch name (default: main): {Style.RESET_ALL}").strip()
    if not branch:
        branch = "main"
    
    zip_path = input(f"{Fore.YELLOW}🗂️  Path to ZIP file: {Style.RESET_ALL}").strip()
    while not zip_path or not Path(zip_path).is_file():
        if not zip_path:
            zip_path = input(f"{Fore.RED}ZIP file path required: {Style.RESET_ALL}").strip()
        else:
            zip_path = input(f"{Fore.RED}File not found. Enter a valid ZIP path: {Style.RESET_ALL}").strip()
    
    log(f"Target: {owner}/{repo} on branch '{branch}'")
    log(f"ZIP file: {zip_path}")
    
    try:
        with open(zip_path, "rb") as f:
            zip_data = f.read()
    except Exception as e:
        log(f"Cannot read ZIP file: {e}", "error")
        sys.exit(1)
    
    log("Reading ZIP file in memory...")
    valid_files = []
    with zipfile.ZipFile(BytesIO(zip_data)) as zf:
        for info in zf.infolist():
            if info.is_dir():
                continue
            path = info.filename
            if "__MACOSX" in path or ".DS_Store" in path:
                continue
            valid_files.append((path, zf.read(info)))
    log(f"Found {len(valid_files)} valid files to process.")
    
    def api_call(path, method="GET", data=None):
        return github_api(token, owner, repo, path, method, data)
    
    try:
        log(f"Fetching branch '{branch}' details...")
        ref_data = api_call(f"/git/ref/heads/{branch}")
        latest_commit_sha = ref_data["object"]["sha"]
        commit_data = api_call(f"/git/commits/{latest_commit_sha}")
        base_tree_sha = commit_data["tree"]["sha"]
    except Exception as e:
        log(f"Branch '{branch}' not found or repository empty. Attempting initialization...", "warn")
        try:
            readme_content = base64.b64encode(b"# Project Repository\nInitialized automatically by GitHub ZIP Deployer.").decode()
            api_call("/contents/README.md", "PUT", {
                "message": "Initial commit by GitHub ZIP Deployer",
                "content": readme_content,
                "branch": branch
            })
            log("Successfully initialized repository with README.md", "success")
            ref_data = api_call(f"/git/ref/heads/{branch}")
            latest_commit_sha = ref_data["object"]["sha"]
            commit_data = api_call(f"/git/commits/{latest_commit_sha}")
            base_tree_sha = commit_data["tree"]["sha"]
        except Exception as init_err:
            raise Exception(f"Failed to initialize empty repository: {init_err}")
    
    log("Uploading files as blobs...")
    tree_entries = []
    batch_size = 10
    total = len(valid_files)
    
    for i in range(0, total, batch_size):
        batch = valid_files[i:i+batch_size]
        def upload_one(file_path, content_bytes):
            content_b64 = base64.b64encode(content_bytes).decode()
            blob = api_call("/git/blobs", "POST", {"content": content_b64, "encoding": "base64"})
            return {
                "path": file_path,
                "mode": "100644",
                "type": "blob",
                "sha": blob["sha"]
            }
        with ThreadPoolExecutor(max_workers=len(batch)) as executor:
            futures = [executor.submit(upload_one, path, data) for path, data in batch]
            for future in futures:
                tree_entries.append(future.result())
        processed = min(i + batch_size, total)
        log(f"  -> Uploaded {processed} / {total} files...")
    
    log("Constructing new Git tree...")
    new_tree = api_call("/git/trees", "POST", {
        "base_tree": base_tree_sha,
        "tree": tree_entries
    })
    
    log("Creating commit...")
    commit_msg = f"Upload ZIP deployment via Web Client\n\nUploaded {total} files."
    new_commit = api_call("/git/commits", "POST", {
        "message": commit_msg,
        "tree": new_tree["sha"],
        "parents": [latest_commit_sha]
    })
    
    log("Updating branch reference to new commit...")
    api_call(f"/git/refs/heads/{branch}", "PATCH", {"sha": new_commit["sha"], "force": False})
    
    log(f"Successfully deployed {total} files to {owner}/{repo} on branch '{branch}'! 🎉", "success")
    log(f"https://github.com/{owner}/{repo}/tree/{branch}", "info")

if __name__ == "__main__":
    main()