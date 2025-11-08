module Main where
import Control.Concurrent.STM
import System.Environment (getArgs, lookupEnv)
import System.Exit (exitFailure)
import Control.Monad (when, forever)
import Control.Concurrent (forkIO, threadDelay)
import Data.Maybe (fromMaybe)
import Text.Read (readMaybe)

import qualified Network.Server as Server
import qualified Concurrency.GameManager as GM

-- ============================================================
-- Server Configuration
-- ============================================================

data ServerConfig = ServerConfig
  { serverPort :: Int
  , maxConnections :: Int
  , enableLogging :: Bool
  , enableStats :: Bool
  , moveTimeout :: Int
  } deriving (Show)

defaultConfig :: ServerConfig
defaultConfig = ServerConfig
  { serverPort = 9160
  , maxConnections = 100
  , enableLogging = True
  , enableStats = True
  , moveTimeout = 30
  }

-- ============================================================
-- Main Entry Point
-- ============================================================

main :: IO ()
main = do
  args <- getArgs
  config <- parseArgs args
  
  printServerBanner
  printConfig config
  
  -- Initialize game manager
  let gmConfig = GM.GameManagerConfig
        { GM.maxConcurrentGames = maxConnections config
        , GM.moveTimeoutSeconds = moveTimeout config
        , GM.enableAutoCleanup = True
        , GM.cleanupIntervalSeconds = 60
        }
  
  gameManager <- GM.newGameManager gmConfig
  
  -- Start background services
  when (enableStats config) $
    forkIO $ statsReporter gameManager
  
  when (GM.enableAutoCleanup gmConfig) $
    forkIO $ GM.autoCleanupThread gameManager
  
  -- Start server
  putStrLn $ "\n🚀 Starting server on port " ++ show (serverPort config)
  putStrLn "Press Ctrl+C to stop"
  putStrLn $ replicate 70 '='
  putStrLn ""
  
  Server.runServer (serverPort config)

-- ============================================================
-- Argument Parsing
-- ============================================================

parseArgs :: [String] -> IO ServerConfig
parseArgs args = do
  -- Check for help
  when ("--help" `elem` args || "-h" `elem` args) $ do
    showHelp
    exitFailure
  
  -- Parse arguments
  let port = parseArg args "--port" (serverPort defaultConfig)
  let maxConn = parseArg args "--max-connections" (maxConnections defaultConfig)
  let timeout = parseArg args "--timeout" (moveTimeout defaultConfig)
  let logging = not ("--no-logging" `elem` args)
  let stats = not ("--no-stats" `elem` args)
  
  -- Check environment variables
  envPort <- lookupEnv "C4_PORT"
  let finalPort = maybe port (fromMaybe port . readMaybe) envPort
  
  return ServerConfig
    { serverPort = finalPort
    , maxConnections = maxConn
    , enableLogging = logging
    , enableStats = stats
    , moveTimeout = timeout
    }

-- Parse a specific argument
parseArg :: Read a => [String] -> String -> a -> a
parseArg args flag defaultVal =
  case dropWhile (/= flag) args of
    (_:val:_) -> fromMaybe defaultVal (readMaybe val)
    _ -> defaultVal

-- ============================================================
-- Banner & Info
-- ============================================================

printServerBanner :: IO ()
printServerBanner = putStrLn $ unlines
  [ ""
  , " ╔══════════════════════════════════════════════════════════════════╗"
  , " ║                                                                  ║"
  , " ║            CONNECT FOUR - MULTIPLAYER SERVER                     ║"
  , " ║                                                                  ║"
  , " ║  🌐 WebSocket-based Game Server with Concurrent Game Management ║"
  , " ║                                                                  ║"
  , " ╚══════════════════════════════════════════════════════════════════╝"
  , ""
  ]

printConfig :: ServerConfig -> IO ()
printConfig config = do
  putStrLn "📋 Server Configuration:"
  putStrLn $ replicate 70 '-'
  putStrLn $ "  Port:              " ++ show (serverPort config)
  putStrLn $ "  Max Connections:   " ++ show (maxConnections config)
  putStrLn $ "  Move Timeout:      " ++ show (moveTimeout config) ++ " seconds"
  putStrLn $ "  Logging:           " ++ if enableLogging config then "Enabled" else "Disabled"
  putStrLn $ "  Statistics:        " ++ if enableStats config then "Enabled" else "Disabled"
  putStrLn $ replicate 70 '-'

showHelp :: IO ()
showHelp = putStrLn $ unlines
  [ "Connect Four Server"
  , ""
  , "USAGE:"
  , "  connect-four-server [OPTIONS]"
  , ""
  , "OPTIONS:"
  , "  --help, -h              Show this help message"
  , "  --port PORT             Server port (default: 9160)"
  , "  --max-connections N     Maximum concurrent connections (default: 100)"
  , "  --timeout SECONDS       Move timeout in seconds (default: 30)"
  , "  --no-logging            Disable logging"
  , "  --no-stats              Disable statistics reporting"
  , ""
  , "ENVIRONMENT VARIABLES:"
  , "  C4_PORT                 Server port (overrides --port)"
  , ""
  , "EXAMPLES:"
  , "  connect-four-server                    # Start with defaults"
  , "  connect-four-server --port 8080        # Custom port"
  , "  connect-four-server --max-connections 200"
  , ""
  ]

-- ============================================================
-- Background Services
-- ============================================================

-- Statistics reporter
statsReporter :: GM.GameManager -> IO ()
statsReporter manager = forever $ do
  threadDelay (30 * 1000000)  -- Every 30 seconds
  GM.printStats manager

-- ============================================================
-- Graceful Shutdown
-- ============================================================

-- TODO: Implement graceful shutdown handler
-- - Save active games
-- - Notify connected clients
-- - Close all connections
gracefulShutdown :: GM.GameManager -> IO ()
gracefulShutdown manager = do
  putStrLn "\n⚠️  Shutting down server..."
  
  -- Get active games
  activeGames <- atomically $ GM.countActiveGames manager
  putStrLn $ "  Saving " ++ show activeGames ++ " active games..."
  
  -- TODO: Save games
  
  putStrLn "  Closing connections..."
  -- TODO: Close connections
  
  putStrLn "✅ Server stopped gracefully"

-- ============================================================
-- Health Check
-- ============================================================

data ServerHealth = ServerHealth
  { healthy :: Bool
  , activeGames :: Int
  , totalConnections :: Int
  , uptime :: Int
  } deriving (Show)

checkHealth :: GM.GameManager -> IO ServerHealth
checkHealth manager = do
  games <- atomically $ GM.countActiveGames manager
  stats <- atomically $ GM.getStats manager
  
  return ServerHealth
    { healthy = True
    , activeGames = games
    , totalConnections = GM.totalGamesCreated stats
    , uptime = 0  -- TODO: track uptime
    }

-- ============================================================
-- Admin Commands
-- ============================================================

-- Simple admin interface (for testing)
adminInterface :: GM.GameManager -> IO ()
adminInterface manager = forever $ do
  putStrLn "\nAdmin Commands: stats | games | quit"
  cmd <- getLine
  
  case cmd of
    "stats" -> GM.printStats manager
    "games" -> do
      gameIds <- atomically $ GM.getActiveGameIds manager
      putStrLn $ "Active games: " ++ show gameIds
    "quit" -> do
      gracefulShutdown manager
      exitFailure
    _ -> putStrLn "Unknown command"
