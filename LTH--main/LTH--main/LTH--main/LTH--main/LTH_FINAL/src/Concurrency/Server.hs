{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
module Network.Server where

import Control.Concurrent (ThreadId, forkIO, killThread)
import Control.Concurrent.STM
import Control.Monad (forever, forM_, when, unless)
import Control.Exception (finally, catch, SomeException)
import Data.Aeson (encode, decode)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Network.WebSockets as WS
import Data.Text (Text)
import qualified Data.Text as T
import Data.Time.Clock (getCurrentTime, diffUTCTime)
import System.IO (hFlush, stdout)

import Game.Types
import Game.Board
import Game.Rules
import Network.Protocol

-- ============================================================
-- Server State
-- ============================================================

data ServerState = ServerState
  { games :: TVar (Map GameId GameSession)
  , waitingPlayers :: TVar [WaitingPlayer]
  , connections :: TVar (Map ClientId ClientConnection)
  , nextGameId :: TVar GameId
  , nextClientId :: TVar ClientId
  , serverStats :: TVar ServerStats
  }

data WaitingPlayer = WaitingPlayer
  { waitingConn :: WS.Connection
  , waitingName :: PlayerName
  , waitingClientId :: ClientId
  }

data ClientConnection = ClientConnection
  { clientConn :: WS.Connection
  , clientName :: PlayerName
  , clientGameId :: Maybe GameId
  , clientJoinTime :: UTCTime
  }

data GameSession = GameSession
  { gameState :: TVar GameState
  , gamePlayer1 :: (ClientId, WS.Connection, PlayerName)
  , gamePlayer2 :: (ClientId, WS.Connection, PlayerName)
  , gameStartTime :: UTCTime
  , gameMoveTimeout :: Int  -- seconds
  , gameLastMove :: TVar UTCTime
  }

type GameId = Int
type ClientId = Int

data ServerStats = ServerStats
  { totalConnections :: Int
  , activeGames :: Int
  , completedGames :: Int
  , totalMessages :: Int
  } deriving (Show)

-- ============================================================
-- Initialize Server
-- ============================================================

newServerState :: IO ServerState
newServerState = do
  gamesVar <- newTVarIO Map.empty
  waitingVar <- newTVarIO []
  connsVar <- newTVarIO Map.empty
  nextGameVar <- newTVarIO 0
  nextClientVar <- newTVarIO 0
  statsVar <- newTVarIO (ServerStats 0 0 0 0)
  return ServerState
    { games = gamesVar
    , waitingPlayers = waitingVar
    , connections = connsVar
    , nextGameId = nextGameVar
    , nextClientId = nextClientVar
    , serverStats = statsVar
    }

-- ============================================================
-- Run Server
-- ============================================================

runServer :: Int -> IO ()
runServer port = do
  putStrLn $ "🎮 Connect Four Server v1.0"
  putStrLn $ "📡 Starting WebSocket server on port " ++ show port
  putStrLn $ "⏰ Move timeout: 30 seconds"
  putStrLn $ replicate 50 '='
  
  serverState <- newServerState
  
  -- Start stats reporting thread
  forkIO $ reportStats serverState
  
  WS.runServer "0.0.0.0" port $ \pending -> do
    conn <- WS.acceptRequest pending
    WS.withPingThread conn 30 (return ()) $ do
      handleNewConnection serverState conn
      `catch` handleException

-- ============================================================
-- Connection Handling
-- ============================================================

handleNewConnection :: ServerState -> WS.Connection -> IO ()
handleNewConnection state conn = do
  -- Get client ID
  clientId <- atomically $ do
    cid <- readTVar (nextClientId state)
    writeTVar (nextClientId state) (cid + 1)
    modifyTVar' (serverStats state) $ \s -> s { totalConnections = totalConnections s + 1 }
    return cid
  
  logInfo $ "Client #" ++ show clientId ++ " connected"
  
  -- Wait for JoinGame message
  msg <- WS.receiveData conn
  case decode msg of
    Just (JoinGame playerName) -> do
      case validatePlayerName playerName of
        Left err -> do
          sendMessage conn (ErrorMsg err)
          logError $ "Invalid player name from client #" ++ show clientId
        Right validName -> do
          now <- getCurrentTime
          
          -- Register connection
          let clientConn = ClientConnection
                { clientConn = conn
                , clientName = validName
                , clientGameId = Nothing
                , clientJoinTime = now
                }
          atomically $ modifyTVar' (connections state) (Map.insert clientId clientConn)
          
          logInfo $ "Player '" ++ T.unpack validName ++ "' joined (Client #" ++ show clientId ++ ")"
          
          -- Try to match with waiting player
          matchPlayer state clientId conn validName
          `finally` cleanupClient state clientId
    
    _ -> do
      sendMessage conn (ErrorMsg "Expected JoinGame message")
      logError $ "Client #" ++ show clientId ++ " sent invalid initial message"

-- ============================================================
-- Player Matching
-- ============================================================

matchPlayer :: ServerState -> ClientId -> WS.Connection -> PlayerName -> IO ()
matchPlayer state clientId conn playerName = do
  mOpponent <- atomically $ do
    waiting <- readTVar (waitingPlayers state)
    case waiting of
      [] -> do
        -- No one waiting, add to queue
        let newWaiting = WaitingPlayer conn playerName clientId
        writeTVar (waitingPlayers state) [newWaiting]
        return Nothing
      (opponent:rest) -> do
        -- Found opponent, remove from queue
        writeTVar (waitingPlayers state) rest
        return (Just opponent)
  
  case mOpponent of
    Nothing -> do
      logInfo $ "Player '" ++ T.unpack playerName ++ "' waiting for opponent..."
      sendMessage conn WaitingForOpponent
      waitForGame state clientId conn playerName
    
    Just opponent -> do
      logInfo $ "Matching: '" ++ T.unpack playerName ++ "' vs '" ++ T.unpack (waitingName opponent) ++ "'"
      startGame state 
        clientId conn playerName
        (waitingClientId opponent) (waitingConn opponent) (waitingName opponent)

-- ============================================================
-- Wait for Game
-- ============================================================

waitForGame :: ServerState -> ClientId -> WS.Connection -> PlayerName -> IO ()
waitForGame state clientId conn playerName = do
  -- Keep connection alive, waiting to be matched
  forever $ do
    msg <- WS.receiveData conn
    case decode msg of
      Just LeaveGame -> do
        logInfo $ "Player '" ++ T.unpack playerName ++ "' left lobby"
        -- Remove from waiting list
        atomically $ modifyTVar' (waitingPlayers state) 
          (filter (\w -> waitingClientId w /= clientId))
        return ()
      Just Ping -> sendMessage conn Pong
      _ -> return ()

-- ============================================================
-- Start Game
-- ============================================================

startGame :: ServerState -> ClientId -> WS.Connection -> PlayerName 
          -> ClientId -> WS.Connection -> PlayerName -> IO ()
startGame state cid1 conn1 name1 cid2 conn2 name2 = do
  -- Generate game ID
  gameId <- atomically $ do
    gid <- readTVar (nextGameId state)
    writeTVar (nextGameId state) (gid + 1)
    modifyTVar' (serverStats state) $ \s -> s { activeGames = activeGames s + 1 }
    return gid
  
  -- Create game state
  now <- getCurrentTime
  stateVar <- newTVarIO (newGame Red)
  lastMoveVar <- newTVarIO now
  
  let session = GameSession
        { gameState = stateVar
        , gamePlayer1 = (cid1, conn1, name1)
        , gamePlayer2 = (cid2, conn2, name2)
        , gameStartTime = now
        , gameMoveTimeout = 30
        , gameLastMove = lastMoveVar
        }
  
  -- Register game
  atomically $ modifyTVar' (games state) (Map.insert gameId session)
  
  -- Update client connections
  atomically $ do
    modifyTVar' (connections state) (Map.adjust (\c -> c { clientGameId = Just gameId }) cid1)
    modifyTVar' (connections state) (Map.adjust (\c -> c { clientGameId = Just gameId }) cid2)
  
  logInfo $ "🎮 Game #" ++ show gameId ++ " started: " 
    ++ T.unpack name1 ++ " (Red) vs " ++ T.unpack name2 ++ " (Black)"
  
  -- Notify players
  initialState <- atomically $ readTVar stateVar
  sendMessage conn1 (OpponentConnected name2)
  sendMessage conn2 (OpponentConnected name1)
  sendMessage conn1 (GameUpdate initialState)
  sendMessage conn2 (GameUpdate initialState)
  
  -- Handle game messages
  tid1 <- forkIO $ handleGameMessages state gameId cid1 conn1 Red 
          `finally` handlePlayerDisconnect state gameId cid1
  tid2 <- forkIO $ handleGameMessages state gameId cid2 conn2 Black
          `finally` handlePlayerDisconnect state gameId cid2
  
  -- Timeout monitor
  forkIO $ monitorTimeout state gameId session
  
  return ()

-- ============================================================
-- Game Message Handling
-- ============================================================

handleGameMessages :: ServerState -> GameId -> ClientId -> WS.Connection 
                   -> Player -> IO ()
handleGameMessages state gameId clientId conn player = forever $ do
  msg <- WS.receiveData conn
  atomically $ modifyTVar' (serverStats state) $ \s -> s { totalMessages = totalMessages s + 1 }
  
  case decode msg of
    Just (MakeMove column) -> do
      result <- atomically $ processMove state gameId player column
      case result of
        Left err -> sendMessage conn (ErrorMsg err)
        Right (session, newState) -> do
          -- Update last move time
          now <- getCurrentTime
          atomically $ writeTVar (gameLastMove session) now
          
          -- Broadcast update
          broadcastGameUpdate state session newState
          
          -- Check game over
          checkGameOver state gameId session newState
    
    Just (ChatMessage text) -> do
      result <- atomically $ getGameSession state gameId
      case result of
        Just session -> do
          let (_, _, name) = if player == Red 
                               then gamePlayer1 session 
                               else gamePlayer2 session
          broadcastChat state session name text
        Nothing -> return ()
    
    Just LeaveGame -> do
      logInfo $ "Player resigned from game #" ++ show gameId
      resignGame state gameId player
    
    Just Ping -> sendMessage conn Pong
    
    _ -> sendMessage conn (ErrorMsg "Invalid message")

-- ============================================================
-- Process Move
-- ============================================================

processMove :: ServerState -> GameId -> Player -> Int 
            -> STM (Either Text (GameSession, GameState))
processMove state gameId player column = do
  gamesMap <- readTVar (games state)
  case Map.lookup gameId gamesMap of
    Nothing -> return $ Left "Game not found"
    Just session -> do
      currentState <- readTVar (gameState session)
      
      -- Validate turn
      if currentPlayer currentState /= player
        then return $ Left "Not your turn"
        else
          -- Validate move
          case validateMove column of
            Left err -> return $ Left err
            Right validCol ->
              case makeMove (board currentState) validCol player of
                Nothing -> return $ Left "Invalid move - column full"
                Just newBoard -> do
                  let newState = currentState
                        { board = newBoard
                        , currentPlayer = nextPlayer player
                        , moveHistory = validCol : moveHistory currentState
                        , gameStatus = getGameResult newBoard
                        , moveCount = moveCount currentState + 1
                        }
                  writeTVar (gameState session) newState
                  return $ Right (session, newState)

-- ============================================================
-- Broadcast & Communication
-- ============================================================

broadcastGameUpdate :: ServerState -> GameSession -> GameState -> IO ()
broadcastGameUpdate state session newState = do
  let (_, conn1, _) = gamePlayer1 session
  let (_, conn2, _) = gamePlayer2 session
  sendMessage conn1 (GameUpdate newState)
  sendMessage conn2 (GameUpdate newState)

broadcastChat :: ServerState -> GameSession -> PlayerName -> Text -> IO ()
broadcastChat state session senderName text = do
  let (_, conn1, _) = gamePlayer1 session
  let (_, conn2, _) = gamePlayer2 session
  let chatMsg = ChatReceived senderName text
  sendMessage conn1 chatMsg
  sendMessage conn2 chatMsg

-- ============================================================
-- Game Over Handling
-- ============================================================

checkGameOver :: ServerState -> GameId -> GameSession -> GameState -> IO ()
checkGameOver state gameId session newState = do
  when (isGameOver (board newState)) $ do
    let (_, conn1, name1) = gamePlayer1 session
    let (_, conn2, name2) = gamePlayer2 session
    
    let result = GameResult
          { resultWinner = case gameStatus newState of
              Winner p -> Just p
              _ -> Nothing
          , resultReason = case gameStatus newState of
              Winner _ -> NormalWin
              Draw -> BoardFull
              _ -> BoardFull
          , resultMoveCount = moveCount newState
          , resultPlayer1Name = name1
          , resultPlayer2Name = name2
          }
    
    sendMessage conn1 (GameOver result)
    sendMessage conn2 (GameOver result)
    
    logInfo $ "🏁 Game #" ++ show gameId ++ " finished: " ++ show (resultWinner result)
    
    -- Cleanup
    endGame state gameId

-- ============================================================
-- Helpers
-- ============================================================

sendMessage :: WS.Connection -> Message -> IO ()
sendMessage conn msg = WS.sendTextData conn (encode msg)
  `catch` \(e :: SomeException) -> logError $ "Send failed: " ++ show e

getGameSession :: ServerState -> GameId -> STM (Maybe GameSession)
getGameSession state gameId = Map.lookup gameId <$> readTVar (games state)

resignGame :: ServerState -> GameId -> Player -> IO ()
resignGame state gameId player = do
  result <- atomically $ getGameSession state gameId
  case result of
    Just session -> do
      let winner = nextPlayer player
      let (_, conn1, name1) = gamePlayer1 session
      let (_, conn2, name2) = gamePlayer2 session
      let result = GameResult (Just winner) Resignation 0 name1 name2
      sendMessage conn1 (GameOver result)
      sendMessage conn2 (GameOver result)
      endGame state gameId
    Nothing -> return ()

endGame :: ServerState -> GameId -> IO ()
endGame state gameId = atomically $ do
  modifyTVar' (games state) (Map.delete gameId)
  modifyTVar' (serverStats state) $ \s -> s 
    { activeGames = activeGames s - 1
    , completedGames = completedGames s + 1
    }

monitorTimeout :: ServerState -> GameId -> GameSession -> IO ()
monitorTimeout state gameId session = return ()  -- TODO: implement timeout

handlePlayerDisconnect :: ServerState -> GameId -> ClientId -> IO ()
handlePlayerDisconnect state gameId clientId = do
  logInfo $ "Client #" ++ show clientId ++ " disconnected from game #" ++ show gameId
  resignGame state gameId Red  -- TODO: determine correct player

cleanupClient :: ServerState -> ClientId -> IO ()
cleanupClient state clientId = atomically $ do
  modifyTVar' (connections state) (Map.delete clientId)
  modifyTVar' (waitingPlayers state) (filter (\w -> waitingClientId w /= clientId))

-- ============================================================
-- Logging & Stats
-- ============================================================

logInfo :: String -> IO ()
logInfo msg = do
  putStrLn $ "[INFO] " ++ msg
  hFlush stdout

logError :: String -> IO ()
logError msg = do
  putStrLn $ "[ERROR] " ++ msg
  hFlush stdout

reportStats :: ServerState -> IO ()
reportStats state = forever $ do
  threadDelay 30000000  -- 30 seconds
  stats <- atomically $ readTVar (serverStats state)
  logInfo $ "📊 Stats: " ++ show (activeGames stats) ++ " active games, " 
         ++ show (completedGames stats) ++ " completed"

handleException :: SomeException -> IO ()
handleException e = logError $ "Exception: " ++ show e

threadDelay :: Int -> IO ()
threadDelay = Control.Concurrent.threadDelay