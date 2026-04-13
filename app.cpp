#include <iostream>
#include <string>
#include <vector>
#include <thread>
#include <future>
#include <chrono>
#include <iomanip>
#include <sstream>
#include <fstream>
#include <algorithm>
#include <cstring>
#include <curl/curl.h>
#include <zip.h>
#include <nlohmann/json.hpp>

using json = nlohmann::json;

std::string base64_encode(const std::vector<unsigned char>& data) {
    static const char* b64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    std::string result;
    int i = 0;
    unsigned char a, b, c;
    int n = data.size();
    while (i < n) {
        a = i < n ? data[i++] : 0;
        b = i < n ? data[i++] : 0;
        c = i < n ? data[i++] : 0;
        result.push_back(b64[a >> 2]);
        result.push_back(b64[((a & 0x03) << 4) | (b >> 4)]);
        result.push_back(b64[((b & 0x0f) << 2) | (c >> 6)]);
        result.push_back(b64[c & 0x3f]);
    }
    for (size_t j = 0; j < (3 - n % 3) % 3; ++j)
        result.back() = '=';
    return result;
}

std::string base64_encode_string(const std::string& s) {
    std::vector<unsigned char> data(s.begin(), s.end());
    return base64_encode(data);
}

std::string base64_encode_bytes(const std::vector<char>& bytes) {
    std::vector<unsigned char> data(bytes.begin(), bytes.end());
    return base64_encode(data);
}

void log(const std::string& msg, const std::string& level = "info") {
    auto now = std::chrono::system_clock::now();
    auto time_t = std::chrono::system_clock::to_time_t(now);
    std::tm tm;
    localtime_r(&time_t, &tm);
    std::ostringstream oss;
    oss << std::setfill('0') << std::setw(2) << tm.tm_hour << ":"
        << std::setw(2) << tm.tm_min << ":"
        << std::setw(2) << tm.tm_sec;
    std::string timestamp = oss.str();

    std::string color, icon;
    if (level == "error") { color = "\033[31m"; icon = "✖"; }
    else if (level == "success") { color = "\033[32m"; icon = "✓"; }
    else if (level == "warn") { color = "\033[33m"; icon = "⚠"; }
    else { color = "\033[36m"; icon = "➜"; }

    std::cout << "\033[90m[" << timestamp << "]\033[0m " << color << icon << " " << msg << "\033[0m" << std::endl;
}

size_t write_callback(void* contents, size_t size, size_t nmemb, std::string* response) {
    size_t total = size * nmemb;
    response->append((char*)contents, total);
    return total;
}

json github_api(const std::string& token, const std::string& owner, const std::string& repo,
                const std::string& endpoint, const std::string& method = "GET",
                const json& data = json::object()) {
    CURL* curl = curl_easy_init();
    if (!curl) throw std::runtime_error("curl init failed");

    std::string url = "https://api.github.com/repos/" + owner + "/" + repo + endpoint;
    std::string response;
    struct curl_slist* headers = nullptr;
    headers = curl_slist_append(headers, ("Authorization: Bearer " + token).c_str());
    headers = curl_slist_append(headers, "Accept: application/vnd.github.v3+json");
    headers = curl_slist_append(headers, "Content-Type: application/json");

    curl_easy_setopt(curl, CURLOPT_URL, url.c_str());
    curl_easy_setopt(curl, CURLOPT_HTTPHEADER, headers);
    curl_easy_setopt(curl, CURLOPT_WRITEFUNCTION, write_callback);
    curl_easy_setopt(curl, CURLOPT_WRITEDATA, &response);
    curl_easy_setopt(curl, CURLOPT_TIMEOUT, 30L);

    if (method == "POST") {
        curl_easy_setopt(curl, CURLOPT_POST, 1L);
        std::string body = data.dump();
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body.c_str());
    } else if (method == "PUT") {
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, "PUT");
        std::string body = data.dump();
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body.c_str());
    } else if (method == "PATCH") {
        curl_easy_setopt(curl, CURLOPT_CUSTOMREQUEST, "PATCH");
        std::string body = data.dump();
        curl_easy_setopt(curl, CURLOPT_POSTFIELDS, body.c_str());
    }

    CURLcode res = curl_easy_perform(curl);
    long http_code = 0;
    curl_easy_getinfo(curl, CURLINFO_RESPONSE_CODE, &http_code);
    curl_slist_free_all(headers);
    curl_easy_cleanup(curl);

    if (res != CURLE_OK) {
        throw std::runtime_error("curl error: " + std::string(curl_easy_strerror(res)));
    }
    if (http_code < 200 || http_code >= 300) {
        throw std::runtime_error("HTTP " + std::to_string(http_code) + ": " + response);
    }
    if (http_code == 204) return json::object();
    return json::parse(response);
}

