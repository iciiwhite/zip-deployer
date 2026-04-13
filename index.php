#!/usr/bin/env php
<?php

function logMessage($message, $level = 'info') {
    $time = date('H:i:s');
    $color = $icon = '';
    switch ($level) {
        case 'error': $color = "\033[31m"; $icon = '✖'; break;
        case 'success': $color = "\033[32m"; $icon = '✓'; break;
        case 'warn': $color = "\033[33m"; $icon = '⚠'; break;
        default: $color = "\033[36m"; $icon = '➜'; break;
    }
    echo "\033[90m[{$time}]\033[0m {$color}{$icon} {$message}\033[0m\n";
}

function githubRequest($token, $owner, $repo, $endpoint, $method = 'GET', $data = null) {
    $url = "https://api.github.com/repos/{$owner}/{$repo}{$endpoint}";
    $ch = curl_init();
    curl_setopt($ch, CURLOPT_URL, $url);
    curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
    curl_setopt($ch, CURLOPT_USERAGENT, 'GitHub-ZIP-Deployer');
    curl_setopt($ch, CURLOPT_HTTPHEADER, [
        "Authorization: Bearer {$token}",
        "Accept: application/vnd.github.v3+json",
        "Content-Type: application/json"
    ]);
    if ($method !== 'GET') {
        curl_setopt($ch, CURLOPT_CUSTOMREQUEST, $method);
        if ($data !== null) {
            curl_setopt($ch, CURLOPT_POSTFIELDS, json_encode($data));
        }
    }
    $response = curl_exec($ch);
    $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
    curl_close($ch);
    if ($httpCode < 200 || $httpCode >= 300) {
        throw new Exception("HTTP {$httpCode}: {$response}");
    }
    if ($httpCode === 204) {
        return null;
    }
    return json_decode($response, true);
}

function readInput($prompt, $secret = false) {
    echo $prompt;
    $handle = fopen('php://stdin', 'r');
    $line = trim(fgets($handle));
    fclose($handle);
    return $line;
}

echo "\n\033[36m\033[1m🚀 GitHub ZIP Deployer — Tool by Icii White\033[0m\n\n";

do {
    $token = readInput("\033[33m🔑 Personal Access Token (repo scope): \033[0m");
} while (empty($token));

do {
    $owner = readInput("\033[33m👤 Repository owner (username or org): \033[0m");
} while (empty($owner));

do {
    $repo = readInput("\033[33m📁 Repository name: \033[0m");
} while (empty($repo));

$branch = readInput("\033[33m🌿 Branch name (default: main): \033[0m");
if (empty($branch)) $branch = 'main';

do {
    $zipPath = readInput("\033[33m🗂️  Path to ZIP file: \033[0m");
    if (!file_exists($zipPath)) {
        logMessage("File not found", 'error');
        $zipPath = '';
    }
} while (empty($zipPath));

logMessage("Target: {$owner}/{$repo} on branch '{$branch}'");
logMessage("ZIP file: {$zipPath}");

logMessage("Reading ZIP file in memory...");
$zip = new ZipArchive;
if ($zip->open($zipPath) !== true) {
    logMessage("Cannot read ZIP file", 'error');
    exit(1);
}

$validFiles = [];
for ($i = 0; $i < $zip->numFiles; $i++) {
    $stat = $zip->statIndex($i);
    $name = $stat['name'];
    if (substr($name, -1) === '/') continue;
    if (strpos($name, '__MACOSX') !== false || strpos($name, '.DS_Store') !== false) continue;
    $content = $zip->getFromIndex($i);
    $validFiles[] = ['path' => $name, 'content' => $content];
}
$zip->close();
logMessage("Found " . count($validFiles) . " valid files to process.");

