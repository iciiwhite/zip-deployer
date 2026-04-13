#!/usr/bin/env stack
-- stack script --resolver lts-21.25
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE LambdaCase #-}

import qualified Data.ByteString as B
import qualified Data.ByteString.Lazy as BL
import qualified Data.ByteString.Base64 as B64
import qualified Data.Text as T
import qualified Data.Text.IO as TIO
import Data.Aeson
import Data.Aeson.Encode.Pretty
import Data.Maybe
import Data.List
import Data.Time
import System.IO
import System.Exit
import System.Directory
import System.FilePath
import Codec.Archive.Zip
import Network.HTTP.Simple
import Network.HTTP.Types.Header
import Control.Concurrent.Async
import Control.Exception
import Control.Monad

logMsg :: String -> String -> IO ()
logMsg msg level = do
  now <- getCurrentTime
  let t = formatTime defaultTimeLocale "%H:%M:%S" now
  let (col, icon) = case level of
        "error" -> ("\x1b[31m", "✖")
        "success" -> ("\x1b[32m", "✓")
        "warn" -> ("\x1b[33m", "⚠")
        _ -> ("\x1b[36m", "➜")
  putStrLn $ "\x1b[90m[" <> t <> "]\x1b[0m " <> col <> icon <> " " <> msg <> "\x1b[0m"

readInput :: String -> IO String
readInput prompt = do
  putStr prompt
  hFlush stdout
  TIO.getLine >>= return . T.unpack . T.strip

githubRequest :: String -> String -> String -> String -> String -> Maybe Value -> IO Value
githubRequest token owner repo endpoint method body = do
  let url = "https://api.github.com/repos/" <> owner <> "/" <> repo <> endpoint
  initReq <- parseRequest url
  let req = initReq
        { method = method
        , requestHeaders = 
            [ ("Authorization", "Bearer " <> T.pack token)
            , ("Accept", "application/vnd.github.v3+json")
            , ("Content-Type", "application/json")
            ]
        , requestBody = case body of
            Just v -> RequestBodyLBS (encode v)
            Nothing -> RequestBodyBS ""
        }
  response <- httpJSONEither req
  case response of
    Left err -> do
      let status = getResponseStatus err
      let msg = T.unpack $ getResponseBody err
      error $ "HTTP " <> show status <> ": " <> msg
    Right (val :: Value) -> pure val

getRef :: String -> String -> String -> String -> IO String
getRef token owner repo branch = do
  v <- githubRequest token owner repo ("/git/ref/heads/" <> branch) "GET" Nothing
  let sha = v ^? key "object" . key "sha" . _String
  case sha of
    Just s -> pure $ T.unpack s
    Nothing -> error "No sha in ref response"

getTreeSha :: String -> String -> String -> String -> IO String
getTreeSha token owner repo commitSha = do
  v <- githubRequest token owner repo ("/git/commits/" <> commitSha) "GET" Nothing
  let sha = v ^? key "tree" . key "sha" . _String
  case sha of
    Just s -> pure $ T.unpack s
    Nothing -> error "No tree sha in commit"

createBlob :: String -> String -> String -> B.ByteString -> IO String
createBlob token owner repo content = do
  let b64 = B64.encode content
  let body = object [ "content" .= T.decodeUtf8 b64, "encoding" .= ("base64" :: T.Text) ]
  v <- githubRequest token owner repo "/git/blobs" "POST" (Just body)
  let sha = v ^? key "sha" . _String
  case sha of
    Just s -> pure $ T.unpack s
    Nothing -> error "No sha in blob response"

createTree :: String -> String -> String -> String -> [Value] -> IO String
createTree token owner repo baseTree entries = do
  let body = object [ "base_tree" .= baseTree, "tree" .= entries ]
  v <- githubRequest token owner repo "/git/trees" "POST" (Just body)
  let sha = v ^? key "sha" . _String
  case sha of
    Just s -> pure $ T.unpack s
    Nothing -> error "No sha in tree response"

createCommit :: String -> String -> String -> String -> String -> String -> IO String
createCommit token owner repo parent tree message = do
  let body = object
        [ "message" .= message
        , "tree" .= tree
        , "parents" .= [parent]
        ]
  v <- githubRequest token owner repo "/git/commits" "POST" (Just body)
  let sha = v ^? key "sha" . _String
  case sha of
    Just s -> pure $ T.unpack s
    Nothing -> error "No sha in commit response"

updateRef :: String -> String -> String -> String -> String -> IO ()
updateRef token owner repo branch commitSha = do
  let body = object [ "sha" .= commitSha, "force" .= False ]
  _ <- githubRequest token owner repo ("/git/refs/heads/" <> branch) "PATCH" (Just body)
  pure ()