std::string get_ref(const std::string& token, const std::string& owner, const std::string& repo, const std::string& branch) {
    json resp = github_api(token, owner, repo, "/git/ref/heads/" + branch);
    return resp["object"]["sha"];
}

std::string get_tree_sha(const std::string& token, const std::string& owner, const std::string& repo, const std::string& commit_sha) {
    json resp = github_api(token, owner, repo, "/git/commits/" + commit_sha);
    return resp["tree"]["sha"];
}

std::string create_blob(const std::string& token, const std::string& owner, const std::string& repo, const std::vector<char>& content) {
    std::string b64 = base64_encode_bytes(content);
    json body = {{"content", b64}, {"encoding", "base64"}};
    json resp = github_api(token, owner, repo, "/git/blobs", "POST", body);
    return resp["sha"];
}

std::string create_tree(const std::string& token, const std::string& owner, const std::string& repo,
                        const std::string& base_tree, const json& tree_entries) {
    json body = {{"base_tree", base_tree}, {"tree", tree_entries}};
    json resp = github_api(token, owner, repo, "/git/trees", "POST", body);
    return resp["sha"];
}

std::string create_commit(const std::string& token, const std::string& owner, const std::string& repo,
                          const std::string& parent, const std::string& tree, const std::string& message) {
    json body = {{"message", message}, {"tree", tree}, {"parents", {parent}}};
    json resp = github_api(token, owner, repo, "/git/commits", "POST", body);
    return resp["sha"];
}

void update_ref(const std::string& token, const std::string& owner, const std::string& repo,
                const std::string& branch, const std::string& commit_sha) {
    json body = {{"sha", commit_sha}, {"force", false}};
    github_api(token, owner, repo, "/git/refs/heads/" + branch, "PATCH", body);
}

void init_repo(const std::string& token, const std::string& owner, const std::string& repo, const std::string& branch) {
    std::string readme_content = base64_encode_string("# Project Repository\nInitialized automatically by GitHub ZIP Deployer.");
    json body = {{"message", "Initial commit by GitHub ZIP Deployer"},
                 {"content", readme_content},
                 {"branch", branch}};
    github_api(token, owner, repo, "/contents/README.md", "PUT", body);
}

std::string read_input(const std::string& prompt, bool secret = false) {
    std::cout << prompt;
    std::string line;
    if (secret) {
        // Simple fallback: just read normally, no hidden input for portability
        std::getline(std::cin, line);
    } else {
        std::getline(std::cin, line);
    }
    return line;
}

