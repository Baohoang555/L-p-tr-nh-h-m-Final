{-# LANGUAGE OverloadedStrings #-}
module Network.Server where

import Control.Concurrent (forkIO)
import Control.Concurrent.STM
import Control.Monad (forever, forM_)
import Data.Aeson (encode, decode)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import qualified Network.WebSockets as WS
import Data.Text (Text)
import qualified Data.Text as T

import Game.Types
import Game.Board
import Game.Rules
import Network.Protocol
import Storage.Statistics (GameStats(..), updateProfile, updateProfileDB)

-- Server state chứa các game sessions
data ServerState = ServerState
  { games :: TVar (Map GameId GameSession)
  , waitingPlayers :: TVar [WS.Connection]
  }

data GameSession = GameSession
  { gameState :: TVar GameState
  , player1 :: (WS.Connection, PlayerName)
  , player2 :: (WS.Connection, PlayerName)
  }

type GameId = Int

-- Khởi tạo server
newServerState :: IO ServerState
newServerState = do
  gamesVar <- newTVarIO Map.empty
  waitingVar <- newTVarIO []
  return ServerState { games = gamesVar, waitingPlayers = waitingVar }

-- Chạy WebSocket server
runServer :: Int -> IO ()
runServer port = do
  putStrLn $ "🎮 Connect Four Server running on port " ++ show port
  serverState <- newServerState
  WS.runServer "0.0.0.0" port $ \pending -> do
    conn <- WS.acceptRequest pending
    WS.withPingThread conn 30 (return ()) $ do
      handleClient serverState conn

-- Xử lý client connection
handleClient :: ServerState -> WS.Connection -> IO ()
handleClient serverState conn = do
  putStrLn "New client connected"
  
  -- Nhận tên player
  msg <- WS.receiveData conn
  case decode msg of
    Just (JoinGame playerName) -> do
      putStrLn $ "Player joined: " ++ T.unpack playerName
      matchPlayer serverState conn playerName
    _ -> do
      sendMessage conn (ErrorMsg "Expected JoinGame message")
      return ()

-- Ghép cặp players
matchPlayer :: ServerState -> WS.Connection -> PlayerName -> IO ()
matchPlayer serverState conn playerName = do
  mOpponent <- atomically $ do
    waiting <- readTVar (waitingPlayers serverState)
    case waiting of
      [] -> do
        -- Không có ai đang chờ, thêm vào queue
        modifyTVar' (waitingPlayers serverState) (conn :)
        return Nothing
      (opponentConn:rest) -> do
        -- Có người chờ, bắt đầu game
        writeTVar (waitingPlayers serverState) rest
        return (Just opponentConn)
  
  case mOpponent of
    Nothing -> do
      sendMessage conn WaitingForOpponent
      waitForGame serverState conn playerName
    Just opponentConn -> do
      -- Tạo game mới
      gameId <- atomically $ do
        gamesMap <- readTVar (games serverState)
        let newId = Map.size gamesMap
        return newId
      
      startGame serverState gameId conn playerName opponentConn "Opponent"

-- Chờ đối thủ
waitForGame :: ServerState -> WS.Connection -> PlayerName -> IO ()
waitForGame serverState conn playerName = do
  -- Logic này sẽ được trigger khi có player khác join
  forever $ WS.receiveData conn >> return ()

-- Bắt đầu game giữa 2 players
startGame :: ServerState -> GameId -> WS.Connection -> PlayerName 
          -> WS.Connection -> PlayerName -> IO ()
startGame serverState gameId conn1 name1 conn2 name2 = do
  -- Tạo game state ban đầu
  initialState <- atomically $ do
    stateVar <- newTVar (newGame Red)
    let session = GameSession
          { gameState = stateVar
          , player1 = (conn1, name1)
          , player2 = (conn2, name2)
          }
    modifyTVar' (games serverState) (Map.insert gameId session)
    return initialState
  
  -- Thông báo cho cả 2 players
  sendMessage conn1 (GameUpdate initialState)
  sendMessage conn2 (GameUpdate initialState)
  
  putStrLn $ "Game " ++ show gameId ++ " started: " 
    ++ T.unpack name1 ++ " vs " ++ T.unpack name2
  
  -- Xử lý moves từ cả 2 players
  forkIO $ handleGameMessages serverState gameId conn1 Red
  forkIO $ handleGameMessages serverState gameId conn2 Black
  return ()

-- Xử lý messages trong game
handleGameMessages :: ServerState -> GameId -> WS.Connection 
                   -> Player -> IO ()
handleGameMessages serverState gameId conn player = do
  forever $ do
    msg <- WS.receiveData conn
    case decode msg of
      Just (MakeMove column) -> do
        result <- atomically $ do
          gamesMap <- readTVar (games serverState)
          case Map.lookup gameId gamesMap of
            Nothing -> return $ Left "Game not found"
            Just session -> do
              state <- readTVar (gameState session)
              -- Kiểm tra lượt chơi
              if currentPlayer state /= player
                then return $ Left "Not your turn"
                else case makeMove (board state) column player of
                  Nothing -> return $ Left "Invalid move"
                  Just newBoard -> do
                    let newState = state 
                          { board = newBoard
                          , currentPlayer = opponent player
                          , moveHistory = column : moveHistory state
                          }
                    writeTVar (gameState session) newState
                    return $ Right (session, newState)
        
        case result of
          Left err -> sendMessage conn (ErrorMsg $ T.pack err)
          Right (session, newState) -> do
            -- Broadcast update cho cả 2 players
            let (conn1, _) = player1 session
            let (conn2, _) = player2 session
            sendMessage conn1 (GameUpdate newState)
            sendMessage conn2 (GameUpdate newState)
            
            -- Kiểm tra thắng/thua
            case checkWinner (board newState) of
              Just winner -> do
                sendMessage conn1 (GameOver (Just winner))
                sendMessage conn2 (GameOver (Just winner))
                -- Remove game
                atomically $ modifyTVar' (games serverState) 
                  (Map.delete gameId)
              Nothing -> 
                if isBoardFull (board newState)
                  then do
                    sendMessage conn1 (GameOver Nothing)
                    sendMessage conn2 (GameOver Nothing)
                  else return ()
      
      Just (ChatMessage text) -> do
        -- Broadcast chat message
        return ()
      
      _ -> sendMessage conn (ErrorMsg "Invalid message")

-- Helper: gửi message
sendMessage :: WS.Connection -> Message -> IO ()
sendMessage conn msg = WS.sendTextData conn (encode msg)

-- Helper: đối thủ
opponent :: Player -> Player
opponent Red = Black
opponent Black = Red