module Game.Board where
import Game.Types
import Data.Vector (Vector)
import qualified Data.Vector as V
import Data.Maybe (isJust)

-- ============================================================
-- Board Creation
-- ============================================================

-- Create new empty board
newBoard :: Board
newBoard = emptyBoard

-- Create board from list of moves (for testing)
boardFromMoves :: Player -> [Move] -> Maybe Board
boardFromMoves startPlayer moves = 
  foldl applyMove (Just (newBoard, startPlayer)) moves >>= Just . fst
  where
    applyMove Nothing _ = Nothing
    applyMove (Just (board, player)) move = 
      case makeMove board move player of
        Nothing -> Nothing
        Just newBoard -> Just (newBoard, nextPlayer player)

-- ============================================================
-- Move Validation
-- ============================================================

-- Check if a column is valid for a move
isValidMove :: Board -> Column -> Bool
isValidMove board col
  | not (isValidColumn col) = False
  | otherwise = isEmpty (getCell board (col, boardHeight - 1))

-- Get all valid columns
getValidColumns :: Board -> [Column]
getValidColumns board = filter (isValidMove board) [0..boardWidth-1]

-- Check if board is full
isBoardFull :: Board -> Bool
isBoardFull board = null (getValidColumns board)

-- ============================================================
-- Making Moves
-- ============================================================

-- Find the lowest empty row in a column
getLowestEmptyRow :: Board -> Column -> Maybe Row
getLowestEmptyRow board col
  | not (isValidColumn col) = Nothing
  | otherwise = findRow 0
  where
    findRow row
      | row >= boardHeight = Nothing
      | isEmpty (getCell board (col, row)) = Just row
      | otherwise = findRow (row + 1)

-- Make a move: drop piece in column
makeMove :: Board -> Column -> Player -> Maybe Board
makeMove board col player = do
  row <- getLowestEmptyRow board col
  return $ setCell board (col, row) (Occupied player)

-- Undo last move (remove top piece from column)
undoMove :: Board -> Column -> Maybe Board
undoMove board col
  | not (isValidColumn col) = Nothing
  | otherwise = removeTopPiece (boardHeight - 1)
  where
    removeTopPiece row
      | row < 0 = Nothing  -- Column is empty
      | isEmpty (getCell board (col, row)) = removeTopPiece (row - 1)
      | otherwise = Just $ setCell board (col, row) Empty

-- ============================================================
-- Board Analysis
-- ============================================================

-- Get the height (number of pieces) in a column
columnHeight :: Board -> Column -> Int
columnHeight board col = 
  length $ filter (not . isEmpty) [getCell board (col, row) | row <- [0..boardHeight-1]]

-- Get all pieces in a column (bottom to top)
getColumn :: Board -> Column -> [Cell]
getColumn board col = [getCell board (col, row) | row <- [0..boardHeight-1]]

-- Get all pieces in a row (left to right)
getRow :: Board -> Row -> [Cell]
getRow board row = [getCell board (col, row) | col <- [0..boardWidth-1]]

-- Get diagonal starting from position (going up-right)
getDiagonalUp :: Board -> Position -> [Cell]
getDiagonalUp board start = map (getCell board) (takeDiagonal start)
  where
    takeDiagonal (col, row)
      | col >= boardWidth || row >= boardHeight = []
      | otherwise = (col, row) : takeDiagonal (col + 1, row + 1)

-- Get diagonal starting from position (going down-right)
getDiagonalDown :: Board -> Position -> [Cell]
getDiagonalDown board start = map (getCell board) (takeDiagonal start)
  where
    takeDiagonal (col, row)
      | col >= boardWidth || row < 0 = []
      | otherwise = (col, row) : takeDiagonal (col + 1, row - 1)

-- ============================================================
-- Pattern Matching
-- ============================================================

-- Count consecutive pieces of player in a list
countConsecutive :: Player -> [Cell] -> Int
countConsecutive player cells = maximum (0 : counts)
  where
    counts = map length $ filter (not . null) $ 
             map (filter (== Occupied player)) $ 
             group cells
    
    -- Group consecutive elements
    group :: Eq a => [a] -> [[a]]
    group [] = []
    group (x:xs) = (x : takeWhile (== x) xs) : group (dropWhile (== x) xs)

