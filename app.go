package main

import (
	"archive/zip"
	"bufio"
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type GitHubAPI struct {
	token string
	owner string
	repo  string
}

type GitBlob struct {
	SHA string `json:"sha"`
}

type GitTreeEntry struct {
	Path string `json:"path"`
	Mode string `json:"mode"`
	Type string `json:"type"`
	SHA  string `json:"sha"`
}

type GitTree struct {
	SHA       string          `json:"sha"`
	Tree      []GitTreeEntry  `json:"tree"`
	BaseTree  string          `json:"base_tree,omitempty"`
}

type GitCommit struct {
	SHA      string `json:"sha"`
	Tree     struct{ SHA string } `json:"tree"`
	Parents  []struct{ SHA string } `json:"parents"`
}

type GitRef struct {
	Object struct {
		SHA string `json:"sha"`
	} `json:"object"`
}

type ContentPut struct {
	Message string `json:"message"`
	Content string `json:"content"`
	Branch  string `json:"branch"`
}

func (g *GitHubAPI) request(method, endpoint string, body interface{}) (*http.Response, error) {
	url := fmt.Sprintf("https://api.github.com/repos/%s/%s%s", g.owner, g.repo, endpoint)
	var bodyReader io.Reader
	if body != nil {
		jsonData, err := json.Marshal(body)
		if err != nil {
			return nil, err
		}
		bodyReader = bytes.NewReader(jsonData)
	}
	req, err := http.NewRequest(method, url, bodyReader)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+g.token)
	req.Header.Set("Accept", "application/vnd.github.v3+json")
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	client := &http.Client{Timeout: 30 * time.Second}
	return client.Do(req)
}

func (g *GitHubAPI) do(method, endpoint string, body interface{}, result interface{}) error {
	resp, err := g.request(method, endpoint, body)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		bodyBytes, _ := io.ReadAll(resp.Body)
		return fmt.Errorf("HTTP %d: %s", resp.StatusCode, string(bodyBytes))
	}
	if result != nil && resp.StatusCode != http.StatusNoContent {
		return json.NewDecoder(resp.Body).Decode(result)
	}
	return nil
}

func (g *GitHubAPI) getRef(branch string) (string, error) {
	var ref GitRef
	err := g.do("GET", fmt.Sprintf("/git/ref/heads/%s", branch), nil, &ref)
	if err != nil {
		return "", err
	}
	return ref.Object.SHA, nil
}

func (g *GitHubAPI) getCommit(sha string) (string, error) {
	var commit GitCommit
	err := g.do("GET", fmt.Sprintf("/git/commits/%s", sha), nil, &commit)
	if err != nil {
		return "", err
	}
	return commit.Tree.SHA, nil
}

func (g *GitHubAPI) createBlob(content []byte) (string, error) {
	encoded := base64.StdEncoding.EncodeToString(content)
	body := map[string]string{
		"content":  encoded,
		"encoding": "base64",
	}
	var blob GitBlob
	err := g.do("POST", "/git/blobs", body, &blob)
	if err != nil {
		return "", err
	}
	return blob.SHA, nil
}

func (g *GitHubAPI) createTree(baseTree string, entries []GitTreeEntry) (string, error) {
	body := GitTree{
		BaseTree: baseTree,
		Tree:     entries,
	}
	var tree GitTree
	err := g.do("POST", "/git/trees", body, &tree)
	if err != nil {
		return "", err
	}
	return tree.SHA, nil
}

func (g *GitHubAPI) createCommit(parent, tree, message string) (string, error) {
	body := map[string]interface{}{
		"message": message,
		"tree":    tree,
		"parents": []string{parent},
	}
	var commit GitCommit
	err := g.do("POST", "/git/commits", body, &commit)
	if err != nil {
		return "", err
	}
	return commit.SHA, nil
}