int main() {
    std::cout << "\n\033[36m\033[1m🚀 GitHub ZIP Deployer — Tool by Icii White\033[0m\n\n";
    
    std::string token;
    do {
        token = read_input("\033[33m🔑 Personal Access Token (repo scope): \033[0m", true);
    } while (token.empty());
    
    std::string owner;
    do {
        owner = read_input("\033[33m👤 Repository owner (username or org): \033[0m");
    } while (owner.empty());
    
    std::string repo;
    do {
        repo = read_input("\033[33m📁 Repository name: \033[0m");
    } while (repo.empty());
    
    std::string branch = read_input("\033[33m🌿 Branch name (default: main): \033[0m");
    if (branch.empty()) branch = "main";
    
    std::string zip_path;
    do {
        zip_path = read_input("\033[33m🗂️  Path to ZIP file: \033[0m");
        if (!zip_path.empty()) {
            std::ifstream test(zip_path, std::ios::binary);
            if (!test.good()) {
                log("File not found", "error");
                zip_path.clear();
            }
        }
    } while (zip_path.empty());
    
    log("Target: " + owner + "/" + repo + " on branch '" + branch + "'");
    log("ZIP file: " + zip_path);
    
    std::ifstream zip_file(zip_path, std::ios::binary);
    if (!zip_file) {
        log("Cannot read ZIP file", "error");
        return 1;
    }
    std::vector<char> zip_data((std::istreambuf_iterator<char>(zip_file)), std::istreambuf_iterator<char>());
    zip_file.close();
    
    log("Reading ZIP file in memory...");
    
    zip_error_t error;
    zip_source_t* src = zip_source_buffer_create(zip_data.data(), zip_data.size(), 0, &error);
    if (!src) {
        log("Failed to create ZIP source", "error");
        return 1;
    }
    zip_t* zf = zip_open_from_source(src, ZIP_RDONLY, &error);
    if (!zf) {
        log("Failed to open ZIP archive", "error");
        zip_source_free(src);
        return 1;
    }
    
    struct FileInfo {
        std::string path;
        std::vector<char> content;
    };
    std::vector<FileInfo> valid_files;
    zip_int64_t num_entries = zip_get_num_entries(zf, 0);
    for (zip_int64_t i = 0; i < num_entries; ++i) {
        const char* name = zip_get_name(zf, i, 0);
        if (!name) continue;
        struct zip_stat st;
        zip_stat_init(&st);
        if (zip_stat(zf, name, 0, &st) != 0) continue;
        if (name[std::strlen(name)-1] == '/') continue;
        if (std::string(name).find("__MACOSX") != std::string::npos ||
            std::string(name).find(".DS_Store") != std::string::npos)
            continue;
        zip_file_t* file = zip_fopen(zf, name, 0);
        if (!file) continue;
        std::vector<char> content(st.size);
        zip_int64_t bytes_read = zip_fread(file, content.data(), st.size);
        zip_fclose(file);
        if (bytes_read == st.size) {
            valid_files.push_back({name, std::move(content)});
        }
    }
    zip_close(zf);
    
    log("Found " + std::to_string(valid_files.size()) + " valid files to process.");
    
    std::string latest_commit_sha, base_tree_sha;
    try {
        latest_commit_sha = get_ref(token, owner, repo, branch);
        base_tree_sha = get_tree_sha(token, owner, repo, latest_commit_sha);
    } catch (const std::exception& e) {
        log("Branch '" + branch + "' not found or repository empty. Attempting initialization...", "warn");
        try {
            init_repo(token, owner, repo, branch);
            log("Successfully initialized repository with README.md", "success");
            latest_commit_sha = get_ref(token, owner, repo, branch);
            base_tree_sha = get_tree_sha(token, owner, repo, latest_commit_sha);
        } catch (const std::exception& init_err) {
            log("Failed to initialize empty repository: " + std::string(init_err.what()), "error");
            return 1;
        }
    }
    
    log("Uploading files as blobs...");
    json tree_entries = json::array();
    const size_t batch_size = 10;
    size_t total = valid_files.size();
    for (size_t i = 0; i < total; i += batch_size) {
        size_t end = std::min(i + batch_size, total);
        std::vector<std::future<std::pair<std::string, std::string>>> futures;
        for (size_t j = i; j < end; ++j) {
            futures.push_back(std::async(std::launch::async, [&token, &owner, &repo, &valid_files, j]() {
                std::string sha = create_blob(token, owner, repo, valid_files[j].content);
                return std::make_pair(valid_files[j].path, sha);
            }));
        }
        for (auto& fut : futures) {
            auto result = fut.get();
            tree_entries.push_back({
                {"path", result.first},
                {"mode", "100644"},
                {"type", "blob"},
                {"sha", result.second}
            });
        }
        log("  -> Uploaded " + std::to_string(std::min(i + batch_size, total)) + " / " + std::to_string(total) + " files...");
    }
    
    log("Constructing new Git tree...");
    std::string new_tree_sha = create_tree(token, owner, repo, base_tree_sha, tree_entries);
    
    log("Creating commit...");
    std::string commit_msg = "Upload ZIP deployment via Web Client\n\nUploaded " + std::to_string(total) + " files.";
    std::string new_commit_sha = create_commit(token, owner, repo, latest_commit_sha, new_tree_sha, commit_msg);
    
    log("Updating branch reference to new commit...");
    update_ref(token, owner, repo, branch, new_commit_sha);
    
    log("Successfully deployed " + std::to_string(total) + " files to " + owner + "/" + repo + " on branch '" + branch + "'! 🎉", "success");
    log("https://github.com/" + owner + "/" + repo + "/tree/" + branch, "info");
    
    return 0;
}