try {
    $refData = githubRequest($token, $owner, $repo, "/git/ref/heads/{$branch}");
    $latestCommitSha = $refData['object']['sha'];
    $commitData = githubRequest($token, $owner, $repo, "/git/commits/{$latestCommitSha}");
    $baseTreeSha = $commitData['tree']['sha'];
} catch (Exception $e) {
    logMessage("Branch '{$branch}' not found or repository empty. Attempting initialization...", 'warn');
    try {
        $readmeContent = base64_encode("# Project Repository\nInitialized automatically by GitHub ZIP Deployer.");
        githubRequest($token, $owner, $repo, "/contents/README.md", 'PUT', [
            'message' => 'Initial commit by GitHub ZIP Deployer',
            'content' => $readmeContent,
            'branch' => $branch
        ]);
        logMessage("Successfully initialized repository with README.md", 'success');
        $refData = githubRequest($token, $owner, $repo, "/git/ref/heads/{$branch}");
        $latestCommitSha = $refData['object']['sha'];
        $commitData = githubRequest($token, $owner, $repo, "/git/commits/{$latestCommitSha}");
        $baseTreeSha = $commitData['tree']['sha'];
    } catch (Exception $initErr) {
        logMessage("Failed to initialize empty repository: " . $initErr->getMessage(), 'error');
        exit(1);
    }
}

logMessage("Uploading files as blobs...");
$treeEntries = [];
$batchSize = 10;
$total = count($validFiles);
for ($i = 0; $i < $total; $i += $batchSize) {
    $batch = array_slice($validFiles, $i, $batchSize);
    $results = [];
    $mh = curl_multi_init();
    $handles = [];
    foreach ($batch as $idx => $file) {
        $url = "https://api.github.com/repos/{$owner}/{$repo}/git/blobs";
        $ch = curl_init();
        curl_setopt($ch, CURLOPT_URL, $url);
        curl_setopt($ch, CURLOPT_RETURNTRANSFER, true);
        curl_setopt($ch, CURLOPT_USERAGENT, 'GitHub-ZIP-Deployer');
        curl_setopt($ch, CURLOPT_POST, true);
        curl_setopt($ch, CURLOPT_HTTPHEADER, [
            "Authorization: Bearer {$token}",
            "Accept: application/vnd.github.v3+json",
            "Content-Type: application/json"
        ]);
        $payload = json_encode([
            'content' => base64_encode($file['content']),
            'encoding' => 'base64'
        ]);
        curl_setopt($ch, CURLOPT_POSTFIELDS, $payload);
        curl_multi_add_handle($mh, $ch);
        $handles[$idx] = $ch;
    }
    $running = null;
    do {
        curl_multi_exec($mh, $running);
    } while ($running > 0);
    foreach ($handles as $idx => $ch) {
        $response = curl_multi_getcontent($ch);
        $httpCode = curl_getinfo($ch, CURLINFO_HTTP_CODE);
        curl_multi_remove_handle($mh, $ch);
        curl_close($ch);
        if ($httpCode >= 200 && $httpCode < 300) {
            $data = json_decode($response, true);
            $treeEntries[] = [
                'path' => $batch[$idx]['path'],
                'mode' => '100644',
                'type' => 'blob',
                'sha' => $data['sha']
            ];
        } else {
            throw new Exception("Blob upload failed: HTTP {$httpCode}");
        }
    }
    curl_multi_close($mh);
    $processed = min($i + $batchSize, $total);
    logMessage("  -> Uploaded {$processed} / {$total} files...");
}

logMessage("Constructing new Git tree...");
$newTree = githubRequest($token, $owner, $repo, "/git/trees", 'POST', [
    'base_tree' => $baseTreeSha,
    'tree' => $treeEntries
]);
$newTreeSha = $newTree['sha'];

logMessage("Creating commit...");
$commitMsg = "Upload ZIP deployment via Web Client\n\nUploaded {$total} files.";
$newCommit = githubRequest($token, $owner, $repo, "/git/commits", 'POST', [
    'message' => $commitMsg,
    'tree' => $newTreeSha,
    'parents' => [$latestCommitSha]
]);
$newCommitSha = $newCommit['sha'];

logMessage("Updating branch reference to new commit...");
githubRequest($token, $owner, $repo, "/git/refs/heads/{$branch}", 'PATCH', [
    'sha' => $newCommitSha,
    'force' => false
]);

logMessage("Successfully deployed {$total} files to {$owner}/{$repo} on branch '{$branch}'! 🎉", 'success');
logMessage("https://github.com/{$owner}/{$repo}/tree/{$branch}");