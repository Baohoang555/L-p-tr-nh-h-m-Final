{-# LANGUAGE RecordWildCards #-}
module Concurrency.GameManager where

import Control.Concurrent.STM
import Control.Concurrent.Async
import Control.Monad (forM_, when)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Time.Clock (getCurrentTime, UTCTime, diffUTCTime)
import Data.Maybe (fromMaybe)

import Game.Types
import Game.Board
import Game.Rules
import Network.Protocol

-- ============================================================
-- Game Manager Types
-- ============================================================

data GameManager = GameManager
  { activeGames :: TVar (Map GameId ManagedGame)
  , nextGameId :: TVar GameId
  , gameStats :: TVar GameManagerStats
  , config :: GameManagerConfig
  }

data ManagedGame = ManagedGame
  { gameId :: GameId
  , gameState :: TVar GameState
  , player1Info :: PlayerInfo
  , player2Info :: PlayerInfo
  , gameMetadata :: GameMetadata
  , moveTimeouts :: TVar (Map Player UTCTime)
  }

data PlayerInfo = PlayerInfo
  { playerId :: PlayerId
  , playerName :: PlayerName
  , playerColor :: Player
  } deriving (Show, Eq)

type PlayerId = Int
type GameId = Int

data GameMetadata = GameMetadata
  { startTime :: UTCTime
  , lastMoveTime :: TVar UTCTime
  , totalMoves :: TVar Int
  , gameStatus :: TVar GameStatus
  } deriving (Eq)

data GameManagerConfig = GameManagerConfig
  { maxConcurrentGames :: Int
  , moveTimeoutSeconds :: Int
  , enableAutoCleanup :: Bool
  , cleanupIntervalSeconds :: Int
  } deriving (Show)

data GameManagerStats = GameManagerStats
  { totalGamesCreated :: Int
  , currentActiveGames :: Int
  , totalMovesProcessed :: Int
  , totalTimeouts :: Int
  } deriving (Show)

-- ============================================================
-- Initialize Game Manager
-- ============================================================

-- Create new game manager
newGameManager :: GameManagerConfig -> IO GameManager
newGameManager cfg = do
  gamesVar <- newTVarIO Map.empty
  nextIdVar <- newTVarIO 0
  statsVar <- newTVarIO emptyStats
  return GameManager
    { activeGames = gamesVar
    , nextGameId = nextIdVar
    , gameStats = statsVar
    , config = cfg
    }

-- Default configuration
defaultConfig :: GameManagerConfig
defaultConfig = GameManagerConfig
  { maxConcurrentGames = 100
  , moveTimeoutSeconds = 30
  , enableAutoCleanup = True
  , cleanupIntervalSeconds = 60
  }

-- Empty stats
emptyStats :: GameManagerStats
emptyStats = GameManagerStats 0 0 0 0

-- ============================================================
-- Game Creation
-- ============================================================

-- Create a new game between two players
createGame :: GameManager -> PlayerId -> PlayerName -> PlayerId -> PlayerName -> IO (Either String GameId)
createGame manager pid1 name1 pid2 name2 = do
  -- Check if at capacity
  gamesMap <- atomically $ readTVar (activeGames manager)
  if Map.size gamesMap >= maxConcurrentGames (config manager)
    then return $ Left "Server at capacity"
    else do
      -- Create game
      now <- getCurrentTime
      
      let player1 = PlayerInfo pid1 name1 Red
      let player2 = PlayerInfo pid2 name2 Black
      
      gameStateVar <- newTVarIO (newGame Red)
      lastMoveVar <- newTVarIO now
      totalMovesVar <- newTVarIO 0
      statusVar <- newTVarIO InProgress
      timeoutsVar <- newTVarIO Map.empty
      
      let metadata = GameMetadata
            { startTime = now
            , lastMoveTime = lastMoveVar
            , totalMoves = totalMovesVar
            , gameStatus = statusVar
            }
      
      gid <- atomically $ do
        -- Get next ID
        gid <- readTVar (nextGameId manager)
        writeTVar (nextGameId manager) (gid + 1)
        
        -- Create managed game
        let managedGame = ManagedGame
              { gameId = gid
              , gameState = gameStateVar
              , player1Info = player1
              , player2Info = player2
              , gameMetadata = metadata
              , moveTimeouts = timeoutsVar
              }
        
        -- Add to active games
        modifyTVar' (activeGames manager) (Map.insert gid managedGame)
        
        -- Update stats
        modifyTVar' (gameStats manager) $ \s -> s
          { totalGamesCreated = totalGamesCreated s + 1
          , currentActiveGames = currentActiveGames s + 1
          }
        
        return gid
      
      return $ Right gid

-- ============================================================
-- Join Existing Game
-- ============================================================

-- Join a game by ID
joinGame :: GameManager -> GameId -> PlayerId -> STM (Either String ManagedGame)
joinGame manager gid pid = do
  gamesMap <- readTVar (activeGames manager)
  case Map.lookup gid gamesMap of
    Nothing -> return $ Left "Game not found"
    Just game -> do
      -- Verify player is part of this game
      if playerId (player1Info game) == pid || playerId (player2Info game) == pid
        then return $ Right game
        else return $ Left "Not a player in this game"

-- ============================================================
-- Make Move
-- ============================================================

-- Process a move in a game
makeGameMove :: GameManager -> GameId -> PlayerId -> Column -> STM (Either String GameState)
makeGameMove manager gid pid column = do
  gamesMap <- readTVar (activeGames manager)
  case Map.lookup gid gamesMap of
    Nothing -> return $ Left "Game not found"
    Just game -> do
      state <- readTVar (gameState game)
      
      -- Verify it's this player's turn
      let currentP = currentPlayer state
      let expectedPid = if currentP == Red 
                          then playerId (player1Info game)
                          else playerId (player2Info game)
      
      if pid /= expectedPid
        then return $ Left "Not your turn"
        else case makeMove (board state) column currentP of
          Nothing -> return $ Left "Invalid move"
          Just newBoard -> do
            let newState = state
                  { board = newBoard
                  , currentPlayer = nextPlayer currentP
                  , moveHistory = column : moveHistory state
                  , gameStatus = getGameResult newBoard
                  , moveCount = moveCount state + 1
                  }
            
            -- Update game state
            writeTVar (gameState game) newState
            
            -- Update metadata
            modifyTVar' (totalMoves $ gameMetadata game) (+1)
            writeTVar (gameStatus $ gameMetadata game) (gameStatus newState)
            
            -- Update manager stats
            modifyTVar' (gameStats manager) $ \s -> s
              { totalMovesProcessed = totalMovesProcessed s + 1
              }
            
            return $ Right newState

-- ============================================================
-- Game Queries
-- ============================================================

-- Get game by ID
getGame :: GameManager -> GameId -> STM (Maybe ManagedGame)
getGame manager gid = do
  gamesMap <- readTVar (activeGames manager)
  return $ Map.lookup gid gamesMap

-- Get game state
getGameState :: GameManager -> GameId -> STM (Maybe GameState)
getGameState manager gid = do
  mGame <- getGame manager gid
  case mGame of
    Nothing -> return Nothing
    Just game -> Just <$> readTVar (gameState game)

-- Get all active game IDs
getActiveGameIds :: GameManager -> STM [GameId]
getActiveGameIds manager = do
  gamesMap <- readTVar (activeGames manager)
  return $ Map.keys gamesMap

-- Get games for a player
getPlayerGames :: GameManager -> PlayerId -> STM [ManagedGame]
getPlayerGames manager pid = do
  gamesMap <- readTVar (activeGames manager)
  return $ filter isPlayerGame (Map.elems gamesMap)
  where
    isPlayerGame game = 
      playerId (player1Info game) == pid || 
      playerId (player2Info game) == pid

-- Count active games
countActiveGames :: GameManager -> STM Int
countActiveGames manager = do
  gamesMap <- readTVar (activeGames manager)
  return $ Map.size gamesMap

-- ============================================================
-- Game Termination
-- ============================================================

-- End a game (remove from manager)
endGame :: GameManager -> GameId -> STM ()
endGame manager gid = do
  modifyTVar' (activeGames manager) (Map.delete gid)
  modifyTVar' (gameStats manager) $ \s -> s
    { currentActiveGames = currentActiveGames s - 1
    }

-- End all games for a player (when they disconnect)
endPlayerGames :: GameManager -> PlayerId -> STM [GameId]
endPlayerGames manager pid = do
  games <- getPlayerGames manager pid
  let gameIds = map gameId games
  forM_ gameIds (endGame manager)
  return gameIds

-- ============================================================
-- Timeout Management
-- ============================================================

-- Set timeout for a player's move
setMoveTimeout :: GameManager -> GameId -> Player -> UTCTime -> STM ()
setMoveTimeout manager gid player deadline = do
  mGame <- getGame manager gid
  case mGame of
    Nothing -> return ()
    Just game -> do
      modifyTVar' (moveTimeouts game) (Map.insert player deadline)

-- Check if move has timed out
checkTimeout :: GameManager -> GameId -> Player -> IO Bool
checkTimeout manager gid player = do
  now <- getCurrentTime
  atomically $ do
    mGame <- getGame manager gid
    case mGame of
      Nothing -> return False
      Just game -> do
        timeouts <- readTVar (moveTimeouts game)
        case Map.lookup player timeouts of
          Nothing -> return False
          Just deadline -> return $ now > deadline

-- Process timeout (forfeit game)
processTimeout :: GameManager -> GameId -> Player -> STM ()
processTimeout manager gid player = do
  mGame <- getGame manager gid
  case mGame of
    Nothing -> return ()
    Just game -> do
      state <- readTVar (gameState game)
      let winner = nextPlayer player
      let newState = state { gameStatus = Winner winner }
      writeTVar (gameState game) newState
      writeTVar (gameStatus $ gameMetadata game) (Winner winner)
      
      -- Update stats
      modifyTVar' (gameStats manager) $ \s -> s
        { totalTimeouts = totalTimeouts s + 1
        }

-- ============================================================
-- Cleanup
-- ============================================================

-- Remove finished games
cleanupFinishedGames :: GameManager -> IO Int
cleanupFinishedGames manager = atomically $ do
  gamesMap <- readTVar (activeGames manager)
  
  -- Find finished games
  finishedIds <- filterM isFinished (Map.keys gamesMap)
  
  -- Remove them
  forM_ finishedIds (endGame manager)
  
  return $ length finishedIds
  where
    isFinished gid = do
      mGame <- getGame manager gid
      case mGame of
        Nothing -> return False
        Just game -> do
          status <- readTVar (gameStatus $ gameMetadata game)
          return $ status /= InProgress

-- Remove old games (older than N minutes)
cleanupOldGames :: GameManager -> Int -> IO Int
cleanupOldGames manager maxAgeMinutes = do
  now <- getCurrentTime
  atomically $ do
    gamesMap <- readTVar (activeGames manager)
    
    -- Find old games
    oldIds <- filterM (isOld now) (Map.keys gamesMap)
    
    -- Remove them
    forM_ oldIds (endGame manager)
    
    return $ length oldIds
  where
    isOld now gid = do
      mGame <- getGame manager gid
      case mGame of
        Nothing -> return False
        Just game -> do
          let start = startTime $ gameMetadata game
          let ageMinutes = realToFrac (diffUTCTime now start) / 60
          return $ ageMinutes > fromIntegral maxAgeMinutes

-- Auto cleanup thread
autoCleanupThread :: GameManager -> IO ()
autoCleanupThread manager = do
  let intervalMicros = cleanupIntervalSeconds (config manager) * 1000000
  
  -- Cleanup finished games
  finishedCount <- cleanupFinishedGames manager
  when (finishedCount > 0) $
    putStrLn $ "🧹 Cleaned up " ++ show finishedCount ++ " finished games"
  
  -- Cleanup games older than 2 hours
  oldCount <- cleanupOldGames manager 120
  when (oldCount > 0) $
    putStrLn $ "🧹 Cleaned up " ++ show oldCount ++ " old games"
  
  threadDelay intervalMicros
  autoCleanupThread manager

-- ============================================================
-- Statistics
-- ============================================================

-- Get current statistics
getStats :: GameManager -> STM GameManagerStats
getStats manager = readTVar (gameStats manager)

-- Print statistics
printStats :: GameManager -> IO ()
printStats manager = do
  stats <- atomically $ getStats manager
  putStrLn "\n📊 Game Manager Statistics"
  putStrLn $ replicate 50 '-'
  putStrLn $ "Total games created: " ++ show (totalGamesCreated stats)
  putStrLn $ "Current active games: " ++ show (currentActiveGames stats)
  putStrLn $ "Total moves processed: " ++ show (totalMovesProcessed stats)
  putStrLn $ "Total timeouts: " ++ show (totalTimeouts stats)
  putStrLn $ replicate 50 '-'

-- ============================================================
-- Testing
-- ============================================================

-- Test game manager
testGameManager :: IO ()
testGameManager = do
  putStrLn "\n🧪 Testing Game Manager"
  putStrLn $ replicate 50 '='
  
  -- Create manager
  manager <- newGameManager defaultConfig
  putStrLn "✅ Manager created"
  
  -- Create games
  result1 <- createGame manager 1 "Alice" 2 "Bob"
  result2 <- createGame manager 3 "Charlie" 4 "David"
  
  case (result1, result2) of
    (Right gid1, Right gid2) -> do
      putStrLn $ "✅ Created games: " ++ show [gid1, gid2]
      
      -- Make moves
      move1 <- atomically $ makeGameMove manager gid1 1 3
      move2 <- atomically $ makeGameMove manager gid1 2 4
      
      putStrLn $ "Move results: " ++ show [move1, move2]
      
      -- Get stats
      printStats manager
      
    _ -> putStrLn "❌ Failed to create games"
  
  putStrLn $ replicate 50 '='

-- Helper
threadDelay :: Int -> IO ()
threadDelay = Control.Concurrent.threadDelay

filterM :: Monad m => (a -> m Bool) -> [a] -> m [a]
filterM _ [] = return []
filterM p (x:xs) = do
  b <- p x
  rest <- filterM p xs
  return $ if b then x : rest else rest