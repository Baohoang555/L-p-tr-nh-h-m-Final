{-# LANGUAGE RecordWildCards #-}
module Game.AI where

import Game.Types
import Game.Board
import Game.Rules
import qualified Game.AI.MonteCarlo as MCTS
import qualified Game.AI.Parallel as Parallel
import Control.DeepSeq
import Data.Time.Clock

-- ============================================================
-- AI Configuration
-- ============================================================

data AIConfig = AIConfig
  { difficulty :: Difficulty
  , useParallel :: Bool          -- Bật parallel computing
  , thinkingTime :: Maybe Double -- Giới hạn thời gian (seconds)
  , showThinking :: Bool         -- Hiển thị quá trình suy nghĩ
  } deriving (Show)

data Difficulty = Easy | Medium | Hard | Expert
  deriving (Show, Eq, Ord)

-- Default configs
easyAI :: AIConfig
easyAI = AIConfig
  { difficulty = Easy
  , useParallel = False
  , thinkingTime = Nothing
  , showThinking = True
  }

mediumAI :: AIConfig
mediumAI = AIConfig
  { difficulty = Medium
  , useParallel = True
  , thinkingTime = Just 3.0
  , showThinking = True
  }

hardAI :: AIConfig
hardAI = AIConfig
  { difficulty = Hard
  , useParallel = True
  , thinkingTime = Just 5.0
  , showThinking = True
  }

expertAI :: AIConfig
expertAI = AIConfig
  { difficulty = Expert
  , useParallel = True
  , thinkingTime = Just 10.0
  , showThinking = True
  }

-- ============================================================
-- Simulations per Difficulty
-- ============================================================

simulationsForDifficulty :: Difficulty -> Int
simulationsForDifficulty Easy = 100
simulationsForDifficulty Medium = 500
simulationsForDifficulty Hard = 2000
simulationsForDifficulty Expert = 5000

-- ============================================================
-- Main AI Interface
-- ============================================================

-- Tính toán AI move với config
getAIMove :: AIConfig -> Board -> Player -> IO Int
getAIMove config board player = do
  when (showThinking config) $ do
    putStrLn $ "\n🤖 AI (" ++ show (difficulty config) ++ ") thinking..."
    when (useParallel config) $ putStrLn "⚡ Parallel mode enabled"
  
  startTime <- getCurrentTime
  
  -- Priority 1: Winning move
  case MCTS.findWinningMove board player of
    Just col -> do
      when (showThinking config) $ putStrLn "✨ Found instant winning move!"
      return col
    Nothing -> do
      -- Priority 2: Blocking move
      case MCTS.findBlockingMove board player of
        Just col -> do
          when (showThinking config) $ putStrLn "🛡️  Blocking opponent's threat!"
          return col
        Nothing -> do
          -- Priority 3: MCTS calculation
          let numSims = simulationsForDifficulty (difficulty config)
          
          col <- if useParallel config
                   then Parallel.parallelBestMove board player numSims
                   else MCTS.selectBestMove board player numSims
          
          endTime <- getCurrentTime
          let elapsed = realToFrac $ diffUTCTime endTime startTime
          
          when (showThinking config) $ do
            putStrLn $ "⏱️  Thinking time: " ++ show elapsed ++ "s"
            putStrLn $ "🎯 Selected column: " ++ show col
          
          return col

-- ============================================================
-- AI vs AI (for testing)
-- ============================================================

-- Chơi một game AI vs AI
playAIvsAI :: AIConfig -> AIConfig -> IO GameResult
playAIvsAI config1 config2 = do
  putStrLn "\n🎮 AI vs AI Game Starting..."
  putStrLn $ "Red: " ++ show (difficulty config1)
  putStrLn $ "Black: " ++ show (difficulty config2)
  putStrLn $ replicate 50 '='
  
  playGame (newBoard, Red, config1, config2, 0)
  where
    playGame :: (Board, Player, AIConfig, AIConfig, Int) -> IO GameResult
    playGame (board, player, cfg1, cfg2, moveNum) = do
      -- Hiển thị board
      putStrLn $ "\nMove " ++ show (moveNum + 1)
      putStrLn $ showBoardPretty board
      
      -- Check game over
      case checkWinner board of
        Just winner -> do
          putStrLn $ "\n🎉 Winner: " ++ show winner
          return (Win winner)
        Nothing -> 
          if isBoardFull board
            then do
              putStrLn "\n🤝 Draw!"
              return Draw
            else do
              -- AI move
              let currentConfig = if player == Red then cfg1 else cfg2
              col <- getAIMove currentConfig board player
              
              case makeMove board col player of
                Nothing -> error "Invalid AI move!"
                Just newBoard -> 
                  playGame (newBoard, opponent player, cfg1, cfg2, moveNum + 1)

-- ============================================================
-- Statistics & Analysis
-- ============================================================

-- Thống kê performance của AI
data AIStats = AIStats
  { totalMoves :: Int
  , totalThinkingTime :: Double
  , avgThinkingTime :: Double
  , wins :: Int
  , losses :: Int
  , draws :: Int
  } deriving (Show)

emptyStats :: AIStats
emptyStats = AIStats 0 0 0 0 0 0

-- Chạy nhiều games để test AI
runAIBenchmark :: AIConfig -> AIConfig -> Int -> IO AIStats
runAIBenchmark config1 config2 numGames = do
  putStrLn $ "\n📊 Running " ++ show numGames ++ " games benchmark..."
  putStrLn $ "Red: " ++ show (difficulty config1)
  putStrLn $ "Black: " ++ show (difficulty config2)
  
  results <- mapM (\n -> do
    putStrLn $ "\nGame " ++ show n ++ "/" ++ show numGames
    playAIvsAI (config1 { showThinking = False }) 
               (config2 { showThinking = False })
    ) [1..numGames]
  
  let redWins = length $ filter (\r -> case r of Win Red -> True; _ -> False) results
      blackWins = length $ filter (\r -> case r of Win Black -> True; _ -> False) results
      draws = length $ filter (== Draw) results
  
  putStrLn "\n" ++ replicate 50 '='
  putStrLn "📈 Benchmark Results:"
  putStrLn $ "Red wins: " ++ show redWins ++ " (" 
          ++ show (100 * redWins `div` numGames) ++ "%)"
  putStrLn $ "Black wins: " ++ show blackWins ++ " (" 
          ++ show (100 * blackWins `div` numGames) ++ "%)"
  putStrLn $ "Draws: " ++ show draws
  putStrLn $ replicate 50 '='
  
  return emptyStats

-- ============================================================
-- Helper Functions
-- ============================================================

data GameResult = Win Player | Draw
  deriving (Show, Eq)

opponent :: Player -> Player
opponent Red = Black
opponent Black = Red

when :: Bool -> IO () -> IO ()
when True action = action
when False _ = return ()

-- Pretty print board
showBoardPretty :: Board -> String
showBoardPretty board = unlines $
  [ "  0 1 2 3 4 5 6"
  , "  " ++ replicate 14 '-'
  ] ++
  [ show row ++ "|" ++ unwords [showCell (getCell board (col, row)) | col <- [0..6]]
    | row <- [5,4..0]
  ] ++
  [ "  " ++ replicate 14 '-' ]

showCell :: Cell -> String
showCell Empty = "·"
showCell (Occupied Red) = "🔴"
showCell (Occupied Black) = "⚫"

-- ============================================================
-- Interactive AI Game
-- ============================================================

-- Chơi với AI
playWithAI :: AIConfig -> IO ()
playWithAI aiConfig = do
  putStrLn "\n🎮 Playing Connect Four vs AI"
  putStrLn $ "AI Difficulty: " ++ show (difficulty aiConfig)
  putStrLn "You are Red, AI is Black"
  putStrLn $ replicate 50 '='
  
  playInteractive (newBoard, Red)
  where
    playInteractive :: (Board, Player) -> IO ()
    playInteractive (board, player) = do
      putStrLn $ "\n" ++ showBoardPretty board
      
      -- Check game over
      case checkWinner board of
        Just winner -> do
          putStrLn $ if winner == Red 
                       then "\n🎉 You win!" 
                       else "\n😔 AI wins!"
          return ()
        Nothing ->
          if isBoardFull board
            then putStrLn "\n🤝 It's a draw!"
            else do
              -- Player move
              col <- if player == Red
                       then getHumanMove board
                       else getAIMove aiConfig board player
              
              case makeMove board col player of
                Nothing -> do
                  putStrLn "Invalid move, try again"
                  playInteractive (board, player)
                Just newBoard ->
                  playInteractive (newBoard, opponent player)
    
    getHumanMove :: Board -> IO Int
    getHumanMove board = do
      putStrLn "Your turn! Enter column (0-6):"
      input <- getLine
      case reads input of
        [(col, "")] | col >= 0 && col <= 6 && isValidMove board col -> return col
        _ -> do
          putStrLn "Invalid input, try again"
          getHumanMove board

-- ============================================================
-- Export
-- ============================================================

-- Main exports
-- getAIMove, playWithAI, playAIvsAI, runAIBenchmark