{-# LANGUAGE ScopedTypeVariables #-}
module Main where

import Test.Hspec
import Test.QuickCheck
import Control.Exception (evaluate)

import qualified Game.Types as G
import qualified Game.Board as B
import qualified Game.Rules as R
import qualified Storage.Serialization as S

main :: IO ()
main = hspec $ do
  gameTypesSpec
  boardSpec
  rulesSpec
  serializationSpec
  propertySpec

-- ============================================================
-- Game Types Tests
-- ============================================================

gameTypesSpec :: Spec
gameTypesSpec = describe "Game.Types" $ do
  
  describe "Player" $ do
    it "switches between Red and Black" $ do
      G.nextPlayer G.Red `shouldBe` G.Black
      G.nextPlayer G.Black `shouldBe` G.Red
    
    it "is reflexive after two switches" $
      G.nextPlayer (G.nextPlayer G.Red) `shouldBe` G.Red
  
  describe "Cell" $ do
    it "detects empty cells" $
      G.isEmpty G.Empty `shouldBe` True
    
    it "detects occupied cells" $ do
      G.isEmpty (G.Occupied G.Red) `shouldBe` False
      G.isEmpty (G.Occupied G.Black) `shouldBe` False
    
    it "extracts player from occupied cell" $ do
      G.cellPlayer (G.Occupied G.Red) `shouldBe` Just G.Red
      G.cellPlayer G.Empty `shouldBe` Nothing
  
  describe "Board" $ do
    it "creates empty board with correct dimensions" $ do
      let board = G.emptyBoard
      G.boardWidth `shouldBe` 7
      G.boardHeight `shouldBe` 6
    
    it "all cells are empty in new board" $ do
      let board = G.emptyBoard
      all (== G.Empty) [G.getCell board (c, r) | c <- [0..6], r <- [0..5]] `shouldBe` True

-- ============================================================
-- Board Tests
-- ============================================================

boardSpec :: Spec
boardSpec = describe "Game.Board" $ do
  
  describe "isValidMove" $ do
    it "allows moves in empty columns" $ do
      let board = B.newBoard
      B.isValidMove board 3 `shouldBe` True
    
    it "rejects moves in full columns" $ do
      let moves = replicate 6 3  -- Fill column 3
      let Just board = B.boardFromMoves G.Red moves
      B.isValidMove board 3 `shouldBe` False
    
    it "rejects invalid column numbers" $ do
      let board = B.newBoard
      B.isValidMove board (-1) `shouldBe` False
      B.isValidMove board 7 `shouldBe` False
  
  describe "makeMove" $ do
    it "places piece at bottom of empty column" $ do
      let board = B.newBoard
      let Just newBoard = B.makeMove board 3 G.Red
      G.getCell newBoard (3, 0) `shouldBe` G.Occupied G.Red
    
    it "stacks pieces correctly" $ do
      let Just board1 = B.makeMove B.newBoard 3 G.Red
      let Just board2 = B.makeMove board1 3 G.Black
      G.getCell board2 (3, 0) `shouldBe` G.Occupied G.Red
      G.getCell board2 (3, 1) `shouldBe` G.Occupied G.Black
    
    it "returns Nothing for invalid moves" $ do
      let moves = replicate 6 3
      let Just fullBoard = B.boardFromMoves G.Red moves
      B.makeMove fullBoard 3 G.Red `shouldBe` Nothing
  
  describe "getLowestEmptyRow" $ do
    it "returns 0 for empty column" $
      B.getLowestEmptyRow B.newBoard 3 `shouldBe` Just 0
    
    it "returns correct row when partially filled" $ do
      let Just board = B.makeMove B.newBoard 3 G.Red
      B.getLowestEmptyRow board 3 `shouldBe` Just 1
    
    it "returns Nothing for full column" $ do
      let moves = replicate 6 3
      let Just board = B.boardFromMoves G.Red moves
      B.getLowestEmptyRow board 3 `shouldBe` Nothing
  
  describe "undoMove" $ do
    it "removes last piece from column" $ do
      let Just board1 = B.makeMove B.newBoard 3 G.Red
      let Just board2 = B.undoMove board1 3
      G.getCell board2 (3, 0) `shouldBe` G.Empty
    
    it "removes correct piece from stack" $ do
      let Just b1 = B.makeMove B.newBoard 3 G.Red
      let Just b2 = B.makeMove b1 3 G.Black
      let Just b3 = B.undoMove b2 3
      G.getCell b3 (3, 0) `shouldBe` G.Occupied G.Red
      G.getCell b3 (3, 1) `shouldBe` G.Empty

-- ============================================================
-- Rules Tests
-- ============================================================

rulesSpec :: Spec
rulesSpec = describe "Game.Rules" $ do
  
  describe "checkWinner" $ do
    it "detects horizontal win" $ do
      let board = R.testWinHorizontal
      R.checkWinner board `shouldBe` Just G.Red
    
    it "detects vertical win" $ do
      let board = R.testWinVertical
      R.checkWinner board `shouldBe` Just G.Red
    
    it "detects diagonal win" $ do
      let board = R.testWinDiagonal
      R.checkWinner board `shouldBe` Just G.Red
    
    it "returns Nothing for no winner" $ do
      let board = B.newBoard
      R.checkWinner board `shouldBe` Nothing
  
  describe "isDraw" $ do
    it "detects draw when board is full" $ do
      let board = R.testDraw
      R.isDraw board `shouldBe` True
    
    it "not a draw when board has spaces" $ do
      R.isDraw B.newBoard `shouldBe` False
  
  describe "isGameOver" $ do
    it "true when there's a winner" $ do
      let board = R.testWinHorizontal
      R.isGameOver board `shouldBe` True
    
    it "true when board is full" $ do
      let board = R.testDraw
      R.isGameOver board `shouldBe` True
    
    it "false when game in progress" $ do
      R.isGameOver B.newBoard `shouldBe` False
  
  describe "applyMove" $ do
    it "updates game state correctly" $ do
      let state = G.newGame G.Red
      let Just newState = R.applyMove state 3
      G.currentPlayer newState `shouldBe` G.Black
      G.moveCount newState `shouldBe` 1
      head (G.moveHistory newState) `shouldBe` 3
    
    it "rejects invalid moves" $ do
      let state = G.newGame G.Red
      R.applyMove state 10 `shouldBe` Nothing
    
    it "updates game status on win" $ do
      let moves = [0, 1, 0, 1, 0, 1]  -- Red wins vertically
      let states = scanl (\s m -> case s of
            Nothing -> Nothing
            Just st -> R.applyMove st m) (Just $ G.newGame G.Red) moves
      let Just finalState = last states
      G.gameStatus finalState `shouldBe` G.Winner G.Red

-- ============================================================
-- Serialization Tests
-- ============================================================

serializationSpec :: Spec
serializationSpec = describe "Storage.Serialization" $ do
  
  describe "Binary serialization" $ do
    it "round-trips GameState correctly" $ do
      let state = G.newGame G.Red
      let serialized = S.serializeGameState state
      let Just deserialized = S.deserializeGameState serialized
      G.moveCount deserialized `shouldBe` G.moveCount state
      G.currentPlayer deserialized `shouldBe` G.currentPlayer state
    
    it "round-trips Board correctly" $ do
      let board = B.newBoard
      let serialized = S.serializeBoard board
      let Just deserialized = S.deserializeBoard serialized
      deserialized `shouldBe` board
  
  describe "JSON serialization" $ do
    it "round-trips GameState correctly" $ do
      let state = G.newGame G.Red
      let serialized = S.serializeGameStateJSON state
      let Just deserialized = S.deserializeGameStateJSON serialized
      G.moveCount deserialized `shouldBe` G.moveCount state
  
  describe "Move history serialization" $ do
    it "serializes moves to string" $ do
      let moves = [0, 1, 2, 3, 4, 5, 6]
      S.serializeMoves moves `shouldBe` "0123456"
    
    it "deserializes moves from string" $ do
      let str = "0123456"
      S.deserializeMoves str `shouldBe` Just [0, 1, 2, 3, 4, 5, 6]
    
    it "rejects invalid move strings" $ do
      S.deserializeMoves "012x456" `shouldBe` Nothing
      S.deserializeMoves "0128" `shouldBe` Nothing

-- ============================================================
-- Property-based Tests
-- ============================================================

propertySpec :: Spec
propertySpec = describe "Property-based tests" $ do
  
  describe "Move validity" $ do
    it "valid moves always succeed on non-full boards" $ property $
      \(col :: Int) -> col >= 0 && col <= 6 ==>
        let board = B.newBoard
        in B.isValidMove board col == True
    
    it "making and undoing move returns to same board" $ property $
      \(col :: Int) -> col >= 0 && col <= 6 ==>
        let board = B.newBoard
            Just board1 = B.makeMove board col G.Red
            Just board2 = B.undoMove board1 col
        in board2 == board
  
  describe "Game state properties" $ do
    it "players alternate" $ property $
      \(moves :: [Int]) ->
        let validMoves = filter (\m -> m >= 0 && m <= 6) $ take 10 moves
            state = G.newGame G.Red
            states = scanl (\s m -> case s of
              Nothing -> Nothing
              Just st -> R.applyMove st m) (Just state) validMoves
            players = map (fmap G.currentPlayer) states
        in all isAlternating (zip players (tail players))
      where
        isAlternating (Just p1, Just p2) = p1 /= p2
        isAlternating _ = True
    
    it "move count increases by 1" $ property $
      \(col :: Int) -> col >= 0 && col <= 6 ==>
        let state = G.newGame G.Red
            Just newState = R.applyMove state col
        in G.moveCount newState == G.moveCount state + 1
  
  describe "Board properties" $ do
    it "total pieces equals move count" $ property $
      \(moves :: [Int]) ->
        let validMoves = filter (\m -> m >= 0 && m <= 6) $ take 20 moves
            Just finalBoard = B.boardFromMoves G.Red validMoves
            pieceCount = length [() | c <- [0..6], r <- [0..5], 
                                  not $ G.isEmpty $ G.getCell finalBoard (c, r)]
        in pieceCount == length validMoves

-- ============================================================
-- Helper Functions
-- ============================================================

-- Arbitraries for QuickCheck
instance Arbitrary G.Player where
  arbitrary = elements [G.Red, G.Black]

instance Arbitrary G.Cell where
  arbitrary = oneof
    [ return G.Empty
    , G.Occupied <$> arbitrary
    ]