func (g *GitHubAPI) updateRef(branch, commitSHA string) error {
	body := map[string]string{
		"sha":   commitSHA,
		"force": "false",
	}
	return g.do("PATCH", fmt.Sprintf("/git/refs/heads/%s", branch), body, nil)
}

func (g *GitHubAPI) initRepo(branch string) error {
	readmeContent := base64.StdEncoding.EncodeToString([]byte("# Project Repository\nInitialized automatically by GitHub ZIP Deployer."))
	body := ContentPut{
		Message: "Initial commit by GitHub ZIP Deployer",
		Content: readmeContent,
		Branch:  branch,
	}
	return g.do("PUT", "/contents/README.md", body, nil)
}

func logMessage(msg string, level string) {
	now := time.Now().Format("15:04:05")
	var color, icon string
	switch level {
	case "error":
		color = "\033[31m"
		icon = "✖"
	case "success":
		color = "\033[32m"
		icon = "✓"
	case "warn":
		color = "\033[33m"
		icon = "⚠"
	default:
		color = "\033[36m"
		icon = "➜"
	}
	fmt.Printf("\033[90m[%s]\033[0m %s%s %s\033[0m\n", now, color, icon, msg)
}

func readInput(prompt string, secret bool) string {
	fmt.Print(prompt)
	if secret {
		bytePassword, _ := terminalReadPassword()
		return strings.TrimSpace(string(bytePassword))
	}
	scanner := bufio.NewScanner(os.Stdin)
	scanner.Scan()
	return strings.TrimSpace(scanner.Text())
}

func terminalReadPassword() ([]byte, error) {
	return []byte(readInput("", false)), nil
}

