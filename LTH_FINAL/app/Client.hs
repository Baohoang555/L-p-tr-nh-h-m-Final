module Main where

import System.Environment (getArgs)
import System.Exit (exitSuccess, exitFailure)
import Control.Monad (when, unless, forever)
import Control.Concurrent (forkIO, threadDelay)
import Data.Text (Text)
import qualified Data.Text as T
import qualified Data.Text.IO as TIO

import qualified Network.Client as Client
import qualified Game.Types as Game
import System.IO (hFlush, stdout)
import Control.Exception (catch, SomeException)
import qualified Game.Board as Board

-- ============================================================
-- Client Configuration
-- ============================================================

data ClientConfig = ClientConfig
  { serverHost :: String
  , serverPort :: Int
  , playerName :: String
  , autoReconnect :: Bool
  } deriving (Show)

defaultConfig :: ClientConfig
defaultConfig = ClientConfig
  { serverHost = "localhost"
  , serverPort = 9160
  , playerName = "Player"
  , autoReconnect = True
  }

-- ============================================================
-- Main Entry Point
-- ============================================================

main :: IO ()
main = do
  args <- getArgs
  config <- parseArgs args
  
  printClientBanner
  printConfig config
  
  -- Connect to server
  result <- Client.connectToServer 
    (serverHost config) 
    (serverPort config) 
    (T.pack $ playerName config)
    (createCallbacks config)
  
  case result of
    Left err -> do
      putStrLn $ "❌ Connection failed: " ++ err
      exitFailure
    Right clientState -> do
      putStrLn "✅ Connected to server!"
      
      -- Start interactive session
      runInteractiveSession clientState

-- ============================================================
-- Argument Parsing
-- ============================================================

parseArgs :: [String] -> IO ClientConfig
parseArgs args = do
  when ("--help" `elem` args || "-h" `elem` args) $ do
    showHelp
    exitSuccess
  
  let host = parseArg args "--host" (serverHost defaultConfig)
  let port = parseArg args "--port" (serverPort defaultConfig)
  let name = parseArg args "--name" (playerName defaultConfig)
  let reconnect = not ("--no-reconnect" `elem` args)
  
  return ClientConfig
    { serverHost = host
    , serverPort = port
    , playerName = name
    , autoReconnect = reconnect
    }

parseArg :: Read a => [String] -> String -> a -> a
parseArg args flag defaultVal =
  case dropWhile (/= flag) args of
    (_:val:_) -> read val
    _ -> defaultVal

-- ============================================================
-- Banner & Info
-- ============================================================

printClientBanner :: IO ()
printClientBanner = putStrLn $ unlines
  [ ""
  , " ╔══════════════════════════════════════════╗"
  , " ║                                          ║"
  , " ║      CONNECT FOUR - MULTIPLAYER CLIENT  ║"
  , " ║                                          ║"
  , " ║  🎮 WebSocket Client for Online Play    ║"
  , " ║                                          ║"
  , " ╚══════════════════════════════════════════╝"
  , ""
  ]

printConfig :: ClientConfig -> IO ()
printConfig config = do
  putStrLn "📋 Client Configuration:"
  putStrLn $ replicate 50 '-'
  putStrLn $ "  Server:      " ++ serverHost config ++ ":" ++ show (serverPort config)
  putStrLn $ "  Player Name: " ++ playerName config
  putStrLn $ "  Auto-reconnect: " ++ if autoReconnect config then "Yes" else "No"
  putStrLn $ replicate 50 '-'
  putStrLn ""

showHelp :: IO ()
showHelp = putStrLn $ unlines
  [ "Connect Four Client"
  , ""
  , "USAGE:"
  , "  connect-four-client [OPTIONS]"
  , ""
  , "OPTIONS:"
  , "  --help, -h          Show this help message"
  , "  --host HOST         Server hostname (default: localhost)"
  , "  --port PORT         Server port (default: 9160)"
  , "  --name NAME         Your player name (default: Player)"
  , "  --no-reconnect      Disable automatic reconnection"
  , ""
  , "EXAMPLES:"
  , "  connect-four-client                           # Connect to localhost"
  , "  connect-four-client --host game.example.com   # Connect to remote server"
  , "  connect-four-client --name Alice --port 8080  # Custom name and port"
  , ""
  , "IN-GAME COMMANDS:"
  , "  0-6         : Drop piece in column"
  , "  chat <msg>  : Send chat message"
  , "  quit        : Disconnect and quit"
  , "  help        : Show help"
  , ""
  ]

-- ============================================================
-- Callbacks
-- ============================================================

createCallbacks :: ClientConfig -> Client.ClientCallbacks
createCallbacks config = Client.ClientCallbacks
  { Client.onGameUpdate = handleGameUpdate
  , Client.onGameOver = handleGameOver
  , Client.onOpponentConnected = handleOpponentConnected
  , Client.onOpponentDisconnected = handleOpponentDisconnected
  , Client.onError = handleError
  , Client.onChatReceived = handleChatReceived
  , Client.onWaitingForOpponent = handleWaitingForOpponent
  }