-- Check if there are 4 consecutive pieces of player
hasFourInRow :: Player -> [Cell] -> Bool
hasFourInRow player cells = countConsecutive player cells >= 4

-- ============================================================
-- Threat Detection (for AI)
-- ============================================================

-- Check if a position would create a winning move
isWinningPosition :: Board -> Column -> Player -> Bool
isWinningPosition board col player = 
  case makeMove board col player of
    Nothing -> False
    Just newBoard -> isJust (checkWinnerAt newBoard (col, row))
  where
    row = case getLowestEmptyRow board col of
            Just r -> r
            Nothing -> 0

-- Find all winning moves for a player
findWinningMoves :: Board -> Player -> [Column]
findWinningMoves board player = 
  filter (\col -> isWinningPosition board col player) (getValidColumns board)

-- Find threats (opponent's winning moves)
findThreats :: Board -> Player -> [Column]
findThreats board player = findWinningMoves board (nextPlayer player)

-- ============================================================
-- Board Scoring (for evaluation)
-- ============================================================

-- Simple board evaluation: count patterns
evaluateBoard :: Board -> Player -> Int
evaluateBoard board player = 
  sum [ scorePattern (getRow board row) player | row <- [0..boardHeight-1] ] +
  sum [ scorePattern (getColumn board col) player | col <- [0..boardWidth-1] ] +
  sum [ scorePattern (getDiagonalUp board (col, 0)) player | col <- [0..boardWidth-1] ] +
  sum [ scorePattern (getDiagonalUp board (0, row)) player | row <- [1..boardHeight-1] ] +
  sum [ scorePattern (getDiagonalDown board (col, boardHeight-1)) player | col <- [0..boardWidth-1] ] +
  sum [ scorePattern (getDiagonalDown board (0, row)) player | row <- [0..boardHeight-2] ]

-- Score a pattern (sequence of cells)
scorePattern :: [Cell] -> Player -> Int
scorePattern cells player = sum $ map scoreWindow windows
  where
    windows = slidingWindow 4 cells
    scoreWindow w = 
      let myCount = length $ filter (== Occupied player) w
          oppCount = length $ filter (== Occupied (nextPlayer player)) w
          emptyCount = length $ filter (== Empty) w
      in if oppCount > 0 
           then 0  -- Opponent blocks this window
           else case myCount of
                  4 -> 1000  -- Win
                  3 -> if emptyCount == 1 then 5 else 0
                  2 -> if emptyCount == 2 then 2 else 0
                  _ -> 0

-- Sliding window of size n
slidingWindow :: Int -> [a] -> [[a]]
slidingWindow n xs
  | length xs < n = []
  | otherwise = take n xs : slidingWindow n (tail xs)

-- ============================================================
-- Helper function to check winner at specific position
-- ============================================================

checkWinnerAt :: Board -> Position -> Maybe Player
checkWinnerAt board pos@(col, row) = 
  case cellPlayer (getCell board pos) of
    Nothing -> Nothing
    Just player -> 
      if any (hasFourInRow player) patterns
        then Just player
        else Nothing
  where
    patterns = 
      [ getRow board row
      , getColumn board col
      , getDiagonalUp board (findDiagStart pos DiagonalUp)
      , getDiagonalDown board (findDiagStart pos DiagonalDown)
      ]
    
    -- Find starting position of diagonal
    findDiagStart (c, r) DiagonalUp = 
      if c > r then (c - r, 0) else (0, r - c)
    findDiagStart (c, r) DiagonalDown = 
      let sum = c + r
      in if sum >= boardHeight 
           then (sum - boardHeight + 1, boardHeight - 1)
           else (0, sum)
    findDiagStart pos _ = pos

-- ============================================================
-- Board Utilities
-- ============================================================

-- Clone board (already immutable, just return it)
cloneBoard :: Board -> Board
cloneBoard = id

-- Compare boards
boardEquals :: Board -> Board -> Bool
boardEquals b1 b2 = V.and $ V.zipWith (V.==) b1 b2

-- Hash board (for transposition table in advanced AI)
boardHash :: Board -> Int
boardHash board = V.sum $ V.imap hashColumn board
  where
    hashColumn col vec = col * V.sum (V.imap hashCell vec)
    hashCell row cell = row * cellValue cell
    cellValue Empty = 0
    cellValue (Occupied Red) = 1
    cellValue (Occupied Black) = 2