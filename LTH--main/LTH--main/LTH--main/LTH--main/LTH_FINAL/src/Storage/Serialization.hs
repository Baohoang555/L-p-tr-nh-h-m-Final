{-# LANGUAGE DeriveGeneric #-}
{-# LANGUAGE FlexibleInstances #-}
module Storage.Serialization where

import Game.Types
import Data.Binary
import Data.Aeson (ToJSON, FromJSON, encode, decode, toJSON, parseJSON, (.:), (.=), object, withObject)
import qualified Data.Aeson as Aeson
import Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString.Lazy as BL
import Data.Vector (Vector)
import qualified Data.Vector as V
import GHC.Generics

-- ============================================================
-- Binary Instances (for efficient storage)
-- ============================================================

-- Binary instance for Player
instance Binary Player where
  put Red = putWord8 0
  put Black = putWord8 1
  
  get = do
    tag <- getWord8
    case tag of
      0 -> return Red
      1 -> return Black
      _ -> fail "Invalid Player tag"

-- Binary instance for Cell
instance Binary Cell where
  put Empty = putWord8 0
  put (Occupied player) = do
    putWord8 1
    put player
  
  get = do
    tag <- getWord8
    case tag of
      0 -> return Empty
      1 -> Occupied <$> get
      _ -> fail "Invalid Cell tag"

-- Binary instance for Vector (for Board)
instance Binary a => Binary (Vector a) where
  put vec = do
    put (V.length vec)
    V.mapM_ put vec
  
  get = do
    len <- get
    V.replicateM len get

-- Binary instance for Board
instance Binary Board where
  put board = put board
  get = get

-- Binary instance for GameStatus
instance Binary GameStatus where
  put InProgress = putWord8 0
  put (Winner player) = do
    putWord8 1
    put player
  put Draw = putWord8 2
  
  get = do
    tag <- getWord8
    case tag of
      0 -> return InProgress
      1 -> Winner <$> get
      2 -> return Draw
      _ -> fail "Invalid GameStatus tag"

-- Binary instance for GameState
instance Binary GameState where
  put state = do
    put (board state)
    put (currentPlayer state)
    put (moveHistory state)
    put (gameStatus state)
    put (moveCount state)
  
  get = GameState <$> get <*> get <*> get <*> get <*> get

-- ============================================================
-- Aeson JSON Instances (already derived via Generic)
-- ============================================================

-- These are already auto-derived in Types.hs via DeriveAnyClass
-- But we can add custom instances for better control:

instance ToJSON Board where
  toJSON board = toJSON $ V.toList $ V.map V.toList board

instance FromJSON Board where
  parseJSON = withObject "Board" $ \v -> do
    lists <- parseJSON (Aeson.Object v)
    return $ V.fromList $ map V.fromList lists

-- Alternative: more compact representation
-- Encode board as a single string: "RRBB.R..."
boardToString :: Board -> String
boardToString board = concatMap cellToChar [getCell board (c, r) | r <- [5,4..0], c <- [0..6]]
  where
    cellToChar Empty = "."
    cellToChar (Occupied Red) = "R"
    cellToChar (Occupied Black) = "B"

boardFromString :: String -> Maybe Board
boardFromString str
  | length str /= 42 = Nothing  -- 7x6 = 42 cells
  | otherwise = Just $ foldl placeCell emptyBoard (zip [0..] str)
  where
    placeCell b (idx, char) = 
      let col = idx `mod` 7
          row = 5 - (idx `div` 7)
          cell = charToCell char
      in setCell b (col, row) cell
    
    charToCell '.' = Empty
    charToCell 'R' = Occupied Red
    charToCell 'B' = Occupied Black
    charToCell _ = Empty

-- ============================================================
-- High-level Serialization Functions
-- ============================================================

-- Serialize Board to ByteString (Binary format)
serializeBoard :: Board -> ByteString
serializeBoard = encode

-- Deserialize Board from ByteString
deserializeBoard :: ByteString -> Maybe Board
deserializeBoard bs = case decodeOrFail bs of
  Right (_, _, board) -> Just board
  Left _ -> Nothing

-- Serialize GameState to ByteString (Binary format)
serializeGameState :: GameState -> ByteString
serializeGameState = encode

-- Deserialize GameState from ByteString
deserializeGameState :: ByteString -> Maybe GameState
deserializeGameState bs = case decodeOrFail bs of
  Right (_, _, state) -> Just state
  Left _ -> Nothing

-- Serialize to JSON
serializeGameStateJSON :: GameState -> ByteString
serializeGameStateJSON = Aeson.encode

-- Deserialize from JSON
deserializeGameStateJSON :: ByteString -> Maybe GameState
deserializeGameStateJSON = Aeson.decode

-- ============================================================
-- Compact Move History Serialization
-- ============================================================

-- Serialize move history as compact string: "0123456..."
serializeMoves :: [Int] -> String
serializeMoves = map intToChar
  where intToChar n = toEnum (n + 48)  -- '0' = 48 in ASCII

-- Deserialize move history
deserializeMoves :: String -> Maybe [Int]
deserializeMoves str = 
  if all isValidChar str
    then Just $ map charToInt str
    else Nothing
  where
    isValidChar c = c >= '0' && c <= '6'
    charToInt c = fromEnum c - 48

-- ============================================================
-- File Format Versioning
-- ============================================================

data FileFormat = FileFormat
  { formatVersion :: Int
  , formatType :: String
  , payload :: ByteString
  } deriving (Generic)

instance Binary FileFormat
instance ToJSON FileFormat
instance FromJSON FileFormat

-- Current version
currentVersion :: Int
currentVersion = 1

-- Wrap data with version info
wrapWithVersion :: ByteString -> FileFormat
wrapWithVersion bs = FileFormat
  { formatVersion = currentVersion
  , formatType = "ConnectFour"
  , payload = bs
  }

-- Unwrap and validate version
unwrapWithVersion :: FileFormat -> Maybe ByteString
unwrapWithVersion fmt
  | formatVersion fmt == currentVersion && formatType fmt == "ConnectFour" = Just (payload fmt)
  | otherwise = Nothing

-- ============================================================
-- Compression (optional)
-- ============================================================

-- For very large save files, we could add compression
-- import Codec.Compression.GZip (compress, decompress)

compressData :: ByteString -> ByteString
compressData = id  -- Placeholder: use GZip.compress in real implementation

decompressData :: ByteString -> ByteString
decompressData = id  -- Placeholder: use GZip.decompress

-- ============================================================
-- Validation
-- ============================================================

-- Validate that deserialized data is valid
validateGameState :: GameState -> Bool
validateGameState state =
  validBoard (board state) &&
  validMoveHistory (moveHistory state) &&
  validMoveCount (moveCount state) (moveHistory state)
  where
    validBoard b = V.length b == 7 && V.all (\col -> V.length col == 6) b
    validMoveHistory moves = all (\m -> m >= 0 && m <= 6) moves
    validMoveCount count history = count == length history

-- Safe deserialization with validation
safeDeserializeGameState :: ByteString -> Maybe GameState
safeDeserializeGameState bs = do
  state <- deserializeGameState bs
  if validateGameState state
    then Just state
    else Nothing

-- ============================================================
-- Example Usage
-- ============================================================

exampleSerialization :: IO ()
exampleSerialization = do
  let state = newGame Red
  
  -- Binary serialization
  let binary = serializeGameState state
  putStrLn $ "Binary size: " ++ show (BL.length binary) ++ " bytes"
  
  -- JSON serialization
  let json = serializeGameStateJSON state
  putStrLn $ "JSON size: " ++ show (BL.length json) ++ " bytes"
  
  -- Round-trip test
  case deserializeGameState binary of
    Just state' -> putStrLn "✅ Binary round-trip successful"
    Nothing -> putStrLn "❌ Binary deserialization failed"
  
  case deserializeGameStateJSON json of
    Just state' -> putStrLn "✅ JSON round-trip successful"
    Nothing -> putStrLn "❌ JSON deserialization failed"