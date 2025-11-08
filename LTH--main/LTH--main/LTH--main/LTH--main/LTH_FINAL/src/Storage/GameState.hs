{-# LANGUAGE RecordWildCards #-}
module Storage.GameState where

import Game.Types
import Game.Board
import Game.Rules
import Storage.Serialization
import Control.Exception (catch, IOException)
import Control.Monad (when)
import Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString.Lazy as BL
import Data.Time.Clock (getCurrentTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import System.Directory (createDirectoryIfMissing, doesFileExist, listDirectory)
import System.FilePath ((</>), takeExtension)

-- ============================================================
-- Save Directory Configuration
-- ============================================================

saveDirectory :: FilePath
saveDirectory = "saves"

autoSaveDirectory :: FilePath
autoSaveDirectory = saveDirectory </> "autosave"

replayDirectory :: FilePath
replayDirectory = saveDirectory </> "replays"

-- Initialize save directories
initSaveDirectories :: IO ()
initSaveDirectories = do
  createDirectoryIfMissing True saveDirectory
  createDirectoryIfMissing True autoSaveDirectory
  createDirectoryIfMissing True replayDirectory

-- ============================================================
-- Save Game
-- ============================================================

-- Save game state to file (Binary format)
saveGame :: FilePath -> GameState -> IO ()
saveGame filepath state = do
  initSaveDirectories
  let fullPath = saveDirectory </> filepath
  let serialized = serializeGameState state
  BL.writeFile fullPath serialized
  putStrLn $ "✅ Game saved to: " ++ fullPath

-- Save game with timestamp
saveGameWithTimestamp :: String -> GameState -> IO FilePath
saveGameWithTimestamp prefix state = do
  timestamp <- getCurrentTime
  let timeStr = formatTime defaultTimeLocale "%Y%m%d_%H%M%S" timestamp
  let filename = prefix ++ "_" ++ timeStr ++ ".c4save"
  saveGame filename state
  return filename

-- Save game (JSON format for readability)
saveGameJSON :: FilePath -> GameState -> IO ()
saveGameJSON filepath state = do
  initSaveDirectories
  let fullPath = saveDirectory </> filepath
  let serialized = serializeGameStateJSON state
  BL.writeFile fullPath serialized
  putStrLn $ "✅ Game saved to: " ++ fullPath ++ " (JSON format)"

-- ============================================================
-- Load Game
-- ============================================================

-- Load game state from file
loadGame :: FilePath -> IO (Maybe GameState)
loadGame filepath = do
  let fullPath = saveDirectory </> filepath
  exists <- doesFileExist fullPath
  if not exists
    then do
      putStrLn $ "❌ File not found: " ++ fullPath
      return Nothing
    else do
      contents <- BL.readFile fullPath
      case safeDeserializeGameState contents of
        Just state -> do
          putStrLn $ "✅ Game loaded from: " ++ fullPath
          return (Just state)
        Nothing -> do
          putStrLn $ "❌ Failed to parse save file: " ++ fullPath
          return Nothing
  `catch` handleIOError
  where
    handleIOError :: IOException -> IO (Maybe GameState)
    handleIOError e = do
      putStrLn $ "❌ Error loading file: " ++ show e
      return Nothing

-- Load game with fallback to JSON
loadGameAuto :: FilePath -> IO (Maybe GameState)
loadGameAuto filepath = do
  -- Try binary first
  result <- loadGame filepath
  case result of
    Just state -> return (Just state)
    Nothing -> do
      -- Try JSON
      let fullPath = saveDirectory </> filepath
      exists <- doesFileExist fullPath
      if not exists
        then return Nothing
        else do
          contents <- BL.readFile fullPath
          case deserializeGameStateJSON contents of
            Just state -> do
              putStrLn $ "✅ Game loaded from JSON: " ++ fullPath
              return (Just state)
            Nothing -> return Nothing

-- ============================================================
-- Auto-Save Functionality
-- ============================================================

-- Auto-save configuration
data AutoSaveConfig = AutoSaveConfig
  { autoSaveEnabled :: Bool
  , autoSaveInterval :: Int  -- Save every N moves
  , maxAutoSaves :: Int      -- Keep only last N auto-saves
  } deriving (Show)

defaultAutoSaveConfig :: AutoSaveConfig
defaultAutoSaveConfig = AutoSaveConfig
  { autoSaveEnabled = True
  , autoSaveInterval = 5
  , maxAutoSaves = 10
  }

-- Check if auto-save should trigger
shouldAutoSave :: AutoSaveConfig -> GameState -> Bool
shouldAutoSave config state =
  autoSaveEnabled config &&
  moveCount state > 0 &&
  moveCount state `mod` autoSaveInterval config == 0

-- Perform auto-save
autoSave :: GameState -> IO ()
autoSave state = do
  initSaveDirectories
  let filename = "autosave_" ++ show (moveCount state) ++ ".c4save"
  let fullPath = autoSaveDirectory </> filename
  let serialized = serializeGameState state
  BL.writeFile fullPath serialized
  putStrLn $ "💾 Auto-saved: " ++ filename

-- Clean up old auto-saves (keep only last N)
cleanupAutoSaves :: Int -> IO ()
cleanupAutoSaves maxKeep = do
  initSaveDirectories
  files <- listDirectory autoSaveDirectory
  let saveFiles = filter (\f -> takeExtension f == ".c4save") files
  when (length saveFiles > maxKeep) $ do
    let toDelete = drop maxKeep (reverse saveFiles)
    mapM_ (\f -> putStrLn $ "🗑️  Deleting old auto-save: " ++ f) toDelete
    -- mapM_ (removeFile . (autoSaveDirectory </>)) toDelete

-- Load most recent auto-save
loadLatestAutoSave :: IO (Maybe GameState)
loadLatestAutoSave = do
  initSaveDirectories
  files <- listDirectory autoSaveDirectory
  let saveFiles = filter (\f -> takeExtension f == ".c4save") files
  if null saveFiles
    then return Nothing
    else do
      let latestFile = last (reverse saveFiles)
      loadGame ("autosave" </> latestFile)

-- ============================================================
-- Save/Load Move History
-- ============================================================

-- Save move history for replay
saveGameHistory :: FilePath -> [Move] -> IO ()
saveGameHistory filepath moves = do
  initSaveDirectories
  let fullPath = replayDirectory </> filepath
  let content = serializeMoves moves
  writeFile fullPath content
  putStrLn $ "✅ Game history saved: " ++ fullPath

-- Load move history
loadGameHistory :: FilePath -> IO (Maybe [Move])
loadGameHistory filepath = do
  let fullPath = replayDirectory </> filepath
  exists <- doesFileExist fullPath
  if not exists
    then return Nothing
    else do
      content <- readFile fullPath
      return (deserializeMoves content)
  `catch` \(_ :: IOException) -> return Nothing

-- ============================================================
-- Replay Game from History
-- ============================================================

-- Replay moves step by step
replayGame :: [Move] -> Player -> IO ()
replayGame moves startPlayer = do
  putStrLn "\n🎬 Replaying game..."
  putStrLn $ "Total moves: " ++ show (length moves)
  putStrLn $ replicate 50 '='
  replayStep (newGame startPlayer) moves 1
  where
    replayStep :: GameState -> [Move] -> Int -> IO ()
    replayStep state [] _ = do
      putStrLn "\n✅ Replay finished"
      putStrLn $ showBoardEmoji (board state)
      case gameStatus state of
        Winner p -> putStrLn $ "Winner: " ++ show p
        Draw -> putStrLn "Game ended in a draw"
        InProgress -> putStrLn "Game incomplete"
    
    replayStep state (move:rest) moveNum = do
      putStrLn $ "\nMove " ++ show moveNum ++ ": Column " ++ show move
      case applyMove state move of
        Nothing -> do
          putStrLn "❌ Invalid move in history!"
          return ()
        Just newState -> do
          putStrLn $ showBoardEmoji (board newState)
          
          -- Pause for readability (in real app, could be interactive)
          -- threadDelay 1000000  -- 1 second
          
          replayStep newState rest (moveNum + 1)

-- Replay with interactive control
replayGameInteractive :: [Move] -> Player -> IO ()
replayGameInteractive moves startPlayer = do
  putStrLn "\n🎬 Interactive Replay"
  putStrLn "Press Enter to see next move, 'q' to quit"
  putStrLn $ replicate 50 '='
  replayInteractive (newGame startPlayer) moves 1
  where
    replayInteractive state [] _ = do
      putStrLn "\n✅ Replay finished"
    
    replayInteractive state (move:rest) moveNum = do
      putStrLn $ "\nMove " ++ show moveNum ++ ": Press Enter..."
      input <- getLine
      if input == "q"
        then putStrLn "Replay cancelled"
        else do
          putStrLn $ "Column " ++ show move
          case applyMove state move of
            Nothing -> putStrLn "Invalid move!"
            Just newState -> do
              putStrLn $ showBoardEmoji (board newState)
              replayInteractive newState rest (moveNum + 1)

-- ============================================================
-- List Saved Games
-- ============================================================

-- List all saved games
listSavedGames :: IO [FilePath]
listSavedGames = do
  initSaveDirectories
  files <- listDirectory saveDirectory
  return $ filter (\f -> takeExtension f == ".c4save") files

-- Print saved games
printSavedGames :: IO ()
printSavedGames = do
  games <- listSavedGames
  putStrLn "\n📂 Saved Games:"
  if null games
    then putStrLn "  No saved games found"
    else mapM_ (\g -> putStrLn $ "  - " ++ g) games

-- ============================================================
-- Quick Save/Load (for in-game use)
-- ============================================================

-- Quick save to default slot
quickSave :: GameState -> IO ()
quickSave state = saveGame "quicksave.c4save" state

-- Quick load from default slot
quickLoad :: IO (Maybe GameState)
quickLoad = loadGame "quicksave.c4save"

-- ============================================================
-- Game Session Management
-- ============================================================

data GameSession = GameSession
  { sessionState :: GameState
  , sessionAutoSaveConfig :: AutoSaveConfig
  , sessionStartTime :: String
  } deriving (Show)

-- Create new session
newSession :: Player -> IO GameSession
newSession startPlayer = do
  timestamp <- getCurrentTime
  let timeStr = formatTime defaultTimeLocale "%Y-%m-%d %H:%M:%S" timestamp
  return GameSession
    { sessionState = newGame startPlayer
    , sessionAutoSaveConfig = defaultAutoSaveConfig
    , sessionStartTime = timeStr
    }

-- Update session with move (handles auto-save)
updateSession :: GameSession -> Move -> IO (Maybe GameSession)
updateSession session move = do
  let state = sessionState session
  case applyMove state move of
    Nothing -> return Nothing
    Just newState -> do
      -- Check auto-save
      when (shouldAutoSave (sessionAutoSaveConfig session) newState) $ do
        autoSave newState
        cleanupAutoSaves (maxAutoSaves $ sessionAutoSaveConfig session)
      
      return $ Just session { sessionState = newState }

-- Save session
saveSession :: FilePath -> GameSession -> IO ()
saveSession filepath session = saveGame filepath (sessionState session)