handleGameUpdate :: Game.GameState -> IO ()
handleGameUpdate state = do
  putStrLn "\n" ++ replicate 50 '='
  putStrLn "📊 Game Update:"
  putStrLn $ Game.showBoardEmoji (Game.board state)
  putStrLn $ "Current player: " ++ show (Game.currentPlayer state)
  putStrLn $ "Move #" ++ show (Game.moveCount state)
  
  case Game.gameStatus state of
    Game.Winner p -> putStrLn $ "🏆 " ++ show p ++ " wins!"
    Game.Draw -> putStrLn "🤝 Draw!"
    Game.InProgress -> putStrLn "\n> Your turn! Enter column (0-6):"

handleGameOver :: Client.GameResult -> IO ()
handleGameOver result = do
  putStrLn "\n" ++ replicate 50 '='
  putStrLn "🏁 GAME OVER"
  putStrLn $ replicate 50 '='
  
  case Client.resultWinner result of
    Just player -> putStrLn $ "🏆 Winner: " ++ show player
    Nothing -> putStrLn "🤝 It's a draw!"
  
  putStrLn $ "Reason: " ++ show (Client.resultReason result)
  putStrLn $ "Total moves: " ++ show (Client.resultMoveCount result)
  putStrLn $ Client.resultPlayer1Name result ++ " vs " ++ Client.resultPlayer2Name result
  putStrLn $ replicate 50 '='
  putStrLn "\nType 'rematch' to play again or 'quit' to exit"

handleOpponentConnected :: Text -> IO ()
handleOpponentConnected name = do
  putStrLn $ "\n✅ Opponent connected: " ++ T.unpack name
  putStrLn "🎮 Game starting..."

handleOpponentDisconnected :: IO ()
handleOpponentDisconnected = do
  putStrLn "\n❌ Opponent disconnected!"
  putStrLn "You win by default."

handleError :: Text -> IO ()
handleError err = do
  putStrLn $ "\n❌ Error: " ++ T.unpack err

handleChatReceived :: Text -> Text -> IO ()
handleChatReceived sender msg = do
  putStrLn $ "\n💬 [" ++ T.unpack sender ++ "]: " ++ T.unpack msg

handleWaitingForOpponent :: IO ()
handleWaitingForOpponent = do
  putStrLn "\n⏳ Waiting for opponent to connect..."
  putStrLn "Please wait..."

-- ============================================================
-- Interactive Session
-- ============================================================

runInteractiveSession :: Client.ClientState -> IO ()
runInteractiveSession clientState = do
  putStrLn "\n🎮 Interactive Mode"
  putStrLn "Type 'help' for commands\n"
  
  -- Start ping thread to keep connection alive
  forkIO $ pingLoop clientState
  
  -- Main input loop
  forever $ do
    putStr "> "
    hFlush stdout
    input <- getLine
    handleCommand clientState input

-- Handle user commands
handleCommand :: Client.ClientState -> String -> IO ()
handleCommand state input = case words input of
  [] -> return ()
  
  ["help"] -> showGameHelp
  
  ["quit"] -> do
    Client.disconnect state
    putStrLn "👋 Goodbye!"
    exitSuccess
  
  ["status"] -> showStatus state
  
  ("chat":rest) -> do
    let msg = T.pack $ unwords rest
    Client.sendChat state msg
  
  ["rematch"] -> Client.requestRematch state
  
  [col] | all (`elem` "0123456") col && length col == 1 -> do
    let column = read col :: Int
    Client.makeMove state column
  
  _ -> putStrLn "Unknown command. Type 'help' for commands."

-- Show in-game help
showGameHelp :: IO ()
showGameHelp = putStrLn $ unlines
  [ "\n📖 Commands:"
  , "  0-6         - Drop piece in column"
  , "  chat <msg>  - Send chat message"
  , "  status      - Show game status"
  , "  rematch     - Request rematch after game"
  , "  help        - Show this help"
  , "  quit        - Disconnect and exit"
  , ""
  ]

-- Show current status
showStatus :: Client.ClientState -> IO ()
showStatus state = do
  status <- Client.getConnectionStatus state
  opponent <- Client.getOpponentName state
  
  putStrLn "\n📊 Status:"
  putStrLn $ "  Connection: " ++ show status
  putStrLn $ "  Opponent: " ++ maybe "None" T.unpack opponent
  
  mGameState <- Client.getGameState state
  case mGameState of
    Nothing -> putStrLn "  Game: Not started"
    Just gs -> do
      putStrLn $ "  Current player: " ++ show (Game.currentPlayer gs)
      putStrLn $ "  Moves: " ++ show (Game.moveCount gs)
      putStrLn $ "  Status: " ++ show (Game.gameStatus gs)

-- Ping loop to keep connection alive
pingLoop :: Client.ClientState -> IO ()
pingLoop state = forever $ do
  threadDelay (10 * 1000000)  -- Every 10 seconds
  Client.sendPing state
  `catch` \(_ :: SomeException) -> return ()

