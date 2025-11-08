{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE DeriveAnyClass #-}
module Game.Types where
import Data.Vector (Vector)
import qualified Data.Vector as V
import Data.Aeson (ToJSON, FromJSON)
import GHC.Generics
import Control.DeepSeq

-- ============================================================
-- Player
-- ============================================================

data Player = Red | Black
  deriving (Show, Eq, Ord, Generic, ToJSON, FromJSON, NFData)

-- Switch player
nextPlayer :: Player -> Player
nextPlayer Red = Black
nextPlayer Black = Red

-- ============================================================
-- Cell
-- ============================================================

data Cell = Empty | Occupied Player
  deriving (Show, Eq, Generic, ToJSON, FromJSON, NFData)

-- Check if cell is empty
isEmpty :: Cell -> Bool
isEmpty Empty = True
isEmpty _ = False

-- Get player from cell
cellPlayer :: Cell -> Maybe Player
cellPlayer (Occupied p) = Just p
cellPlayer Empty = Nothing

-- ============================================================
-- Board
-- ============================================================

-- 7 columns x 6 rows (standard Connect Four)
-- Column 0-6, Row 0-5 (bottom to top)
type Board = Vector (Vector Cell)

-- Board dimensions
boardWidth :: Int
boardWidth = 7

boardHeight :: Int
boardHeight = 6

-- Create empty board
emptyBoard :: Board
emptyBoard = V.replicate boardWidth (V.replicate boardHeight Empty)

-- Get cell at position
getCell :: Board -> (Int, Int) -> Cell
getCell board (col, row)
  | col < 0 || col >= boardWidth = Empty
  | row < 0 || row >= boardHeight = Empty
  | otherwise = (board V.! col) V.! row

-- Set cell at position
setCell :: Board -> (Int, Int) -> Cell -> Board
setCell board (col, row) cell
  | col < 0 || col >= boardWidth = board
  | row < 0 || row >= boardHeight = board
  | otherwise = board V.// [(col, newColumn)]
  where
    oldColumn = board V.! col
    newColumn = oldColumn V.// [(row, cell)]

-- ============================================================
-- Game State
-- ============================================================

data GameState = GameState
  { board :: Board
  , currentPlayer :: Player
  , moveHistory :: [Int]        -- List of column indices
  , gameStatus :: GameStatus
  , moveCount :: Int
  } deriving (Show, Generic, ToJSON, FromJSON)

data GameStatus 
  = InProgress
  | Winner Player
  | Draw
  deriving (Show, Eq, Generic, ToJSON, FromJSON)

-- Create new game
newGame :: Player -> GameState
newGame startPlayer = GameState
  { board = emptyBoard
  , currentPlayer = startPlayer
  , moveHistory = []
  , gameStatus = InProgress
  , moveCount = 0
  }

-- Check if game is over
isGameOver :: GameState -> Bool
isGameOver state = case gameStatus state of
  InProgress -> False
  _ -> True

-- ============================================================
-- Move
-- ============================================================

type Column = Int
type Row = Int

-- A move is just a column index (0-6)
type Move = Column

-- Valid move check
isValidColumn :: Column -> Bool
isValidColumn col = col >= 0 && col < boardWidth

-- ============================================================
-- Position
-- ============================================================

-- (column, row) position on board
type Position = (Column, Row)

-- All positions on board
allPositions :: [Position]
allPositions = [(col, row) | col <- [0..boardWidth-1], row <- [0..boardHeight-1]]

-- Get all positions in a column (bottom to top)
columnPositions :: Column -> [Position]
columnPositions col = [(col, row) | row <- [0..boardHeight-1]]

-- Get all positions in a row (left to right)
rowPositions :: Row -> [Position]
rowPositions row = [(col, row) | col <- [0..boardWidth-1]]

-- ============================================================
-- Direction (for win checking)
-- ============================================================

data Direction = Horizontal | Vertical | DiagonalUp | DiagonalDown
  deriving (Show, Eq, Enum)

-- Get next position in direction
moveInDirection :: Position -> Direction -> Position
moveInDirection (col, row) Horizontal = (col + 1, row)
moveInDirection (col, row) Vertical = (col, row + 1)
moveInDirection (col, row) DiagonalUp = (col + 1, row + 1)
moveInDirection (col, row) DiagonalDown = (col + 1, row - 1)

-- Get all positions in a line from start position
getLine :: Position -> Direction -> Int -> [Position]
getLine start dir length = take length $ iterate (`moveInDirection` dir) start

-- ============================================================
-- Utility Functions
-- ============================================================

-- Count cells of a specific type on board
countCells :: (Cell -> Bool) -> Board -> Int
countCells predicate board = 
  V.sum $ V.map (V.length . V.filter predicate) board

-- Count empty cells
countEmpty :: Board -> Int
countEmpty = countCells isEmpty

-- Count occupied cells
countOccupied :: Board -> Int
countOccupied = countCells (not . isEmpty)

-- Get all occupied positions
getOccupiedPositions :: Board -> Player -> [Position]
getOccupiedPositions board player = 
  filter (\pos -> cellPlayer (getCell board pos) == Just player) allPositions

-- ============================================================
-- Display
-- ============================================================

-- Pretty print board (ASCII)
showBoard :: Board -> String
showBoard board = unlines $
  [ "  0 1 2 3 4 5 6" 
  , "  " ++ replicate 14 '-'
  ] ++
  [ show row ++ "|" ++ unwords [showCell (getCell board (col, row)) | col <- [0..6]]
    | row <- [5,4..0]
  ] ++
  [ "  " ++ replicate 14 '-' ]

showCellPretty :: Cell -> String
showCellPretty Empty = "·"
showCellPretty (Occupied Red) = "🔴"
showCellPretty (Occupied Black) = "⚫"

-- Show with emoji
showBoardEmoji :: Board -> String
showBoardEmoji board = unlines $
  [ "  0 1 2 3 4 5 6" 
  , "  " ++ replicate 14 '─'
  ] ++
  [ show row ++ "│" ++ unwords [showCellEmoji (getCell board (col, row)) | col <- [0..6]]
    | row <- [5,4..0]
  ] ++
  [ "  " ++ replicate 14 '─' ]

showCellEmoji :: Cell -> String
showCellEmoji Empty = "⚪"
showCellEmoji (Occupied Red) = "🔴"
showCellEmoji (Occupied Black) = "⚫"

-- ============================================================
-- NFData instances for parallel computing
-- ============================================================

instance NFData GameState where
  rnf (GameState b p h s c) = rnf b `seq` rnf p `seq` rnf h `seq` rnf s `seq` rnf c

instance NFData GameStatus where
  rnf InProgress = ()
  rnf (Winner p) = rnf p
  rnf Draw = ()

-- Board is already strict (Vector), so just evaluate to WHNF
instance NFData Board where
  rnf board = board `seq` ()