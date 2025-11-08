module Game.Rules where
import Game.Types
import Game.Board
import Data.Maybe (listToMaybe)

-- ============================================================
-- Win Detection
-- ============================================================

-- Check if there's a winner on the board
checkWinner :: Board -> Maybe Player
checkWinner board = 
  listToMaybe [ player 
              | player <- [Red, Black]
              , hasWon board player
              ]

-- Check if a specific player has won
hasWon :: Board -> Player -> Bool
hasWon board player = 
  checkHorizontal board player ||
  checkVertical board player ||
  checkDiagonalUp board player ||
  checkDiagonalDown board player

-- ============================================================
-- Horizontal Win (—)
-- ============================================================

checkHorizontal :: Board -> Player -> Bool
checkHorizontal board player = 
  any (hasFourInRow player) [getRow board row | row <- [0..boardHeight-1]]

-- ============================================================
-- Vertical Win (|)
-- ============================================================

checkVertical :: Board -> Player -> Bool
checkVertical board player = 
  any (hasFourInRow player) [getColumn board col | col <- [0..boardWidth-1]]

-- ============================================================
-- Diagonal Up Win (/)
-- ============================================================

checkDiagonalUp :: Board -> Player -> Bool
checkDiagonalUp board player = any (hasFourInRow player) allDiagonalsUp
  where
    -- Starting from bottom row, going right
    allDiagonalsUp = 
      [getDiagonalUp board (col, 0) | col <- [0..boardWidth-1]] ++
      [getDiagonalUp board (0, row) | row <- [1..boardHeight-1]]

-- ============================================================
-- Diagonal Down Win (\)
-- ============================================================

checkDiagonalDown :: Board -> Player -> Bool
checkDiagonalDown board player = any (hasFourInRow player) allDiagonalsDown
  where
    -- Starting from top row, going right
    allDiagonalsDown = 
      [getDiagonalDown board (col, boardHeight-1) | col <- [0..boardWidth-1]] ++
      [getDiagonalDown board (0, row) | row <- [0..boardHeight-2]]

-- ============================================================
-- Draw Detection
-- ============================================================

-- Check if the game is a draw (board full, no winner)
isDraw :: Board -> Bool
isDraw board = isBoardFull board && checkWinner board == Nothing

-- ============================================================
-- Game Over Detection
-- ============================================================

-- Check if game is over (win or draw)
isGameOver :: Board -> Bool
isGameOver board = checkWinner board /= Nothing || isBoardFull board

-- Get game result
getGameResult :: Board -> GameStatus
getGameResult board
  | Just winner <- checkWinner board = Winner winner
  | isBoardFull board = Draw
  | otherwise = InProgress

-- ============================================================
-- Detailed Win Information
-- ============================================================

data WinInfo = WinInfo
  { winningPlayer :: Player
  , winningDirection :: Direction
  , winningPositions :: [Position]
  } deriving (Show, Eq)

-- Find exact winning positions (for UI highlighting)
findWinningLine :: Board -> Maybe WinInfo
findWinningLine board = 
  case checkWinner board of
    Nothing -> Nothing
    Just player -> 
      listToMaybe $ concat
        [ checkDirection player Horizontal
        , checkDirection player Vertical
        , checkDirection player DiagonalUp
        , checkDirection player DiagonalDown
        ]
  where
    checkDirection player dir = 
      [ WinInfo player dir positions
      | start <- getStartPositions dir
      , let positions = take 4 $ iterate (`moveInDirection` dir) start
      , all (\pos -> getCell board pos == Occupied player) positions
      ]
    
    getStartPositions Horizontal = 
      [(col, row) | row <- [0..boardHeight-1], col <- [0..boardWidth-4]]
    getStartPositions Vertical = 
      [(col, row) | col <- [0..boardWidth-1], row <- [0..boardHeight-4]]
    getStartPositions DiagonalUp = 
      [(col, row) | col <- [0..boardWidth-4], row <- [0..boardHeight-4]]
    getStartPositions DiagonalDown = 
      [(col, row) | col <- [0..boardWidth-4], row <- [3..boardHeight-1]]

