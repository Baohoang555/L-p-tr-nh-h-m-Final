{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards #-}
module Network.Client where

import Control.Concurrent (forkIO, threadDelay, killThread, ThreadId)
import Control.Concurrent.STM
import Control.Monad (forever, when, unless)
import Control.Exception (catch, finally, SomeException, bracket)
import Data.Aeson (encode, decode)
import qualified Network.WebSockets as WS
import Data.Text (Text)
import qualified Data.Text as T
import System.IO (hFlush, stdout)

import Game.Types
import Game.Board
import Network.Protocol

-- ============================================================
-- Client State
-- ============================================================

data ClientState = ClientState
  { clientConnection :: WS.Connection
  , clientPlayerName :: PlayerName
  , currentGameState :: TVar (Maybe GameState)
  , opponentName :: TVar (Maybe PlayerName)
  , connectionStatus :: TVar ConnectionStatus
  , messageQueue :: TQueue Message
  , clientCallbacks :: ClientCallbacks
  }

data ConnectionStatus
  = Disconnected
  | Connecting
  | WaitingForOpponent
  | InGame
  | GameFinished
  deriving (Show, Eq)

-- Callbacks for UI updates
data ClientCallbacks = ClientCallbacks
  { onGameUpdate :: GameState -> IO ()
  , onGameOver :: GameResult -> IO ()
  , onOpponentConnected :: PlayerName -> IO ()
  , onOpponentDisconnected :: IO ()
  , onError :: Text -> IO ()
  , onChatReceived :: PlayerName -> Text -> IO ()
  , onWaitingForOpponent :: IO ()
  }

-- Default callbacks (console output)
defaultCallbacks :: ClientCallbacks
defaultCallbacks = ClientCallbacks
  { onGameUpdate = \state -> do
      putStrLn "\n📊 Game Update:"
      putStrLn $ showBoardEmoji (board state)
      putStrLn $ "Current player: " ++ show (currentPlayer state)
      putStrLn $ "Move count: " ++ show (moveCount state)
  , onGameOver = \result -> do
      putStrLn "\n🏁 Game Over!"
      case resultWinner result of
        Just player -> putStrLn $ "Winner: " ++ show player
        Nothing -> putStrLn "Draw!"
      putStrLn $ "Reason: " ++ show (resultReason result)
  , onOpponentConnected = \name -> 
      putStrLn $ "✅ Opponent connected: " ++ T.unpack name
  , onOpponentDisconnected = 
      putStrLn "❌ Opponent disconnected"
  , onError = \err -> 
      putStrLn $ "❌ Error: " ++ T.unpack err
  , onChatReceived = \sender msg ->
      putStrLn $ "[" ++ T.unpack sender ++ "]: " ++ T.unpack msg
  , onWaitingForOpponent = 
      putStrLn "⏳ Waiting for opponent..."
  }

-- ============================================================
-- Connect to Server
-- ============================================================

-- Connect to server and initialize client
connectToServer :: String -> Int -> PlayerName -> ClientCallbacks -> IO (Either String ClientState)
connectToServer host port playerName callbacks = do
  putStrLn $ "🔌 Connecting to " ++ host ++ ":" ++ show port
  
  -- Validate player name
  case validatePlayerName playerName of
    Left err -> return $ Left $ T.unpack err
    Right validName -> do
      result <- tryConnect host port validName callbacks
      return result
  `catch` handleConnectionError
  where
    handleConnectionError :: SomeException -> IO (Either String ClientState)
    handleConnectionError e = return $ Left $ "Connection failed: " ++ show e

-- Internal connect function
tryConnect :: String -> Int -> PlayerName -> ClientCallbacks -> IO (Either String ClientState)
tryConnect host port playerName callbacks = do
  WS.runClient host port "/" $ \conn -> do
    -- Send JoinGame message
    sendMessage conn (JoinGame playerName)
    
    -- Create client state
    gameStateVar <- newTVarIO Nothing
    opponentVar <- newTVarIO Nothing
    statusVar <- newTVarIO Connecting
    msgQueue <- newTQueueIO
    
    let clientState = ClientState
          { clientConnection = conn
          , clientPlayerName = playerName
          , currentGameState = gameStateVar
          , opponentName = opponentVar
          , connectionStatus = statusVar
          , messageQueue = msgQueue
          , clientCallbacks = callbacks
          }
    
    -- Start message receiver thread
    receiverThread <- forkIO $ receiveMessages clientState
    
    putStrLn "✅ Connected to server"
    
    -- Keep connection alive
    forever $ threadDelay 1000000
    `finally` killThread receiverThread
    
    return $ Right clientState

-- Simplified connect for testing
simpleConnect :: String -> Int -> PlayerName -> IO ClientState
simpleConnect host port playerName = do
  result <- connectToServer host port playerName defaultCallbacks
  case result of
    Left err -> error err
    Right state -> return state

-- ============================================================
-- Message Handling
-- ============================================================

-- Receive messages from server
receiveMessages :: ClientState -> IO ()
receiveMessages state = forever $ do
  msg <- WS.receiveData (clientConnection state)
  case decode msg of
    Just message -> do
      -- Add to queue
      atomically $ writeTQueue (messageQueue state) message
      -- Process immediately
      handleMessage state message
    Nothing -> do
      putStrLn "⚠️  Received invalid message"

-- Handle incoming message
handleMessage :: ClientState -> Message -> IO ()
handleMessage state msg = case msg of
  GameUpdate gameState -> do
    atomically $ writeTVar (currentGameState state) (Just gameState)
    atomically $ writeTVar (connectionStatus state) InGame
    onGameUpdate (clientCallbacks state) gameState
  
  GameOver result -> do
    atomically $ writeTVar (connectionStatus state) GameFinished
    onGameOver (clientCallbacks state) result
  
  WaitingForOpponent -> do
    atomically $ writeTVar (connectionStatus state) WaitingForOpponent
    onWaitingForOpponent (clientCallbacks state)
  
  OpponentConnected name -> do
    atomically $ writeTVar (opponentName state) (Just name)
    onOpponentConnected (clientCallbacks state) name
  
  OpponentDisconnected -> do
    atomically $ writeTVar (opponentName state) Nothing
    onOpponentDisconnected (clientCallbacks state)
  
  ErrorMsg err -> do
    onError (clientCallbacks state) err
  
  ChatReceived sender text -> do
    onChatReceived (clientCallbacks state) sender text
  
  Pong -> return ()  -- Heartbeat response
  
  _ -> putStrLn $ "⚠️  Unhandled message: " ++ show msg

-- ============================================================
-- Send Actions
-- ============================================================

-- Make a move
makeMove :: ClientState -> Column -> IO ()
makeMove state column = do
  status <- atomically $ readTVar (connectionStatus state)
  case status of
    InGame -> do
      case validateMove column of
        Left err -> onError (clientCallbacks state) err
        Right validCol -> sendMessage (clientConnection state) (MakeMove validCol)
    _ -> onError (clientCallbacks state) "Not in game"

-- Send chat message
sendChat :: ClientState -> Text -> IO ()
sendChat state text
  | T.null text = return ()
  | T.length text > 500 = onError (clientCallbacks state) "Message too long"
  | otherwise = sendMessage (clientConnection state) (ChatMessage text)

-- Leave game
leaveGame :: ClientState -> IO ()
leaveGame state = do
  sendMessage (clientConnection state) LeaveGame
  atomically $ writeTVar (connectionStatus state) Disconnected

-- Request rematch
requestRematch :: ClientState -> IO ()
requestRematch state = do
  status <- atomically $ readTVar (connectionStatus state)
  when (status == GameFinished) $
    sendMessage (clientConnection state) RequestRematch

-- Send ping (heartbeat)
sendPing :: ClientState -> IO ()
sendPing state = sendMessage (clientConnection state) Ping

-- ============================================================
-- Client State Queries
-- ============================================================

-- Get current game state
getGameState :: ClientState -> IO (Maybe GameState)
getGameState state = atomically $ readTVar (currentGameState state)

-- Get opponent name
getOpponentName :: ClientState -> IO (Maybe PlayerName)
getOpponentName state = atomically $ readTVar (opponentName state)

-- Get connection status
getConnectionStatus :: ClientState -> IO ConnectionStatus
getConnectionStatus state = atomically $ readTVar (connectionStatus state)

-- Check if in game
isInGame :: ClientState -> IO Bool
isInGame state = do
  status <- getConnectionStatus state
  return $ status == InGame

-- Get message from queue (non-blocking)
pollMessage :: ClientState -> IO (Maybe Message)
pollMessage state = atomically $ tryReadTQueue (messageQueue state)

-- ============================================================
-- Disconnect
-- ============================================================

-- Gracefully disconnect from server
disconnect :: ClientState -> IO ()
disconnect state = do
  putStrLn "👋 Disconnecting from server..."
  leaveGame state
  threadDelay 100000  -- Give time for message to send
  WS.sendClose (clientConnection state) ("Client disconnecting" :: Text)
  atomically $ writeTVar (connectionStatus state) Disconnected
  putStrLn "✅ Disconnected"

-- ============================================================
-- Helper Functions
-- ============================================================

-- Send message to server
sendMessage :: WS.Connection -> Message -> IO ()
sendMessage conn msg = do
  WS.sendTextData conn (encode msg)
  `catch` \(e :: SomeException) -> 
    putStrLn $ "⚠️  Failed to send message: " ++ show e

-- Wait for game to start
waitForGame :: ClientState -> IO ()
waitForGame state = do
  putStrLn "⏳ Waiting for game to start..."
  atomically $ do
    status <- readTVar (connectionStatus state)
    when (status /= InGame) retry

-- Wait for game to end
waitForGameEnd :: ClientState -> IO GameResult
waitForGameEnd state = do
  atomically $ do
    status <- readTVar (connectionStatus state)
    when (status /= GameFinished) retry
  
  -- Get last message from queue (should be GameOver)
  msg <- atomically $ readTQueue (messageQueue state)
  case msg of
    GameOver result -> return result
    _ -> error "Expected GameOver message"

-- ============================================================
-- Interactive Client Session
-- ============================================================

-- Run interactive client session
runInteractiveClient :: String -> Int -> PlayerName -> IO ()
runInteractiveClient host port playerName = do
  putStrLn "\n🎮 Connect Four Client"
  putStrLn $ replicate 50 '='
  
  result <- connectToServer host port playerName defaultCallbacks
  case result of
    Left err -> putStrLn $ "❌ Connection failed: " ++ err
    Right state -> do
      putStrLn "✅ Connected!"
      
      -- Wait for game
      waitForGame state
      
      -- Game loop
      playInteractiveGame state
      
      -- Disconnect
      disconnect state

-- Interactive game loop
playInteractiveGame :: ClientState -> IO ()
playInteractiveGame state = do
  gameState <- getGameState state
  case gameState of
    Nothing -> do
      putStrLn "⚠️  No game state"
      return ()
    Just gs -> do
      -- Check if it's our turn
      -- (In a real implementation, we'd need to track which player we are)
      
      putStrLn "\nYour turn! Enter column (0-6) or 'quit':"
      input <- getLine
      
      case input of
        "quit" -> leaveGame state
        _ -> case reads input of
          [(col, "")] | col >= 0 && col <= 6 -> do
            makeMove state col
            threadDelay 100000  -- Wait for response
            
            status <- getConnectionStatus state
            unless (status == GameFinished) $
              playInteractiveGame state
          _ -> do
            putStrLn "Invalid input"
            playInteractiveGame state

-- ============================================================
-- Reconnection Logic
-- ============================================================

-- Attempt to reconnect with exponential backoff
reconnectWithBackoff :: String -> Int -> PlayerName -> ClientCallbacks -> Int -> IO (Maybe ClientState)
reconnectWithBackoff host port playerName callbacks maxAttempts = 
  tryReconnect 1
  where
    tryReconnect attempt
      | attempt > maxAttempts = do
          putStrLn $ "❌ Failed to reconnect after " ++ show maxAttempts ++ " attempts"
          return Nothing
      | otherwise = do
          putStrLn $ "🔄 Reconnection attempt " ++ show attempt ++ "/" ++ show maxAttempts
          result <- connectToServer host port playerName callbacks
          case result of
            Right state -> do
              putStrLn "✅ Reconnected!"
              return (Just state)
            Left err -> do
              let delay = min (2 ^ attempt * 1000000) 30000000  -- Max 30 seconds
              putStrLn $ "⏳ Waiting " ++ show (delay `div` 1000000) ++ " seconds..."
              threadDelay delay
              tryReconnect (attempt + 1)

-- ============================================================
-- Testing Helpers
-- ============================================================

-- Create test client that connects and waits
testClient :: String -> Int -> String -> IO ()
testClient host port name = do
  state <- simpleConnect host port (T.pack name)
  putStrLn "Press Enter to disconnect..."
  _ <- getLine
  disconnect state

-- Example usage
exampleClient :: IO ()
exampleClient = do
  putStrLn "=== Connect Four Client Example ==="
  runInteractiveClient "localhost" 9160 "Player1"