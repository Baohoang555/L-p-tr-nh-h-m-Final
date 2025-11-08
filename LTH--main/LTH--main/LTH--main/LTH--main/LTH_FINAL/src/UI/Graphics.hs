{-# LANGUAGE RecordWildCards #-}
module UI.Graphics where

import Graphics.Gloss
import Graphics.Gloss.Interface.Pure.Game
import Data.Maybe (fromMaybe)
import Control.Concurrent.STM
import Control.Monad (when)

import Game.Types
import Game.Board
import Game.Rules
import qualified Game.AI as AI

-- ============================================================
-- UI State
-- ============================================================

data UIState = UIState
  { uiGameState :: GameState
  , uiMode :: GameMode
  , uiHoverColumn :: Maybe Int
  , uiAnimations :: [Animation]
  , uiMessage :: Maybe String
  , uiAIConfig :: Maybe AI.AIConfig
  , uiShowMenu :: Bool
  , uiMenuSelection :: MenuOption
  } deriving (Show)

data GameMode
  = SinglePlayer Player  -- Human player color
  | TwoPlayer
  | AIvsAI
  | MainMenu
  deriving (Show, Eq)

data MenuOption
  = MenuSinglePlayer
  | MenuTwoPlayer
  | MenuAIvsAI
  | MenuLoadGame
  | MenuQuit
  deriving (Show, Eq, Enum, Bounded)

data Animation = PieceFalling
  { animColumn :: Int
  , animRow :: Int
  , animPlayer :: Player
  , animProgress :: Float  -- 0 to 1
  } deriving (Show)

-- ============================================================
-- UI Configuration
-- ============================================================

-- Window settings
windowWidth, windowHeight :: Int
windowWidth = 800
windowHeight = 700

-- Board dimensions
cellSize :: Float
cellSize = 80

boardOffsetX, boardOffsetY :: Float
boardOffsetX = -280
boardOffsetY = -200

-- Colors
backgroundColor :: Color
backgroundColor = makeColor 0.1 0.1 0.2 1.0

boardColor :: Color
boardColor = makeColor 0.2 0.4 0.8 1.0

redColor :: Color
redColor = makeColor 0.9 0.2 0.2 1.0

blackColor :: Color
blackColor = makeColor 0.2 0.2 0.2 1.0

hoverColor :: Color
hoverColor = makeColor 1.0 1.0 1.0 0.3

gridColor :: Color
gridColor = makeColor 0.1 0.2 0.5 1.0

-- ============================================================
-- Initialize UI
-- ============================================================

initialUIState :: GameMode -> UIState
initialUIState mode = UIState
  { uiGameState = newGame Red
  , uiMode = mode
  , uiHoverColumn = Nothing
  , uiAnimations = []
  , uiMessage = Nothing
  , uiAIConfig = if mode == SinglePlayer Black then Just AI.mediumAI else Nothing
  , uiShowMenu = mode == MainMenu
  , uiMenuSelection = MenuSinglePlayer
  }

-- ============================================================
-- Run Game
-- ============================================================

runGame :: GameMode -> IO ()
runGame mode = play
  (InWindow "Connect Four" (windowWidth, windowHeight) (100, 100))
  backgroundColor
  30  -- FPS
  (initialUIState mode)
  drawUI
  handleInput
  updateUI

-- Quick start functions
playSinglePlayer :: IO ()
playSinglePlayer = runGame (SinglePlayer Red)

playTwoPlayer :: IO ()
playTwoPlayer = runGame TwoPlayer

playAIvsAI :: IO ()
playAIvsAI = runGame AIvsAI

playFromMenu :: IO ()
playFromMenu = runGame MainMenu

-- ============================================================
-- Drawing
-- ============================================================

drawUI :: UIState -> Picture
drawUI state
  | uiShowMenu state = drawMenu state
  | otherwise = pictures
      [ drawBoard (board $ uiGameState state)
      , drawPieces (board $ uiGameState state)
      , drawAnimations (uiAnimations state)
      , drawHover state
      , drawStatus state
      , drawWinningLine state
      ]

-- Draw the blue board with holes
drawBoard :: Board -> Picture
drawBoard _ = pictures
  [ -- Board background
    translate boardOffsetX boardOffsetY $
    color boardColor $
    rectangleSolid (7 * cellSize + 20) (6 * cellSize + 20)
  
  , -- Grid lines
    translate boardOffsetX boardOffsetY $
    color gridColor $
    pictures $ concat
      [ [line [(-3.5 * cellSize, y), (3.5 * cellSize, y)] | y <- map (* cellSize) [-2.5, -1.5 .. 2.5]]
      , [line [(x, -2.5 * cellSize), (x, 2.5 * cellSize)] | x <- map (* cellSize) [-3 .. 3]]
      ]
  
  , -- Column numbers
    pictures [drawColumnNumber col | col <- [0..6]]
  ]

drawColumnNumber :: Int -> Picture
drawColumnNumber col =
  translate (boardOffsetX + fromIntegral col * cellSize - 3 * cellSize)
            (boardOffsetY + 3.5 * cellSize) $
  scale 0.2 0.2 $
  color white $
  text (show col)

-- Draw all pieces on board
drawPieces :: Board -> Picture
drawPieces board = pictures
  [ drawPiece col row (getCell board (col, row))
  | col <- [0..6]
  , row <- [0..5]
  ]

-- Draw a single piece
drawPiece :: Int -> Int -> Cell -> Picture
drawPiece col row cell = case cell of
  Empty -> blank
  Occupied player ->
    translate x y $
    color (playerColor player) $
    circleSolid (cellSize / 2 - 5)
  where
    x = boardOffsetX + fromIntegral col * cellSize - 3 * cellSize
    y = boardOffsetY + fromIntegral row * cellSize - 2.5 * cellSize

-- Draw animations
drawAnimations :: [Animation] -> Picture
drawAnimations = pictures . map drawAnimation

drawAnimation :: Animation -> Picture
drawAnimation (PieceFalling col row player progress) =
  translate x y $
  color (playerColor player) $
  circleSolid (cellSize / 2 - 5)
  where
    targetX = boardOffsetX + fromIntegral col * cellSize - 3 * cellSize
    startY = boardOffsetY + 4 * cellSize
    targetY = boardOffsetY + fromIntegral row * cellSize - 2.5 * cellSize
    x = targetX
    y = startY + (targetY - startY) * progress

-- Draw hover effect
drawHover :: UIState -> Picture
drawHover state = case uiHoverColumn state of
  Nothing -> blank
  Just col ->
    translate x (boardOffsetY + 3 * cellSize) $
    color hoverColor $
    circleSolid (cellSize / 2 - 5)
    where
      x = boardOffsetX + fromIntegral col * cellSize - 3 * cellSize

-- Draw status bar
drawStatus :: UIState -> Picture
drawStatus state = pictures
  [ -- Current player
    translate (-350) 300 $
    scale 0.15 0.15 $
    color white $
    text $ "Current Player: " ++ show (currentPlayer $ uiGameState state)
  
  , -- Move count
    translate (-350) 270 $
    scale 0.12 0.12 $
    color white $
    text $ "Moves: " ++ show (moveCount $ uiGameState state)
  
  , -- Game mode
    translate (-350) 240 $
    scale 0.12 0.12 $
    color white $
    text $ "Mode: " ++ show (uiMode state)
  
  , -- Message
    case uiMessage state of
        Nothing -> blank
        Just msg ->
          translate (-200) (-320) $
          scale 0.2 0.2 $
          color yellow $
          text msg
  ]

-- Draw winning line
drawWinningLine :: UIState -> Picture
drawWinningLine state = case findWinningLine (board $ uiGameState state) of
  Nothing -> blank
  Just winInfo -> pictures
    [ drawWinningPiece pos (winningPlayer winInfo)
    | pos <- winningPositions winInfo
    ]
  where
    drawWinningPiece (col, row) player =
      translate x y $
      color yellow $
      thickCircle (cellSize / 2 - 5) 4
      where
        x = boardOffsetX + fromIntegral col * cellSize - 3 * cellSize
        y = boardOffsetY + fromIntegral row * cellSize - 2.5 * cellSize

-- Draw main menu
drawMenu :: UIState -> Picture
drawMenu state = pictures
  [ -- Title
    translate (-150) 250 $
    scale 0.4 0.4 $
    color white $
    text "CONNECT FOUR"
  
  , -- Menu options
    pictures [drawMenuOption state opt | opt <- [minBound..maxBound]]
  
  , -- Instructions
    translate (-200) (-300) $
    scale 0.1 0.1 $
    color white $
    text "Use Arrow Keys to navigate, Enter to select"
  ]

drawMenuOption :: UIState -> MenuOption -> Picture
drawMenuOption state opt =
  translate (-150) y $
  color c $
  scale 0.2 0.2 $
  text (menuOptionText opt)
  where
    y = 100 - fromIntegral (fromEnum opt) * 50
    c = if uiMenuSelection state == opt then yellow else white

menuOptionText :: MenuOption -> String
menuOptionText MenuSinglePlayer = "Single Player vs AI"
menuOptionText MenuTwoPlayer = "Two Player"
menuOptionText MenuAIvsAI = "AI vs AI"
menuOptionText MenuLoadGame = "Load Game"
menuOptionText MenuQuit = "Quit"

-- ============================================================
-- Input Handling
-- ============================================================

handleInput :: Event -> UIState -> UIState
handleInput event state
  | uiShowMenu state = handleMenuInput event state
  | otherwise = handleGameInput event state

-- Handle menu input
handleMenuInput :: Event -> UIState -> UIState
handleMenuInput (EventKey (SpecialKey KeyUp) Down _ _) state =
  state { uiMenuSelection = prevOption (uiMenuSelection state) }
handleMenuInput (EventKey (SpecialKey KeyDown) Down _ _) state =
  state { uiMenuSelection = nextOption (uiMenuSelection state) }
handleMenuInput (EventKey (SpecialKey KeyEnter) Down _ _) state =
  selectMenuOption state
handleMenuInput _ state = state

-- Handle game input
handleGameInput :: Event -> UIState -> UIState
handleGameInput (EventMotion (x, y)) state =
  state { uiHoverColumn = getColumnFromMouse x y }
handleGameInput (EventKey (MouseButton LeftButton) Down _ (x, y)) state =
  case getColumnFromMouse x y of
    Nothing -> state
    Just col -> makePlayerMove state col
handleGameInput (EventKey (Char 'r') Down _ _) state =
  state { uiGameState = newGame Red, uiMessage = Just "Game reset!" }
handleGameInput (EventKey (Char 'u') Down _ _) state =
  undoMove state
handleGameInput (EventKey (SpecialKey KeyEsc) Down _ _) state =
  state { uiShowMenu = True }
handleGameInput _ state = state

-- Get column from mouse position
getColumnFromMouse :: Float -> Float -> Maybe Int
getColumnFromMouse x y
  | y < boardOffsetY - 3 * cellSize || y > boardOffsetY + 3 * cellSize = Nothing
  | col < 0 || col > 6 = Nothing
  | otherwise = Just col
  where
    relX = x - boardOffsetX + 3.5 * cellSize
    col = floor (relX / cellSize)

-- Make a move
makePlayerMove :: UIState -> Int -> UIState
makePlayerMove state col
  | not (isValidMove (board gs) col) = state { uiMessage = Just "Invalid move!" }
  | gameStatus gs /= InProgress = state { uiMessage = Just "Game over!" }
  | otherwise = case makeMove (board gs) col (currentPlayer gs) of
      Nothing -> state { uiMessage = Just "Column full!" }
      Just newBoard ->
        let newState = gs
              { board = newBoard
              , currentPlayer = nextPlayer (currentPlayer gs)
              , moveHistory = col : moveHistory gs
              , gameStatus = getGameResult newBoard
              , moveCount = moveCount gs + 1
              }
            row = fromMaybe 0 (getLowestEmptyRow (board gs) col)
            animation = PieceFalling col row (currentPlayer gs) 0.0
        in state
          { uiGameState = newState
          , uiAnimations = [animation]
          , uiMessage = case gameStatus newState of
              Winner p -> Just $ show p ++ " wins!"
              Draw -> Just "It's a draw!"
              InProgress -> Nothing
          }
  where
    gs = uiGameState state

-- Undo last move
undoMove :: UIState -> UIState
undoMove state = case undoLastMove (uiGameState state) of
  Nothing -> state { uiMessage = Just "Nothing to undo!" }
  Just newState -> state
    { uiGameState = newState
    , uiMessage = Just "Move undone"
    }

-- Menu navigation
prevOption :: MenuOption -> MenuOption
prevOption opt = if opt == minBound then maxBound else pred opt

nextOption :: MenuOption -> MenuOption
nextOption opt = if opt == maxBound then minBound else succ opt

-- Select menu option
selectMenuOption :: UIState -> UIState
selectMenuOption state = case uiMenuSelection state of
  MenuSinglePlayer -> state { uiShowMenu = False, uiMode = SinglePlayer Red, uiAIConfig = Just AI.mediumAI }
  MenuTwoPlayer -> state { uiShowMenu = False, uiMode = TwoPlayer }
  MenuAIvsAI -> state { uiShowMenu = False, uiMode = AIvsAI }
  MenuLoadGame -> state { uiMessage = Just "Load game not implemented" }
  MenuQuit -> state  -- TODO: proper quit

-- ============================================================
-- Update
-- ============================================================

updateUI :: Float -> UIState -> UIState
updateUI dt state
  | uiShowMenu state = state
  | otherwise = 
      let state' = updateAnimations dt state
          state'' = updateAI state'
      in state''

-- Update animations
updateAnimations :: Float -> UIState -> UIState
updateAnimations dt state =
  state { uiAnimations = filter (not . isAnimationComplete) updatedAnims }
  where
    updatedAnims = map (updateAnimation dt) (uiAnimations state)
    
    updateAnimation :: Float -> Animation -> Animation
    updateAnimation dt anim@(PieceFalling col row player progress) =
      anim { animProgress = min 1.0 (progress + dt * 3.0) }
    
    isAnimationComplete (PieceFalling _ _ _ progress) = progress >= 1.0

-- Update AI
updateAI :: UIState -> UIState
updateAI state
  | null (uiAnimations state) && shouldAIMove state = makeAIMove state
  | otherwise = state

-- Check if AI should move
shouldAIMove :: UIState -> Bool
shouldAIMove state =
  gameStatus (uiGameState state) == InProgress &&
  case uiMode state of
    SinglePlayer humanColor -> currentPlayer (uiGameState state) /= humanColor
    AIvsAI -> True
    _ -> False

-- Make AI move (simplified - should be async in real app)
makeAIMove :: UIState -> UIState
makeAIMove state = case uiAIConfig state of
  Nothing -> state
  Just cfg ->
    -- This is synchronous for simplicity
    -- In real app, use async/STM
    state  -- TODO: implement AI move

-- ============================================================
-- Helper Functions
-- ============================================================

playerColor :: Player -> Color
playerColor Red = redColor
playerColor Black = blackColor

-- ============================================================
-- Examples
-- ============================================================

-- Test UI
testUI :: IO ()
testUI = playFromMenu