func main() {
	fmt.Printf("\n\033[36m\033[1m🚀 GitHub ZIP Deployer — Tool by Icii White\033[0m\n\n")
	token := readInput("\033[33m🔑 Personal Access Token (repo scope): \033[0m", true)
	for token == "" {
		token = readInput("\033[31mToken is required: \033[0m", true)
	}
	owner := readInput("\033[33m👤 Repository owner (username or org): \033[0m", false)
	for owner == "" {
		owner = readInput("\033[31mOwner is required: \033[0m", false)
	}
	repo := readInput("\033[33m📁 Repository name: \033[0m", false)
	for repo == "" {
		repo = readInput("\033[31mRepository name is required: \033[0m", false)
	}
	branch := readInput("\033[33m🌿 Branch name (default: main): \033[0m", false)
	if branch == "" {
		branch = "main"
	}
	zipPath := readInput("\033[33m🗂️  Path to ZIP file: \033[0m", false)
	for zipPath == "" {
		zipPath = readInput("\033[31mZIP file path required: \033[0m", false)
	}
	for {
		if _, err := os.Stat(zipPath); err == nil {
			break
		}
		zipPath = readInput("\033[31mFile not found. Enter a valid ZIP path: \033[0m", false)
	}
	logMessage(fmt.Sprintf("Target: %s/%s on branch '%s'", owner, repo, branch), "info")
	logMessage(fmt.Sprintf("ZIP file: %s", zipPath), "info")
	zipData, err := os.ReadFile(zipPath)
	if err != nil {
		logMessage(fmt.Sprintf("Cannot read ZIP file: %v", err), "error")
		os.Exit(1)
	}
	logMessage("Reading ZIP file in memory...", "info")
	validFiles := make([]struct {
		path string
		data []byte
	}, 0)
	zipReader, err := zip.NewReader(bytes.NewReader(zipData), int64(len(zipData)))
	if err != nil {
		logMessage(fmt.Sprintf("Invalid ZIP: %v", err), "error")
		os.Exit(1)
	}
	for _, f := range zipReader.File {
		if f.FileInfo().IsDir() {
			continue
		}
		if strings.Contains(f.Name, "__MACOSX") || strings.Contains(f.Name, ".DS_Store") {
			continue
		}
		rc, err := f.Open()
		if err != nil {
			continue
		}
		content, err := io.ReadAll(rc)
		rc.Close()
		if err != nil {
			continue
		}
		validFiles = append(validFiles, struct {
			path string
			data []byte
		}{f.Name, content})
	}
	logMessage(fmt.Sprintf("Found %d valid files to process.", len(validFiles)), "info")
	api := &GitHubAPI{token: token, owner: owner, repo: repo}
	var latestCommitSHA, baseTreeSHA string
	logMessage(fmt.Sprintf("Fetching branch '%s' details...", branch), "info")
	refSHA, err := api.getRef(branch)
	if err != nil {
		logMessage(fmt.Sprintf("Branch '%s' not found or repository empty. Attempting initialization...", branch), "warn")
		if err := api.initRepo(branch); err != nil {
			logMessage(fmt.Sprintf("Failed to initialize empty repository: %v", err), "error")
			os.Exit(1)
		}
		logMessage("Successfully initialized repository with README.md", "success")
		refSHA, err = api.getRef(branch)
		if err != nil {
			logMessage(fmt.Sprintf("Cannot fetch branch after init: %v", err), "error")
			os.Exit(1)
		}
	}
	latestCommitSHA = refSHA
	treeSHA, err := api.getCommit(latestCommitSHA)
	if err != nil {
		logMessage(fmt.Sprintf("Cannot get commit tree: %v", err), "error")
		os.Exit(1)
	}
	baseTreeSHA = treeSHA
	logMessage("Uploading files as blobs...", "info")
	var wg sync.WaitGroup
	var mu sync.Mutex
	treeEntries := make([]GitTreeEntry, 0)
	batchSize := 10
	total := len(validFiles)
	for i := 0; i < total; i += batchSize {
		end := i + batchSize
		if end > total {
			end = total
		}
		batch := validFiles[i:end]
		var batchEntries []GitTreeEntry
		var batchWg sync.WaitGroup
		var batchMu sync.Mutex
		for _, file := range batch {
			batchWg.Add(1)
			go func(f struct{ path string; data []byte }) {
				defer batchWg.Done()
				sha, err := api.createBlob(f.data)
				if err != nil {
					return
				}
				batchMu.Lock()
				batchEntries = append(batchEntries, GitTreeEntry{
					Path: f.path,
					Mode: "100644",
					Type: "blob",
					SHA:  sha,
				})
				batchMu.Unlock()
			}(file)
		}
		batchWg.Wait()
		mu.Lock()
		treeEntries = append(treeEntries, batchEntries...)
		mu.Unlock()
		processed := i + len(batch)
		if processed > total {
			processed = total
		}
		logMessage(fmt.Sprintf("  -> Uploaded %d / %d files...", processed, total), "info")
	}
	logMessage("Constructing new Git tree...", "info")
	newTreeSHA, err := api.createTree(baseTreeSHA, treeEntries)
	if err != nil {
		logMessage(fmt.Sprintf("Tree creation failed: %v", err), "error")
		os.Exit(1)
	}
	logMessage("Creating commit...", "info")
	commitMsg := fmt.Sprintf("Upload ZIP deployment via Web Client\n\nUploaded %d files.", total)
	newCommitSHA, err := api.createCommit(latestCommitSHA, newTreeSHA, commitMsg)
	if err != nil {
		logMessage(fmt.Sprintf("Commit creation failed: %v", err), "error")
		os.Exit(1)
	}
	logMessage("Updating branch reference to new commit...", "info")
	if err := api.updateRef(branch, newCommitSHA); err != nil {
		logMessage(fmt.Sprintf("Branch update failed: %v", err), "error")
		os.Exit(1)
	}
	logMessage(fmt.Sprintf("Successfully deployed %d files to %s/%s on branch '%s'! 🎉", total, owner, repo, branch), "success")
	logMessage(fmt.Sprintf("https://github.com/%s/%s/tree/%s", owner, repo, branch), "info")
}