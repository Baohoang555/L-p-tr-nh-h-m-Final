{-# LANGUAGE BangPatterns #-}
module Game.AI.Parallel where

import Game.Types
import Game.Board
import Game.AI.MonteCarlo
import Control.Parallel.Strategies
import Control.Concurrent.Async
import Control.DeepSeq
import System.CPUTime
import Text.Printf

-- ============================================================
-- Parallel Evaluation với Strategies
-- ============================================================

-- Evaluate 7 columns đồng thời sử dụng parallel strategies
parallelEvaluate :: Board -> Player -> Int -> IO [Double]
parallelEvaluate board player numSimulations = do
  putStrLn "⚡ Using parallel strategies for evaluation..."
  
  let validCols = [0..6]
  
  -- Evaluate tất cả columns song song
  -- parList rdeepseq: evaluate mỗi element song song và force full evaluation
  let scores = map (\col -> evaluateColumnPure board player numSimulations col) validCols
                `using` parList rdeepseq
  
  return scores

-- Pure version của evaluateColumn (không có IO)
evaluateColumnPure :: Board -> Player -> Int -> Int -> Double
evaluateColumnPure board player numSims column = 
  case makeMove board column player of
    Nothing -> -1.0
    Just newBoard -> 
      let scores = map (\seed -> simulatePure newBoard (opponent player) seed) [1..numSims]
          opponentWinRate = sum scores / fromIntegral numSims
      in 1.0 - opponentWinRate

-- Pure version của simulate
simulatePure :: Board -> Player -> Int -> Double
simulatePure board player seed = 
  let result = runSimulationPure board player seed
  in evaluateResultPure result player
  where
    runSimulationPure :: Board -> Player -> Int -> GameResult
    runSimulationPure b p s
      | Just winner <- checkWinner b = Win winner
      | isBoardFull b = Draw
      | otherwise = 
          let validMoves = getValidColumns b
              chosenCol = validMoves !! (s `mod` length validMoves)
          in case makeMove b chosenCol p of
               Nothing -> Draw
               Just newBoard -> runSimulationPure newBoard (opponent p) (s * 31 + 17)
    
    evaluateResultPure :: GameResult -> Player -> Double
    evaluateResultPure (Win winner) p = if winner == p then 1.0 else 0.0
    evaluateResultPure Draw _ = 0.5

-- ============================================================
-- Parallel Simulations với Async
-- ============================================================

-- Chạy nhiều simulations song song cho một move
parSimulate :: Board -> Player -> Int -> IO [Double]
parSimulate board player numSimulations = do
  putStrLn $ "⚡ Running " ++ show numSimulations ++ " parallel simulations..."
  
  -- Chia simulations thành chunks cho mỗi core
  let chunkSize = max 1 (numSimulations `div` 8)  -- 8 cores
      chunks = [chunkSize | _ <- [1..8]]
  
  -- Chạy mỗi chunk song song
  results <- mapConcurrently (runChunk board player) chunks
  
  return (concat results)

-- Chạy một chunk simulations
runChunk :: Board -> Player -> Int -> IO [Double]
runChunk board player n = replicateM n (simulate board player)

-- ============================================================
-- Parallel Best Move Selection
-- ============================================================

-- Chọn best move sử dụng parallel evaluation
parallelBestMove :: Board -> Player -> Int -> IO Int
parallelBestMove board player numSimulations = do
  scores <- parallelEvaluate board player numSimulations
  
  let indexedScores = zip [0..] scores
      validScores = filter (\(_, score) -> score >= 0) indexedScores
  
  if null validScores
    then return 3
    else do
      let (bestCol, bestScore) = maximumBy (comparing snd) validScores
      putStrLn $ "🚀 Parallel AI: Best move " ++ show bestCol 
                 ++ " (win rate: " ++ show (bestScore * 100) ++ "%)"
      return bestCol

-- ============================================================
-- Chunked Parallel Evaluation (Hybrid approach)
-- ============================================================

-- Evaluate columns song song, mỗi column chạy nhiều simulations
chunkedParallelEvaluate :: Board -> Player -> Int -> IO [Double]
chunkedParallelEvaluate board player numSimulations = do
  putStrLn "⚡⚡ Using chunked parallel evaluation..."
  
  let columns = [0..6]
  
  -- Mỗi column được evaluate song song
  scores <- mapConcurrently 
    (\col -> evaluateColumn board player numSimulations col) 
    columns
  
  return scores

-- ============================================================
-- Benchmarking
-- ============================================================

-- Benchmark serial vs parallel
benchmarkAI :: Board -> Player -> Int -> IO ()
benchmarkAI board player numSims = do
  putStrLn "\n========================================="
  putStrLn "🏁 AI Performance Benchmark"
  putStrLn "========================================="
  putStrLn $ "Board state: " ++ show (length (getValidColumns board)) ++ " valid moves"
  putStrLn $ "Simulations per move: " ++ show numSims
  putStrLn ""
  
  -- Serial evaluation
  putStrLn "1️⃣  Serial Evaluation:"
  (serialTime, serialResult) <- timeIO $ evaluate board player numSims
  printf "   Time: %.3f seconds\n" serialTime
  printf "   Best column: %d (score: %.2f%%)\n" 
    (fst $ maximumBy (comparing snd) $ zip [0..] serialResult)
    ((maximum serialResult) * 100)
  
  -- Parallel evaluation with strategies
  putStrLn "\n2️⃣  Parallel Evaluation (Strategies):"
  (parTime, parResult) <- timeIO $ parallelEvaluate board player numSims
  printf "   Time: %.3f seconds\n" parTime
  printf "   Best column: %d (score: %.2f%%)\n"
    (fst $ maximumBy (comparing snd) $ zip [0..] parResult)
    ((maximum parResult) * 100)
  printf "   Speedup: %.2fx\n" (serialTime / parTime)
  
  -- Chunked parallel evaluation
  putStrLn "\n3️⃣  Chunked Parallel Evaluation (Async):"
  (chunkedTime, chunkedResult) <- timeIO $ chunkedParallelEvaluate board player numSims
  printf "   Time: %.3f seconds\n" chunkedTime
  printf "   Best column: %d (score: %.2f%%)\n"
    (fst $ maximumBy (comparing snd) $ zip [0..] chunkedResult)
    ((maximum chunkedResult) * 100)
  printf "   Speedup: %.2fx\n" (serialTime / chunkedTime)
  
  putStrLn "\n========================================="
  putStrLn "Summary:"
  printf "  Serial:           %.3fs (baseline)\n" serialTime
  printf "  Parallel (Strat): %.3fs (%.1fx faster)\n" parTime (serialTime / parTime)
  printf "  Parallel (Async): %.3fs (%.1fx faster)\n" chunkedTime (serialTime / chunkedTime)
  putStrLn "========================================="

-- Time an IO action
timeIO :: IO a -> IO (Double, a)
timeIO action = do
  start <- getCPUTime
  result <- action
  end <- getCPUTime
  let diff = fromIntegral (end - start) / (10^12)
  return (diff, result)

-- ============================================================
-- NFData instances for deepseq
-- ============================================================

instance NFData Player where
  rnf Red = ()
  rnf Black = ()

instance NFData Cell where
  rnf Empty = ()
  rnf (Occupied p) = rnf p

instance NFData GameResult where
  rnf (Win p) = rnf p
  rnf Draw = ()

-- ============================================================
-- Helper imports
-- ============================================================

import Data.List (maximumBy)
import Data.Ord (comparing)
import Control.Monad (replicateM)
import Control.Concurrent.Async (mapConcurrently)

-- ============================================================
-- Testing
-- ============================================================

-- Test parallel AI
testParallelAI :: IO ()
testParallelAI = do
  putStrLn "Testing Parallel AI..."
  let board = newBoard
  
  putStrLn "\n=== Benchmark với 200 simulations ==="
  benchmarkAI board Red 200
  
  putStrLn "\n=== Benchmark với 1000 simulations ==="
  benchmarkAI board Red 1000

-- Quick comparison test
quickTest :: IO ()
quickTest = do
  let board = newBoard
  
  putStrLn "Quick Test: Serial vs Parallel"
  putStrLn "\nSerial (500 sims):"
  (t1, _) <- timeIO $ selectBestMove board Red 500
  printf "Time: %.3fs\n" t1
  
  putStrLn "\nParallel (500 sims):"
  (t2, _) <- timeIO $ parallelBestMove board Red 500
  printf "Time: %.3fs\n" t2
  printf "Speedup: %.2fx\n" (t1 / t2)