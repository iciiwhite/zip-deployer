# GitHub ZIP Deployer

A browser-based tool that extracts a ZIP archive and pushes its contents directly to a GitHub repository using the GitHub API. No server-side code is required—everything runs client-side.

## Features

- **Direct Upload** – Upload a ZIP file and have its contents automatically added to your repository.
- **GitHub Integration** – Uses the GitHub REST API to create blobs, build a tree, and commit changes.
- **Branch Support** – Specify any existing branch; if the branch does not exist, the tool initializes the repository with a placeholder README.
- **Real-Time Logging** – A live console window displays every step of the process, making it easy to track progress and debug issues.
- **Secure** – Your personal access token is never sent to a third‑party server; all API calls are made directly from your browser to GitHub.

## How It Works

1. **Authentication** – You provide a GitHub personal access token (classic or fine‑grained) with the `repo` scope.
2. **Repository Details** – Enter the repository owner, repository name, and target branch.
3. **ZIP Upload** – Select a ZIP file containing the project files you want to upload.
4. **Processing** – The tool:
   - Reads the ZIP file in memory.
   - Filters out unnecessary metadata (e.g., `__MACOSX` folder, `.DS_Store` files).
   - Fetches the current commit and tree for the target branch.
   - Uploads each file as a Git blob in batches.
   - Creates a new Git tree that includes the uploaded blobs.
   - Creates a commit that points to the new tree.
   - Updates the branch reference to the new commit.
5. **Result** – Your repository is updated with the exact contents of the ZIP file, preserving the directory structure.

## Requirements

- A GitHub account.
- A personal access token with at least the `repo` scope.  
  (Learn how to create one [here](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/managing-your-personal-access-tokens).)
- A modern web browser (JavaScript enabled).

## Usage

1. Clone or download this repository to your local machine, or simply open the provided HTML file in your browser.
2. Fill in the form:
   - **Personal Access Token** – Your GitHub token.
   - **Owner / Username** – The GitHub username or organization that owns the target repository.
   - **Repository Name** – The name of the repository where the files should be uploaded.
   - **Branch** – The branch to update (defaults to `main`).
3. Click the upload area to select a ZIP file, or drag and drop a ZIP file onto the area.
4. Click **Deploy to GitHub**.
5. Watch the log window for progress. On success, you will see a confirmation message.

## Important Notes

- **File Overwrites** – If a file with the same path already exists in the target branch, it will be replaced.
- **Empty Repositories** – If the repository is empty or the branch does not exist, the tool will automatically create an initial commit (with a basic `README.md`) to establish a commit history.
- **Large ZIP Files** – Processing time depends on the number and size of files. The tool uploads files in batches of ten to avoid rate limits, but very large archives may still take a while.
- **Browser Limitations** – All processing occurs in memory, so extremely large ZIP files may exceed the browser’s memory limit. For most projects (up to a few hundred MB) this should work fine.

## Troubleshooting

- **Authentication Errors** – Ensure your token has the `repo` scope and that you have write access to the repository.
- **“Branch not found”** – If the branch does not exist and the repository is empty, the tool attempts to create an initial commit. If the repository is not empty but the branch is missing, you will need to create the branch manually.
- **API Rate Limits** – Authenticated requests using a token have higher rate limits. The tool batches requests to reduce the chance of hitting limits, but if you are uploading many files in a short period, you may still be limited. Wait a few minutes and try again.

## Contributing

Contributions are welcome. Please open an issue or submit a pull request with your improvements.

## License

This project is licensed under the MIT License. See the LICENSE file for details.

## Disclaimer

This tool is provided “as is”, without warranty of any kind. Use it at your own risk. Always ensure you have backups of your repository before performing bulk operations.