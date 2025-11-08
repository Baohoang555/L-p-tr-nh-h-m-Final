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
import Control.Exception (finally, catch, SomeException) -- Thêm Exception
import Game.Types
import Game.Board
import Game.Rules
import Network.Protocol
-- Xóa import Storage.Statistics không dùng đến

-- Server state chứa các game sessions
data ServerState = ServerState
  { games :: TVar (Map GameId GameSession)
  -- ✅ SỬA LỖI 1: Hàng chờ lưu cả (Connection, Tên)
  , waitingPlayers :: TVar [(WS.Connection, PlayerName)]
  -- ✅ SỬA LỖI 2: Thêm TVar cho GameId để tránh race condition
  , nextGameId :: TVar GameId
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
  -- ✅ SỬA LỖI 2: Khởi tạo nextGameId
  nextIdVar <- newTVarIO 0
  return ServerState { games = gamesVar, waitingPlayers = waitingVar, nextGameId = nextIdVar }

-- Chạy WebSocket server
runServer :: Int -> IO ()
runServer port = do
  putStrLn $ "🎮 Connect Four Server running on port " ++ show port
  serverState <- newServerState
  WS.runServer "0.0.0.0" port $ \pending -> do
    conn <- WS.acceptRequest pending
    WS.withPingThread conn 30 (return ()) $ do
      -- ✅ SỬA LỖI 3: Bọc handleClient trong 'finally' để dọn dẹp
      handleClient serverState conn `finally` (cleanupClient serverState conn)

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
        -- ✅ SỬA LỖI 1: Thêm (conn, playerName) vào hàng chờ
        modifyTVar' (waitingPlayers serverState) ((conn, playerName) :)
        return Nothing
      -- ✅ SỬA LỖI 1: Lấy ra (opponentConn, opponentName)
      ((opponentConn, opponentName):rest) -> do
        -- Có người chờ, bắt đầu game
        writeTVar (waitingPlayers serverState) rest
        return (Just (opponentConn, opponentName))
  
  case mOpponent of
    Nothing -> do
      sendMessage conn WaitingForOpponent
      -- Chờ game, hoặc ngắt kết nối
      waitForGame serverState conn playerName
    -- ✅ SỬA LỖI 1: Lấy được opponentName
    Just (opponentConn, opponentName) -> do
      -- Tạo game mới
      gameId <- atomically $ do
        -- ✅ SỬA LỖI 2: Lấy ID an toàn
        gid <- readTVar (nextGameId serverState)
        let newId = gid + 1
        writeTVar (nextGameId serverState) newId
        return newId
      
      -- ✅ SỬA LỖI 1: Truyền opponentName
      startGame serverState gameId conn playerName opponentConn opponentName

-- Chờ đối thủ (hoặc ngắt kết nối)
waitForGame :: ServerState -> WS.Connection -> PlayerName -> IO ()
waitForGame serverState conn playerName = do
  -- ✅ SỬA LỖI 6 (từ file trước): Xử lý ngắt kết nối khi đang chờ
  (forever $ WS.receiveData conn >> return ()) 
    `catch` (\(e :: SomeException) -> putStrLn $ "Waiting player " ++ T.unpack playerName ++ " disconnected: " ++ show e)
    `finally` (cleanupClient serverState conn) -- Tự động xóa khỏi hàng chờ

-- Dọn dẹp client khi ngắt kết nối (dù ở hàng chờ hay trong game)
cleanupClient :: ServerState -> WS.Connection -> IO ()
cleanupClient serverState conn = do
  putStrLn "Client disconnected. Cleaning up..."
  -- Xóa client khỏi hàng chờ (nếu có)
  atomically $ do
    modifyTVar' (waitingPlayers serverState) (filter (\(c, _) -> c /= conn))

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
  
  -- Gửi thông báo bắt đầu game
  sendMessage conn1 (OpponentConnected name2)
  sendMessage conn2 (OpponentConnected name1)
  
  -- Gửi trạng thái game ban đầu
  sendMessage conn1 (GameUpdate initialState)
  sendMessage conn2 (GameUpdate initialState)
  
  putStrLn $ "Game " ++ show gameId ++ " started: " 
    ++ T.unpack name1 ++ " (Red) vs " ++ T.unpack name2 ++ " (Black)"
  
  -- Xử lý moves từ cả 2 players
  -- ✅ SỬA LỖI 3: Thêm 'finally' để xử lý ngắt kết nối
  forkIO $ (handleGameMessages serverState gameId conn1 Red) 
           `finally` (handleDisconnect serverState gameId Red)
  forkIO $ (handleGameMessages serverState gameId conn2 Black) 
           `finally` (handleDisconnect serverState gameId Black)
  return ()

-- Xử lý messages trong game
handleGameMessages :: ServerState -> GameId -> WS.Connection 
                   -> Player -> IO ()
handleGameMessages serverState gameId conn player = do
  forever $ do
    msg <- WS.receiveData conn
    case decode msg of
      Just (MakeMove column) -> do
        -- Biến kết quả (result) để lưu (session, newState)
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
                          , gameStatus = getGameResult newBoard -- Cập nhật trạng thái
                          , moveCount = moveCount state + 1 -- Cập nhật lượt
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
            
            -- Kiểm tra thắng/thua/hòa
            case gameStatus newState of
              Winner winner -> do
                putStrLn $ "Game " ++ show gameId ++ " finished. Winner: " ++ show winner
                let (conn1, name1) = player1 session
                let (conn2, name2) = player2 session
                let resultMsg = GameResult 
                      { resultWinner = Just winner
                      , resultReason = NormalWin
                      , resultMoveCount = moveCount newState
                      , resultPlayer1Name = name1
                      , resultPlayer2Name = name2
                      }
                sendMessage conn1 (GameOver resultMsg)
                sendMessage conn2 (GameOver resultMsg)
                -- Remove game
                atomically $ modifyTVar' (games serverState) (Map.delete gameId)
              
              Draw -> do
                putStrLn $ "Game " ++ show gameId ++ " finished. Draw."
                let (conn1, name1) = player1 session
                let (conn2, name2) = player2 session
                let resultMsg = GameResult 
                      { resultWinner = Nothing
                      , resultReason = BoardFull
                      , resultMoveCount = moveCount newState
                      , resultPlayer1Name = name1
                      , resultPlayer2Name = name2
                      }
                sendMessage conn1 (GameOver resultMsg)
                sendMessage conn2 (GameOver resultMsg)
                -- Remove game
                atomically $ modifyTVar' (games serverState) (Map.delete gameId)

              InProgress -> return () -- Game tiếp tục
      
      -- ✅ SỬA LỖI 4: Cài đặt Chat
      Just (ChatMessage text) -> do
        mSession <- atomically $ Map.lookup gameId <$> readTVar (games serverState)
        case mSession of
          Nothing -> return ()
          Just session -> do
            let (senderName, conn1, conn2) = if player == Red
                                               then (snd $ player1 session, fst $ player1 session, fst $ player2 session)
                                               else (snd $ player2 session, fst $ player2 session, fst $ player1 session)
            sendMessage conn1 (ChatReceived senderName text)
            sendMessage conn2 (ChatReceived senderName text)
      
      Just LeaveGame -> do
        putStrLn $ "Player " ++ show player ++ " left game " ++ show gameId
        handleDisconnect serverState gameId player
        
      _ -> sendMessage conn (ErrorMsg "Invalid message")

-- ✅ SỬA LỖI 3: Hàm xử lý ngắt kết nối
handleDisconnect :: ServerState -> GameId -> Player -> IO ()
handleDisconnect serverState gameId player = do
  putStrLn $ "Player " ++ show player ++ " from game " ++ show gameId ++ " disconnected."
  -- Lấy session và xóa game khỏi Map
  mSession <- atomically $ do
    mSess <- Map.lookup gameId <$> readTVar (games serverState)
    modifyTVar' (games serverState) (Map.delete gameId) -- Xóa game
    return mSess
  
  case mSession of
    Nothing -> return () -- Game đã kết thúc
    Just session -> do
      let (conn1, name1) = player1 session
      let (conn2, name2) = player2 session
      
      -- Xác định người chơi còn lại và gửi thông báo
      let (opponentConn, reason) = if player == Red
                                    then (conn2, Disconnection) -- Player 1 (Red) ngắt kết nối
                                    else (conn1, Disconnection) -- Player 2 (Black) ngắt kết nối
      
      let winner = opponent player -- Người chơi còn lại thắng
      let result = GameResult (Just winner) reason 0 name1 name2
      
      -- Cố gắng thông báo cho người chơi còn lại
      catch (sendMessage opponentConn (GameOver result)) 
            (\(e :: SomeException) -> putStrLn $ "Failed to notify opponent: " ++ show e)

-- Helper: gửi message
sendMessage :: WS.Connection -> Message -> IO ()
sendMessage conn msg = 
  catch (WS.sendTextData conn (encode msg))
        (\(e :: SomeException) -> putStrLn $ "Failed to send message: " ++ show e)

-- Helper: đối thủ
opponent :: Player -> Player
opponent Red = Black
opponent Black = Red