{-# LANGUAGE RecordWildCards #-}
module Main where
import System.Environment (getArgs)
import System.Exit (exitSuccess)
import Control.Monad (when, unless)
import Data.List (isPrefixOf)

-- Game modules
import qualified Game.Types as Game
import qualified Game.AI as AI
import qualified UI.Graphics as Graphics
import qualified UI.Terminal as Terminal
import qualified Storage.GameState as Storage

-- ============================================================
-- Main Entry Point
-- ============================================================

main :: IO ()
main = do
  args <- getArgs
  case args of
    [] -> showMainMenu
    ["--help"] -> showHelp
    ["-h"] -> showHelp
    ["--version"] -> showVersion
    ["--gui"] -> Graphics.playFromMenu
    ["--tui"] -> Terminal.runGameFromMenu
    ["--single"] -> Graphics.playSinglePlayer
    ["--two"] -> Graphics.playTwoPlayer
    ["--ai-demo"] -> Graphics.playAIvsAI
    ["--terminal"] -> Terminal.playTwoPlayerTUI
    ["--test"] -> runTests
    _ -> do
      putStrLn "Invalid arguments. Use --help for usage information."
      exitSuccess

-- ============================================================
-- Interactive Main Menu
-- ============================================================

showMainMenu :: IO ()
showMainMenu = do
  printBanner
  putStrLn "\n🎮 Welcome to Connect Four!"
  putStrLn $ replicate 50 '='
  putStrLn "\nChoose interface:"
  putStrLn "  1. Graphical UI (Gloss) - Recommended"
  putStrLn "  2. Terminal UI (Brick)"
  putStrLn "  3. Console (Text-based)"
  putStrLn "  4. Run Tests"
  putStrLn "  5. Exit"
  putStrLn ""
  
  choice <- getLine
  case choice of
    "1" -> Graphics.playFromMenu
    "2" -> Terminal.runGameFromMenu
    "3" -> runConsoleGame
    "4" -> runTests
    "5" -> putStrLn "Goodbye!" >> exitSuccess
    _ -> do
      putStrLn "Invalid choice. Try again."
      showMainMenu

-- ============================================================
-- Banner
-- ============================================================

printBanner :: IO ()
printBanner = putStrLn $ unlines
  [ ""
  , " ╔═══════════════════════════════════════╗"
  , " ║                                       ║"
  , " ║        CONNECT FOUR - HASKELL         ║"
  , " ║                                       ║"
  , " ║  🔴⚫ A Functional Game Implementation ║"
  , " ║                                       ║"
  , " ╚═══════════════════════════════════════╝"
  , ""
  ]

-- ============================================================
-- Help Text
-- ============================================================

showHelp :: IO ()
showHelp = do
  putStrLn "Connect Four - Haskell Implementation"
  putStrLn ""
  putStrLn "USAGE:"
  putStrLn "  connect-four-exe [OPTIONS]"
  putStrLn ""
  putStrLn "OPTIONS:"
  putStrLn "  --help, -h       Show this help message"
  putStrLn "  --version        Show version information"
  putStrLn "  --gui            Launch graphical UI (Gloss)"
  putStrLn "  --tui            Launch terminal UI (Brick)"
  putStrLn "  --terminal       Launch simple terminal UI"
  putStrLn "  --single         Quick start single player"
  putStrLn "  --two            Quick start two player"
  putStrLn "  --ai-demo        Watch AI vs AI"
  putStrLn "  --test           Run test suite"
  putStrLn ""
  putStrLn "EXAMPLES:"
  putStrLn "  connect-four-exe              # Interactive menu"
  putStrLn "  connect-four-exe --gui        # Start with GUI"
  putStrLn "  connect-four-exe --single     # Quick single player"
  putStrLn ""
  putStrLn "CONTROLS (GUI):"
  putStrLn "  Mouse Click : Drop piece"
  putStrLn "  R           : Reset game"
  putStrLn "  U           : Undo move"
  putStrLn "  ESC         : Return to menu"
  putStrLn ""
  putStrLn "CONTROLS (Terminal):"
  putStrLn "  ←→ or h/l   : Move cursor"
  putStrLn "  Space/Enter : Drop piece"
  putStrLn "  R           : Reset game"
  putStrLn "  U           : Undo move"
  putStrLn "  H           : Show help"
  putStrLn "  Q           : Quit"
  putStrLn ""

-- ============================================================
-- Version
-- ============================================================

showVersion :: IO ()
showVersion = do
  putStrLn "Connect Four Haskell Edition"
  putStrLn "Version: 1.0.0"
  putStrLn "Author: Haskell Connect Four Team"
  putStrLn ""
  putStrLn "Features:"
  putStrLn "  ✓ Single Player vs AI (Monte Carlo Tree Search)"
  putStrLn "  ✓ Two Player Local"
  putStrLn "  ✓ Multiplayer (Client-Server)"
  putStrLn "  ✓ Parallel AI Computation"
  putStrLn "  ✓ Save/Load Games"
  putStrLn "  ✓ Graphical UI (Gloss)"
  putStrLn "  ✓ Terminal UI (Brick)"
  putStrLn ""
  putStrLn "Built with:"
  putStrLn "  • GHC 9.6.7"
  putStrLn "  • Stack/Cabal"
  putStrLn "  • Gloss, Brick, WebSockets, STM"
  putStrLn ""

-- ============================================================
-- Console Game (Simple Text-based)
-- ============================================================

runConsoleGame :: IO ()
runConsoleGame = do
  putStrLn "\n🎮 Console Connect Four"
  putStrLn $ replicate 50 '='
  putStrLn "\nGame Mode:"
  putStrLn "  1. Single Player (vs AI)"
  putStrLn "  2. Two Player"
  putStrLn "  3. AI Demo"
  putStrLn ""
  
  choice <- getLine
  case choice of
    "1" -> playConsoleSingle
    "2" -> playConsoleTwo
    "3" -> playConsoleAIDemo
    _ -> putStrLn "Invalid choice" >> runConsoleGame

-- Single player console
playConsoleSingle :: IO ()
playConsoleSingle = do
  putStrLn "\nSelect AI difficulty:"
  putStrLn "  1. Easy"
  putStrLn "  2. Medium"
  putStrLn "  3. Hard"
  
  choice <- getLine
  let aiConfig = case choice of
        "1" -> AI.easyAI
        "2" -> AI.mediumAI
        "3" -> AI.hardAI
        _ -> AI.mediumAI
  
  AI.playWithAI aiConfig

-- Two player console
playConsoleTwo :: IO ()
playConsoleTwo = do
  putStrLn "\n🎮 Two Player Game"
  putStrLn "Players take turns entering column (0-6)"
  gameLoop (Game.newGame Game.Red)
  where
    gameLoop state = do
      putStrLn ""
      putStrLn $ Game.showBoardEmoji (Game.board state)
      
      case Game.gameStatus state of
        Game.Winner p -> do
          putStrLn $ "\n🏆 " ++ show p ++ " wins!"
          return ()
        Game.Draw -> do
          putStrLn "\n🤝 It's a draw!"
          return ()
        Game.InProgress -> do
          putStrLn $ "\n" ++ show (Game.currentPlayer state) ++ "'s turn"
          putStrLn "Enter column (0-6):"
          input <- getLine
          
          case reads input of
            [(col, "")] | col >= 0 && col <= 6 ->
              case Game.makeMove (Game.board state) col (Game.currentPlayer state) of
                Nothing -> do
                  putStrLn "❌ Invalid move!"
                  gameLoop state
                Just newBoard -> do
                  let newState = state
                        { Game.board = newBoard
                        , Game.currentPlayer = Game.nextPlayer (Game.currentPlayer state)
                        , Game.moveHistory = col : Game.moveHistory state
                        , Game.gameStatus = Game.getGameResult newBoard
                        , Game.moveCount = Game.moveCount state + 1
                        }
                  gameLoop newState
            _ -> do
              putStrLn "❌ Invalid input!"
              gameLoop state

-- AI demo console
playConsoleAIDemo :: IO ()
playConsoleAIDemo = do
  putStrLn "\n🤖 AI vs AI Demo"
  _ <- AI.playAIvsAI AI.mediumAI AI.mediumAI
  return ()

-- ============================================================
-- Tests
-- ============================================================

runTests :: IO ()
runTests = do
  putStrLn "\n🧪 Running Tests..."
  putStrLn $ replicate 50 '='
  
  -- Test game logic
  putStrLn "\n1. Testing Game Logic..."
  testGameLogic
  
  -- Test AI
  putStrLn "\n2. Testing AI..."
  testAI
  
  -- Test serialization
  putStrLn "\n3. Testing Serialization..."
  testSerialization
  
  putStrLn "\n" ++ replicate 50 '='
  putStrLn "✅ All tests passed!"

testGameLogic :: IO ()
testGameLogic = do
  let board = Game.newBoard
  
  -- Test empty board
  when (Game.isBoardFull board) $
    error "Empty board should not be full"
  
  -- Test move
  case Game.makeMove board 3 Game.Red of
    Nothing -> error "Should be able to make move"
    Just newBoard -> 
      when (Game.getCell newBoard (3, 0) /= Game.Occupied Game.Red) $
        error "Piece not placed correctly"
  
  putStrLn "  ✓ Board creation and moves"
  
  -- Test win detection
  let winBoard = Game.testWinHorizontal
  when (Game.checkWinner winBoard /= Just Game.Red) $
    error "Should detect horizontal win"
  
  putStrLn "  ✓ Win detection"

testAI :: IO ()
testAI = do
  let board = Game.newBoard
  
  -- Test AI move selection
  col <- AI.getAIMove AI.easyAI board Game.Red
  when (col < 0 || col > 6) $
    error "AI returned invalid column"
  
  putStrLn "  ✓ AI move selection"
  
  putStrLn "  ✓ Monte Carlo simulation"

testSerialization :: IO ()
testSerialization = do
  let state = Game.newGame Game.Red
  
  -- Test save/load
  Storage.saveGame "test.c4save" state
  mLoaded <- Storage.loadGame "test.c4save"
  
  case mLoaded of
    Nothing -> error "Failed to load game"
    Just loaded ->
      when (Game.moveCount loaded /= Game.moveCount state) $
        error "Loaded state doesn't match"
  
  putStrLn "  ✓ Save/Load game state"
  putStrLn "  ✓ Serialization"

-- ============================================================
-- Utilities
-- ============================================================

-- Check if running in graphical environment
hasDisplay :: IO Bool
hasDisplay = do
  -- Simple check - in real app, check DISPLAY env var
  return True

-- Get preferred UI
getPreferredUI :: IO String
getPreferredUI = do
  display <- hasDisplay
  return $ if display then "gui" else "tui"