{-# LANGUAGE RecordWildCards #-}
module Game.AI.MonteCarlo where

import Game.Types
import Game.Board
import Game.Rules
import System.Random
import Control.Monad (replicateM)
import Data.List (maximumBy)
import Data.Ord (comparing)

-- ============================================================
-- MCTS Node Structure
-- ============================================================

data MCTSNode = MCTSNode
  { nodeBoard :: Board
  , nodePlayer :: Player
  , visits :: Int
  , wins :: Double
  , children :: [(Int, MCTSNode)]  -- (column, child node)
  } deriving (Show)

-- Tạo node gốc
rootNode :: Board -> Player -> MCTSNode
rootNode board player = MCTSNode
  { nodeBoard = board
  , nodePlayer = player
  , visits = 0
  , wins = 0
  , children = []
  }

-- ============================================================
-- Random Playout (Simulation)
-- ============================================================

-- Chạy một game hoàn chỉnh từ board hiện tại với random moves
-- Return: 1.0 nếu player thắng, 0.0 nếu thua, 0.5 nếu hòa
simulate :: Board -> Player -> IO Double
simulate board player = do
  gen <- newStdGen
  let result = runSimulation board player gen
  return $ evaluateResult result player
  where
    -- Chạy simulation đến khi kết thúc
    runSimulation :: Board -> Player -> StdGen -> GameResult
    runSimulation b p g
      | Just winner <- checkWinner b = Win winner
      | isBoardFull b = Draw
      | otherwise = 
          let validMoves = getValidColumns b
              (chosenCol, g') = randomChoice validMoves g
          in case makeMove b chosenCol p of
               Nothing -> Draw  -- Không nên xảy ra
               Just newBoard -> runSimulation newBoard (opponent p) g'
    
    -- Đánh giá kết quả từ góc nhìn của player
    evaluateResult :: GameResult -> Player -> Double
    evaluateResult (Win winner) p = if winner == p then 1.0 else 0.0
    evaluateResult Draw _ = 0.5

-- Game result
data GameResult = Win Player | Draw
  deriving (Show, Eq)

-- Lấy các cột hợp lệ
getValidColumns :: Board -> [Int]
getValidColumns board = filter (isValidMove board) [0..6]

-- Chọn random từ list
randomChoice :: [a] -> StdGen -> (a, StdGen)
randomChoice xs g = 
  let (idx, g') = randomR (0, length xs - 1) g
  in (xs !! idx, g')

-- ============================================================
-- Evaluation - Đánh giá nhiều moves
-- ============================================================

-- Đánh giá tất cả các moves có thể bằng cách chạy nhiều simulations
-- Trả về list win rates cho mỗi cột
evaluate :: Board -> Player -> Int -> IO [Double]
evaluate board player numSimulations = do
  let validCols = getValidColumns board
  
  -- Với mỗi cột, chạy simulations và tính win rate
  results <- mapM (evaluateColumn board player numSimulations) validCols
  
  -- Tạo result array đầy đủ (7 cột)
  let fullResults = map (\col -> 
        case lookup col (zip validCols results) of
          Just score -> score
          Nothing -> -1.0  -- Cột không hợp lệ
        ) [0..6]
  
  return fullResults

-- Đánh giá một cột cụ thể
evaluateColumn :: Board -> Player -> Int -> Int -> IO Double
evaluateColumn board player numSims column = do
  case makeMove board column player of
    Nothing -> return (-1.0)  -- Move không hợp lệ
    Just newBoard -> do
      -- Chạy numSims simulations từ newBoard
      scores <- replicateM numSims (simulate newBoard (opponent player))
      -- Win rate = (1 - opponent win rate)
      let opponentWinRate = sum scores / fromIntegral numSims
      return (1.0 - opponentWinRate)

-- ============================================================
-- Best Move Selection
-- ============================================================

-- Chọn move tốt nhất dựa trên MCTS
selectBestMove :: Board -> Player -> Int -> IO Int
selectBestMove board player numSimulations = do
  scores <- evaluate board player numSimulations
  
  -- Tìm cột có win rate cao nhất
  let indexedScores = zip [0..] scores
      validScores = filter (\(_, score) -> score >= 0) indexedScores
  
  if null validScores
    then return 3  -- Fallback: cột giữa
    else do
      let (bestCol, bestScore) = maximumBy (comparing snd) validScores
      putStrLn $ "🤖 AI thinking... Best move: " ++ show bestCol 
                 ++ " (win rate: " ++ show (bestScore * 100) ++ "%)"
      return bestCol

-- ============================================================
-- AI with Difficulty Levels
-- ============================================================

data Difficulty = Easy | Medium | Hard
  deriving (Show, Eq)

-- Số simulations cho mỗi độ khó
simulationsForDifficulty :: Difficulty -> Int
simulationsForDifficulty Easy = 100
simulationsForDifficulty Medium = 500
simulationsForDifficulty Hard = 2000

-- AI move với difficulty
aiMove :: Board -> Player -> Difficulty -> IO Int
aiMove board player difficulty = do
  let numSims = simulationsForDifficulty difficulty
  putStrLn $ "🤖 AI (" ++ show difficulty ++ ") thinking with " 
             ++ show numSims ++ " simulations..."
  selectBestMove board player numSims

-- ============================================================
-- Quick Win Detection (Optimization)
-- ============================================================

-- Kiểm tra xem có move nào thắng ngay lập tức không
findWinningMove :: Board -> Player -> Maybe Int
findWinningMove board player = 
  let validCols = getValidColumns board
      winningCols = filter isWinning validCols
  in if null winningCols then Nothing else Just (head winningCols)
  where
    isWinning col = case makeMove board col player of
      Nothing -> False
      Just newBoard -> checkWinner newBoard == Just player

-- Kiểm tra xem đối thủ có move nào thắng không (phải block)
findBlockingMove :: Board -> Player -> Maybe Int
findBlockingMove board player = findWinningMove board (opponent player)

-- AI thông minh: ưu tiên thắng -> block -> MCTS
smartAiMove :: Board -> Player -> Difficulty -> IO Int
smartAiMove board player difficulty = do
  -- 1. Kiểm tra xem có thể thắng ngay không
  case findWinningMove board player of
    Just col -> do
      putStrLn "🎯 AI found winning move!"
      return col
    Nothing -> 
      -- 2. Kiểm tra xem cần block đối thủ không
      case findBlockingMove board player of
        Just col -> do
          putStrLn "🛡️  AI blocking opponent's winning move!"
          return col
        Nothing -> 
          -- 3. Dùng MCTS
          aiMove board player difficulty

-- ============================================================
-- Helper Functions
-- ============================================================

opponent :: Player -> Player
opponent Red = Black
opponent Black = Red

-- Test AI
testAI :: IO ()
testAI = do
  putStrLn "Testing Connect Four AI..."
  let emptyBoard = newBoard
  
  putStrLn "\n=== Easy AI ===="
  col1 <- aiMove emptyBoard Red Easy
  putStrLn $ "AI chose column: " ++ show col1
  
  putStrLn "\n=== Medium AI ===="
  col2 <- aiMove emptyBoard Red Medium
  putStrLn $ "AI chose column: " ++ show col2
  
  putStrLn "\n=== Hard AI ===="
  col3 <- aiMove emptyBoard Red Hard
  putStrLn $ "AI chose column: " ++ show col3