-- ============================================================
-- Move Validation with Rules
-- ============================================================

-- Check if a move is legal
isLegalMove :: GameState -> Column -> Bool
isLegalMove state col = 
  gameStatus state == InProgress && isValidMove (board state) col

-- Apply move to game state (with validation)
applyMove :: GameState -> Column -> Maybe GameState
applyMove state col
  | not (isLegalMove state col) = Nothing
  | otherwise = do
      newBoard <- makeMove (board state) col (currentPlayer state)
      let newState = state
            { board = newBoard
            , currentPlayer = nextPlayer (currentPlayer state)
            , moveHistory = col : moveHistory state
            , gameStatus = getGameResult newBoard
            , moveCount = moveCount state + 1
            }
      return newState

-- Undo last move from game state
undoLastMove :: GameState -> Maybe GameState
undoLastMove state
  | null (moveHistory state) = Nothing
  | otherwise = do
      let lastCol = head (moveHistory state)
      newBoard <- undoMove (board state) lastCol
      let newState = state
            { board = newBoard
            , currentPlayer = nextPlayer (currentPlayer state)
            , moveHistory = tail (moveHistory state)
            , gameStatus = InProgress
            , moveCount = moveCount state - 1
            }
      return newState

-- ============================================================
-- Game Statistics
-- ============================================================

-- Count total pieces on board
totalPieces :: Board -> Int
totalPieces = countOccupied

-- Count pieces for a specific player
countPlayerPieces :: Board -> Player -> Int
countPlayerPieces board player = 
  length $ filter (\pos -> getCell board pos == Occupied player) allPositions

-- Get move number from board state
getMoveNumber :: Board -> Int
getMoveNumber = totalPieces

-- ============================================================
-- Pattern Analysis (for AI)
-- ============================================================

-- Count threats (3-in-a-row with empty space)
countThreats :: Board -> Player -> Int
countThreats board player = length (findWinningMoves board player)

-- Check if position creates a threat
createsThreat :: Board -> Column -> Player -> Bool
createsThreat board col player = 
  case makeMove board col player of
    Nothing -> False
    Just newBoard -> countThreats newBoard player > countThreats board player

-- ============================================================
-- Testing Utilities
-- ============================================================

-- Create test scenarios
testWinHorizontal :: Board
testWinHorizontal = case boardFromMoves Red [0,0,1,1,2,2,3] of
  Just b -> b
  Nothing -> emptyBoard

testWinVertical :: Board
testWinVertical = case boardFromMoves Red [0,1,0,1,0,1,0] of
  Just b -> b
  Nothing -> emptyBoard

testWinDiagonal :: Board
testWinDiagonal = case boardFromMoves Red [0,1,1,2,2,3,2,3,3,6,3] of
  Just b -> b
  Nothing -> emptyBoard

testDraw :: Board
testDraw = case boardFromMoves Red 
  [0,0,0,1,1,1,2,2,2,3,3,3,4,4,4,5,5,5,6,6,6,
   0,0,0,1,1,1,2,2,2,3,3,3,4,4,4,5,5,5,6,6,6] of
  Just b -> b
  Nothing -> emptyBoard

-- ============================================================
-- Rule Explanations (for UI)
-- ============================================================

rules :: [String]
rules = 
  [ "Connect Four Rules:"
  , "1. Players take turns dropping pieces into columns"
  , "2. Pieces fall to the lowest available position"
  , "3. First player to connect 4 pieces in a row wins"
  , "4. Connections can be horizontal, vertical, or diagonal"
  , "5. If the board fills without a winner, it's a draw"
  ]

printRules :: IO ()
printRules = mapM_ putStrLn rules