initRepo :: String -> String -> String -> String -> IO ()
initRepo token owner repo branch = do
  let readmeContent = "# Project Repository\nInitialized automatically by GitHub ZIP Deployer."
  let b64 = B64.encode (BL.toStrict $ BL.fromStrict $ T.encodeUtf8 (T.pack readmeContent))
  let body = object
        [ "message" .= ("Initial commit by GitHub ZIP Deployer" :: T.Text)
        , "content" .= T.decodeUtf8 b64
        , "branch" .= branch
        ]
  _ <- githubRequest token owner repo "/contents/README.md" "PUT" (Just body)
  pure ()

main :: IO ()
main = do
  hSetBuffering stdout NoBuffering
  putStrLn $ "\n\x1b[36m\x1b[1m🚀 GitHub ZIP Deployer — Tool by Icii White\x1b[0m\n"
  
  token <- readInput "\x1b[33m🔑 Personal Access Token (repo scope): \x1b[0m"
  when (null token) $ error "Token required"
  
  owner <- readInput "\x1b[33m👤 Repository owner (username or org): \x1b[0m"
  when (null owner) $ error "Owner required"
  
  repo <- readInput "\x1b[33m📁 Repository name: \x1b[0m"
  when (null repo) $ error "Repository name required"
  
  branch <- readInput "\x1b[33m🌿 Branch name (default: main): \x1b[0m"
  let branch' = if null branch then "main" else branch
  
  zipPath <- loopPath
  where
    loopPath = do
      p <- readInput "\x1b[33m🗂️  Path to ZIP file: \x1b[0m"
      exists <- doesFileExist p
      if exists then pure p else do
        logMsg "File not found" "error"
        loopPath
  
  logMsg ("Target: " <> owner <> "/" <> repo <> " on branch '" <> branch' <> "'") "info"
  logMsg ("ZIP file: " <> zipPath) "info"
  
  logMsg "Reading ZIP file in memory..." "info"
  archive <- B.readFile zipPath
  let entries = withArchive archive (filter (not . isDirectory) (filesInArchive))
  let validFiles = filter (\e -> not ("__MACOSX" `isInfixOf` e) && not (".DS_Store" `isInfixOf` e)) entries
  let validContents = map (\f -> (f, fromArchive archive f)) validFiles
  let total = length validContents
  logMsg ("Found " <> show total <> " valid files to process.") "info"
  
  (latestCommit, baseTree) <- getInitialRefs token owner repo branch'
  
  logMsg "Uploading files as blobs..." "info"
  treeEntries <- uploadBlobs token owner repo validContents total
  
  logMsg "Constructing new Git tree..." "info"
  newTreeSha <- createTree token owner repo baseTree treeEntries
  
  logMsg "Creating commit..." "info"
  let commitMsg = "Upload ZIP deployment via Web Client\n\nUploaded " <> show total <> " files."
  newCommitSha <- createCommit token owner repo latestCommit newTreeSha commitMsg
  
  logMsg "Updating branch reference to new commit..." "info"
  updateRef token owner repo branch' newCommitSha
  
  logMsg ("Successfully deployed " <> show total <> " files to " <> owner <> "/" <> repo <> " on branch '" <> branch' <> "'! 🎉") "success"
  logMsg ("https://github.com/" <> owner <> "/" <> repo <> "/tree/" <> branch') "info"

getInitialRefs :: String -> String -> String -> String -> IO (String, String)
getInitialRefs token owner repo branch = do
  let action = do
        ref <- getRef token owner repo branch
        tree <- getTreeSha token owner repo ref
        pure (ref, tree)
  action `catch` \(_ :: SomeException) -> do
    logMsg ("Branch '" <> branch <> "' not found or repository empty. Attempting initialization...") "warn"
    initRepo token owner repo branch
    logMsg "Successfully initialized repository with README.md" "success"
    getInitialRefs token owner repo branch

uploadBlobs :: String -> String -> String -> [(String, B.ByteString)] -> Int -> IO [Value]
uploadBlobs token owner repo files total = do
  let batchSize = 10
  let batches = chunksOf batchSize files
  results <- forM (zip batches [1..]) $ \(batch, idx) -> do
    entries <- mapConcurrently ( \(path, content) -> do
        sha <- createBlob token owner repo content
        pure $ object
          [ "path" .= path
          , "mode" .= ("100644" :: T.Text)
          , "type" .= ("blob" :: T.Text)
          , "sha" .= sha
          ]
      ) batch
    let processed = min (idx * batchSize) total
    logMsg ("  -> Uploaded " <> show processed <> " / " <> show total <> " files...") "info"
    pure entries
  pure $ concat results

chunksOf :: Int -> [a] -> [[a]]
chunksOf _ [] = []
chunksOf n xs = take n xs : chunksOf n (drop n xs)