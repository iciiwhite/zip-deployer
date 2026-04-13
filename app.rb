#!/usr/bin/env ruby

require 'json'
require 'net/http'
require 'base64'
require 'zip'
require 'uri'
require 'find'

def log(message, level = :info)
  time = Time.now.strftime("%H:%M:%S")
  color, icon = case level
                when :error then ["\033[31m", "✖"]
                when :success then ["\033[32m", "✓"]
                when :warn then ["\033[33m", "⚠"]
                else ["\033[36m", "➜"]
                end
  puts "\033[90m[#{time}]\033[0m #{color}#{icon} #{message}\033[0m"
end

def github_api(token, owner, repo, endpoint, method = :get, body = nil)
  uri = URI.parse("https://api.github.com/repos/#{owner}/#{repo}#{endpoint}")
  http = Net::HTTP.new(uri.host, uri.port)
  http.use_ssl = true
  http.read_timeout = 30

  request = case method
            when :get then Net::HTTP::Get.new(uri)
            when :post then Net::HTTP::Post.new(uri)
            when :put then Net::HTTP::Put.new(uri)
            when :patch then Net::HTTP::Patch.new(uri)
            end

  request["Authorization"] = "Bearer #{token}"
  request["Accept"] = "application/vnd.github.v3+json"
  request["Content-Type"] = "application/json"
  request.body = JSON.dump(body) if body

  response = http.request(request)

  unless response.code.to_i.between?(200, 204)
    raise "HTTP #{response.code}: #{response.body}"
  end
  return nil if response.code == "204"
  JSON.parse(response.body)
end

def get_ref(token, owner, repo, branch)
  data = github_api(token, owner, repo, "/git/ref/heads/#{branch}")
  data["object"]["sha"]
end

def get_tree_sha(token, owner, repo, commit_sha)
  data = github_api(token, owner, repo, "/git/commits/#{commit_sha}")
  data["tree"]["sha"]
end

def create_blob(token, owner, repo, content)
  data = github_api(token, owner, repo, "/git/blobs", :post, {
    content: Base64.strict_encode64(content),
    encoding: "base64"
  })
  data["sha"]
end

def create_tree(token, owner, repo, base_tree, tree_entries)
  data = github_api(token, owner, repo, "/git/trees", :post, {
    base_tree: base_tree,
    tree: tree_entries
  })
  data["sha"]
end

def create_commit(token, owner, repo, parent, tree, message)
  data = github_api(token, owner, repo, "/git/commits", :post, {
    message: message,
    tree: tree,
    parents: [parent]
  })
  data["sha"]
end

def update_ref(token, owner, repo, branch, commit_sha)
  github_api(token, owner, repo, "/git/refs/heads/#{branch}", :patch, {
    sha: commit_sha,
    force: false
  })
end

def init_repo(token, owner, repo, branch)
  readme_content = Base64.strict_encode64("# Project Repository\nInitialized automatically by GitHub ZIP Deployer.")
  github_api(token, owner, repo, "/contents/README.md", :put, {
    message: "Initial commit by GitHub ZIP Deployer",
    content: readme_content,
    branch: branch
  })
end

def read_input(prompt, secret = false)
  print prompt
  $stdin.gets.chomp
end

def extract_zip(zip_path)
  files = []
  Zip::File.open(zip_path) do |zip|
    zip.each do |entry|
      next if entry.name.end_with?('/')
      next if entry.name.include?('__MACOSX') || entry.name.include?('.DS_Store')
      files << { path: entry.name, content: entry.get_input_stream.read }
    end
  end
  files
end

def main
  puts "\n\033[36m\033[1m🚀 GitHub ZIP Deployer — Tool by Icii White\033[0m\n"

  token = loop do
    input = read_input("\033[33m🔑 Personal Access Token (repo scope): \033[0m", true)
    break input unless input.strip.empty?
  end

  owner = loop do
    input = read_input("\033[33m👤 Repository owner (username or org): \033[0m")
    break input unless input.strip.empty?
  end

  repo = loop do
    input = read_input("\033[33m📁 Repository name: \033[0m")
    break input unless input.strip.empty?
  end

  branch = read_input("\033[33m🌿 Branch name (default: main): \033[0m")
  branch = "main" if branch.strip.empty?

  zip_path = loop do
    input = read_input("\033[33m🗂️  Path to ZIP file: \033[0m")
    break input if File.file?(input)
    log("File not found", :error)
  end

  log("Target: #{owner}/#{repo} on branch '#{branch}'")
  log("ZIP file: #{zip_path}")

  log("Reading ZIP file in memory...")
  valid_files = extract_zip(zip_path)
  log("Found #{valid_files.size} valid files to process.")

  begin
    latest_commit_sha = get_ref(token, owner, repo, branch)
    base_tree_sha = get_tree_sha(token, owner, repo, latest_commit_sha)
  rescue => e
    log("Branch '#{branch}' not found or repository empty. Attempting initialization...", :warn)
    init_repo(token, owner, repo, branch)
    log("Successfully initialized repository with README.md", :success)
    latest_commit_sha = get_ref(token, owner, repo, branch)
    base_tree_sha = get_tree_sha(token, owner, repo, latest_commit_sha)
  end

  log("Uploading files as blobs...")
  tree_entries = []
  batch_size = 10
  total = valid_files.size

  (0...total).step(batch_size) do |i|
    batch = valid_files[i, batch_size]
    threads = batch.map do |file|
      Thread.new do
        sha = create_blob(token, owner, repo, file[:content])
        { path: file[:path], sha: sha }
      end
    end
    results = threads.map(&:value)
    results.each do |res|
      tree_entries << {
        path: res[:path],
        mode: "100644",
        type: "blob",
        sha: res[:sha]
      }
    end
    processed = [i + batch_size, total].min
    log("  -> Uploaded #{processed} / #{total} files...")
  end

  log("Constructing new Git tree...")
  new_tree_sha = create_tree(token, owner, repo, base_tree_sha, tree_entries)

  log("Creating commit...")
  commit_msg = "Upload ZIP deployment via Web Client\n\nUploaded #{total} files."
  new_commit_sha = create_commit(token, owner, repo, latest_commit_sha, new_tree_sha, commit_msg)

  log("Updating branch reference to new commit...")
  update_ref(token, owner, repo, branch, new_commit_sha)

  log("Successfully deployed #{total} files to #{owner}/#{repo} on branch '#{branch}'! 🎉", :success)
  log("https://github.com/#{owner}/#{repo}/tree/#{branch}")
end

main if __FILE__ == $0