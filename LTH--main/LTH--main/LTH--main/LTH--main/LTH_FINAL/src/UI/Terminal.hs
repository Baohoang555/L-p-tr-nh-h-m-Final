{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE TemplateHaskell #-}
module UI.Terminal where

import Brick
import Brick.Widgets.Border
import Brick.Widgets.Border.Style
import Brick.Widgets.Center
import qualified Graphics.Vty as V
import Control.Monad (void)
import Lens.Micro.TH
import Lens.Micro

import Game.Types
import Game.Board
import Game.Rules
import qualified Game.AI as AI

-- ============================================================
-- App State
-- ============================================================

data AppState = AppState
  { _gameState :: GameState
  , _gameMode :: GameMode
  , _cursorColumn :: Int
  , _statusMessage :: String
  , _aiConfig :: Maybe AI.AIConfig
  , _showHelp :: Bool
  } deriving (Show)

makeLenses ''AppState

data GameMode
  = SinglePlayer Player
  | TwoPlayer
  | AIDemo
  deriving (Show, Eq)

-- Resource name for focus
data Name = BoardFocus
  deriving (Show, Eq, Ord)

-- ============================================================
-- Initialize App
-- ============================================================

initialState :: GameMode -> AppState
initialState mode = AppState
  { _gameState = newGame Red
  , _gameMode = mode
  , _cursorColumn = 3
  , _statusMessage = "Welcome to Connect Four!"
  , _aiConfig = if mode == SinglePlayer Black then Just AI.easyAI else Nothing
  , _showHelp = False
  }

-- ============================================================
-- Drawing
-- ============================================================

drawUI :: AppState -> [Widget Name]
drawUI state = [ui]
  where
    ui = vBox
      [ drawHeader
      , padTop (Pad 1) $ drawBoard state
      , padTop (Pad 1) $ drawStatus state
      , padTop (Pad 1) $ drawControls
      , if _showHelp state then drawHelp else emptyWidget
      ]

-- Draw header
drawHeader :: Widget Name
drawHeader = 
  withBorderStyle unicode $
  borderWithLabel (str " CONNECT FOUR ") $
  center $
  padLeftRight 2 $
  str "Terminal Edition"

-- Draw the game board
drawBoard :: AppState -> Widget Name
drawBoard state = center $ vBox
  [ drawColumnNumbers (_cursorColumn state)
  , drawBoardCells (board $ _gameState state) (_cursorColumn state)
  , str "  └─┴─┴─┴─┴─┴─┴─┘"
  ]

-- Draw column numbers with cursor
drawColumnNumbers :: Int -> Widget Name
drawColumnNumbers cursor = hBox
  [ str "  "
  , hBox [drawColNum i (i == cursor) | i <- [0..6]]
  ]
  where
    drawColNum i isCursor =
      let num = show i
          style = if isCursor then withAttr "cursor" else id
      in style $ str $ " " ++ num

-- Draw board cells
drawBoardCells :: Board -> Int -> Widget Name
drawBoardCells board cursor = vBox
  [ str "  ┌─┬─┬─┬─┬─┬─┬─┐"
  , vBox [drawRow board row cursor | row <- [5,4..0]]
  ]

-- Draw a single row
drawRow :: Board -> Int -> Int -> Widget Name
drawRow board row cursor = hBox
  [ str "  │"
  , hBox [drawCell board (col, row) (col == cursor) | col <- [0..6]]
  ]

-- Draw a single cell
drawCell :: Board -> Position -> Bool -> Widget Name
drawCell board pos isCursor =
  let cell = getCell board pos
      cellChar = case cell of
        Empty -> " "
        Occupied Red -> "●"
        Occupied Black -> "○"
      style = case cell of
        Empty -> if isCursor then withAttr "cursor" else id
        Occupied Red -> withAttr "red"
        Occupied Black -> withAttr "black"
  in style (str cellChar) <+> str "│"

-- Draw status bar
drawStatus :: AppState -> Widget Name
drawStatus state = center $ vBox
  [ hBox
      [ str "Player: "
      , withAttr (playerAttr $ currentPlayer gs) $
          str $ show (currentPlayer gs)
      , str "  |  Move: "
      , str $ show (moveCount gs)
      ]
  , str $ _statusMessage state
  , case gameStatus gs of
      Winner p -> withAttr "winner" $ str $ "🏆 " ++ show p ++ " WINS!"
      Draw -> withAttr "draw" $ str "🤝 DRAW!"
      InProgress -> emptyWidget
  ]
  where
    gs = _gameState state
    playerAttr Red = "red"
    playerAttr Black = "black"

-- Draw controls
drawControls :: Widget Name
drawControls = center $ str "←→: Move  Space/Enter: Drop  R: Reset  U: Undo  H: Help  Q: Quit"

-- Draw help overlay
drawHelp :: Widget Name
drawHelp = center $ withBorderStyle unicode $ border $ padAll 1 $ vBox
  [ str "HELP"
  , str ""
  , str "←/→ or h/l : Move cursor left/right"
  , str "Space/Enter : Drop piece"
  , str "R           : Reset game"
  , str "U           : Undo last move"
  , str "H           : Toggle this help"
  , str "Q/Esc       : Quit"
  , str ""
  , str "Press any key to close"
  ]

-- ============================================================
-- Event Handling
-- ============================================================

handleEvent :: AppState -> BrickEvent Name e -> EventM Name (Next AppState)
handleEvent state (VtyEvent e) =
  case e of
    -- Help toggle
    V.EvKey (V.KChar 'h') [] | not (_showHelp state) ->
      continue $ state & showHelp .~ True
    
    V.EvKey _ [] | _showHelp state ->
      continue $ state & showHelp .~ False
    
    -- Quit
    V.EvKey (V.KChar 'q') [] -> halt state
    V.EvKey V.KEsc [] -> halt state
    
    -- Movement
    V.EvKey V.KLeft [] ->
      continue $ state & cursorColumn %~ max 0 . subtract 1
    V.EvKey V.KRight [] ->
      continue $ state & cursorColumn %~ min 6 . (+1)
    V.EvKey (V.KChar 'h') [] ->
      continue $ state & cursorColumn %~ max 0 . subtract 1
    V.EvKey (V.KChar 'l') [] ->
      continue $ state & cursorColumn %~ min 6 . (+1)
    
    -- Drop piece
    V.EvKey V.KEnter [] -> handleDrop state
    V.EvKey (V.KChar ' ') [] -> handleDrop state
    
    -- Reset
    V.EvKey (V.KChar 'r') [] ->
      continue $ state 
        & gameState .~ newGame Red
        & statusMessage .~ "Game reset!"
    
    -- Undo
    V.EvKey (V.KChar 'u') [] -> handleUndo state
    
    _ -> continue state

handleEvent state _ = continue state

-- Handle dropping a piece
handleDrop :: AppState -> EventM Name (Next AppState)
handleDrop state
  | gameStatus (_gameState state) /= InProgress =
      continue $ state & statusMessage .~ "Game over! Press R to restart"
  | otherwise =
      let col = _cursorColumn state
          gs = _gameState state
      in case makeMove (board gs) col (currentPlayer gs) of
        Nothing -> continue $ state & statusMessage .~ "Column full!"
        Just newBoard ->
          let newGS = gs
                { board = newBoard
                , currentPlayer = nextPlayer (currentPlayer gs)
                , moveHistory = col : moveHistory gs
                , gameStatus = getGameResult newBoard
                , moveCount = moveCount gs + 1
                }
              msg = case gameStatus newGS of
                Winner p -> show p ++ " wins!"
                Draw -> "It's a draw!"
                InProgress -> "Move made"
          in continue $ state
            & gameState .~ newGS
            & statusMessage .~ msg

-- Handle undo
handleUndo :: AppState -> EventM Name (Next AppState)
handleUndo state = case undoLastMove (_gameState state) of
  Nothing -> continue $ state & statusMessage .~ "Nothing to undo!"
  Just newGS -> continue $ state
    & gameState .~ newGS
    & statusMessage .~ "Move undone"

-- ============================================================
-- Attributes
-- ============================================================

theMap :: AttrMap
theMap = attrMap V.defAttr
  [ ("red", fg V.red)
  , ("black", fg V.white)
  , ("cursor", bg V.blue)
  , ("winner", fg V.yellow `V.withStyle` V.bold)
  , ("draw", fg V.cyan)
  ]

-- ============================================================
-- App Definition
-- ============================================================

app :: App AppState e Name
app = App
  { appDraw = drawUI
  , appChooseCursor = neverShowCursor
  , appHandleEvent = handleEvent
  , appStartEvent = return
  , appAttrMap = const theMap
  }

-- ============================================================
-- Run App
-- ============================================================

runTerminalUI :: GameMode -> IO ()
runTerminalUI mode = do
  let buildVty = V.mkVty V.defaultConfig
  initialVty <- buildVty
  void $ customMain initialVty buildVty Nothing app (initialState mode)

-- Quick start functions
playSinglePlayerTUI :: IO ()
playSinglePlayerTUI = runTerminalUI (SinglePlayer Red)

playTwoPlayerTUI :: IO ()
playTwoPlayerTUI = runTerminalUI TwoPlayer

playAIDemoTUI :: IO ()
playAIDemoTUI = runTerminalUI AIDemo

-- ============================================================
-- Main Menu TUI
-- ============================================================

data MenuState = MenuState
  { _menuSelection :: Int
  , _menuOptions :: [String]
  }

makeLenses ''MenuState

menuInitial :: MenuState
menuInitial = MenuState
  { _menuSelection = 0
  , _menuOptions = 
      [ "Single Player vs AI"
      , "Two Player Local"
      , "AI Demo"
      , "Quit"
      ]
  }

drawMenu :: MenuState -> [Widget Name]
drawMenu state = [ui]
  where
    ui = center $ vBox
      [ padAll 2 $ str "CONNECT FOUR"
      , padAll 1 $ vBox $ zipWith (drawOption state) [0..] (_menuOptions state)
      , padTop (Pad 2) $ str "Use ↑↓ to navigate, Enter to select"
      ]

drawOption :: MenuState -> Int -> String -> Widget Name
drawOption state idx opt =
  let selected = idx == _menuSelection state
      prefix = if selected then "> " else "  "
      attr = if selected then withAttr "cursor" else id
  in attr $ str $ prefix ++ opt

handleMenuEvent :: MenuState -> BrickEvent Name e -> EventM Name (Next MenuState)
handleMenuEvent state (VtyEvent e) =
  case e of
    V.EvKey V.KUp [] ->
      continue $ state & menuSelection %~ max 0 . subtract 1
    V.EvKey V.KDown [] ->
      continue $ state & menuSelection %~ min (length (_menuOptions state) - 1) . (+1)
    V.EvKey V.KEnter [] -> halt state
    V.EvKey (V.KChar 'q') [] -> halt state
    V.EvKey V.KEsc [] -> halt state
    _ -> continue state
handleMenuEvent state _ = continue state

menuApp :: App MenuState e Name
menuApp = App
  { appDraw = drawMenu
  , appChooseCursor = neverShowCursor
  , appHandleEvent = handleMenuEvent
  , appStartEvent = return
  , appAttrMap = const theMap
  }

runMenu :: IO (Maybe GameMode)
runMenu = do
  let buildVty = V.mkVty V.defaultConfig
  initialVty <- buildVty
  finalState <- customMain initialVty buildVty Nothing menuApp menuInitial
  return $ case _menuSelection finalState of
    0 -> Just (SinglePlayer Red)
    1 -> Just TwoPlayer
    2 -> Just AIDemo
    _ -> Nothing

-- Run game from menu
runGameFromMenu :: IO ()
runGameFromMenu = do
  mMode <- runMenu
  case mMode of
    Just mode -> runTerminalUI mode
    Nothing -> putStrLn "Goodbye!"

-- ============================================================
-- Testing
-- ============================================================

testTerminalUI :: IO ()
testTerminalUI = runGameFromMenu