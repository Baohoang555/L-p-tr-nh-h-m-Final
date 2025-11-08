{-# LANGUAGE DeriveGeneric #-}
module Network.Protocol where

import Game.Types
import Data.Aeson
import Data.Text (Text)
import qualified Data.Text as T
import Data.Binary
import GHC.Generics
import Data.ByteString.Lazy (ByteString)
import qualified Data.ByteString.Lazy as BL

-- ============================================================
-- Message Types
-- ============================================================

data Message 
  -- Client -> Server
  = JoinGame PlayerName
  | MakeMove Int                    -- Column (0-6)
  | ChatMessage Text
  | LeaveGame
  | RequestRematch
  
  -- Server -> Client
  | GameUpdate GameState
  | GameOver GameResult
  | WaitingForOpponent
  | OpponentConnected PlayerName
  | OpponentDisconnected
  | ErrorMsg Text
  | ChatReceived PlayerName Text
  | RematchRequest PlayerName
  | RematchAccepted
  | RematchDeclined
  
  -- Bidirectional
  | Ping
  | Pong
  deriving (Generic, Show, Eq)

instance ToJSON Message
instance FromJSON Message
instance Binary Message

type PlayerName = Text

-- ============================================================
-- Game Result (for end game)
-- ============================================================

data GameResult = GameResult
  { resultWinner :: Maybe Player
  , resultReason :: GameEndReason
  , resultMoveCount :: Int
  , resultPlayer1Name :: PlayerName
  , resultPlayer2Name :: PlayerName
  } deriving (Generic, Show, Eq)

instance ToJSON GameResult
instance FromJSON GameResult
instance Binary GameResult

data GameEndReason
  = NormalWin         -- 4 in a row
  | BoardFull         -- Draw
  | Resignation       -- Player quit
  | Timeout           -- Player didn't move in time
  | Disconnection     -- Player disconnected
  deriving (Generic, Show, Eq)

instance ToJSON GameEndReason
instance FromJSON GameEndReason
instance Binary GameEndReason

-- ============================================================
-- Server State Messages (Internal)
-- ============================================================

data ServerMessage
  = ClientConnected ClientId
  | ClientDisconnected ClientId
  | ClientMove ClientId Int
  | ClientChat ClientId Text
  deriving (Show, Eq)

type ClientId = Int

-- ============================================================
-- Lobby System
-- ============================================================

data LobbyState
  = EmptyLobby
  | WaitingForPlayer PlayerName
  | GameInProgress
  deriving (Show, Eq)

-- ============================================================
-- Message Validation
-- ============================================================

-- Validate column move
validateMove :: Int -> Either Text Int
validateMove col
  | col < 0 || col > 6 = Left "Invalid column: must be 0-6"
  | otherwise = Right col

-- Validate player name
validatePlayerName :: PlayerName -> Either Text PlayerName
validatePlayerName name
  | T.null name = Left "Player name cannot be empty"
  | T.length name > 20 = Left "Player name too long (max 20 characters)"
  | T.all (`elem` validChars) name = Right name
  | otherwise = Left "Player name contains invalid characters"
  where
    validChars = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_- "

-- Validate message
validateMessage :: Message -> Either Text Message
validateMessage msg@(JoinGame name) = JoinGame <$> validatePlayerName name
validateMessage msg@(MakeMove col) = MakeMove <$> validateMove col
validateMessage msg@(ChatMessage text)
  | T.length text > 500 = Left "Chat message too long (max 500 characters)"
  | otherwise = Right msg
validateMessage msg = Right msg

-- ============================================================
-- Message Encoding/Decoding
-- ============================================================

-- Encode message to ByteString (JSON)
encodeMessage :: Message -> ByteString
encodeMessage = encode

-- Decode message from ByteString
decodeMessage :: ByteString -> Maybe Message
decodeMessage = decode

-- Encode with validation
encodeMessageSafe :: Message -> Either Text ByteString
encodeMessageSafe msg = do
  validMsg <- validateMessage msg
  return $ encodeMessage validMsg

-- Decode with validation
decodeMessageSafe :: ByteString -> Either Text Message
decodeMessageSafe bs = 
  case decodeMessage bs of
    Nothing -> Left "Failed to decode message"
    Just msg -> validateMessage msg

-- ============================================================
-- Binary Encoding (for efficiency)
-- ============================================================

-- Encode message to binary
encodeBinary :: Message -> ByteString
encodeBinary = encode

-- Decode binary message
decodeBinary :: ByteString -> Maybe Message
decodeBinary bs = 
  case decodeOrFail bs of
    Right (_, _, msg) -> Just msg
    Left _ -> Nothing

-- ============================================================
-- Protocol Version
-- ============================================================

protocolVersion :: Int
protocolVersion = 1

data ProtocolHeader = ProtocolHeader
  { version :: Int
  , messageType :: Text
  , payloadLength :: Int
  } deriving (Generic, Show)

instance ToJSON ProtocolHeader
instance FromJSON ProtocolHeader

-- ============================================================
-- Error Handling
-- ============================================================

data ProtocolError
  = InvalidMessage Text
  | UnsupportedVersion Int
  | ParseError Text
  | ValidationError Text
  deriving (Show, Eq)

errorToMessage :: ProtocolError -> Message
errorToMessage (InvalidMessage msg) = ErrorMsg $ "Invalid message: " <> msg
errorToMessage (UnsupportedVersion v) = ErrorMsg $ "Unsupported protocol version: " <> T.pack (show v)
errorToMessage (ParseError msg) = ErrorMsg $ "Parse error: " <> msg
errorToMessage (ValidationError msg) = ErrorMsg $ "Validation error: " <> msg

-- ============================================================
-- Message Helpers
-- ============================================================

-- Create common messages
makeGameUpdateMsg :: GameState -> Message
makeGameUpdateMsg = GameUpdate

makeErrorMsg :: String -> Message
makeErrorMsg = ErrorMsg . T.pack

makeGameOverMsg :: Maybe Player -> GameEndReason -> Int -> PlayerName -> PlayerName -> Message
makeGameOverMsg winner reason moves p1 p2 = 
  GameOver $ GameResult winner reason moves p1 p2

makeChatMsg :: PlayerName -> Text -> Message
makeChatMsg = ChatReceived

-- Check message type
isClientMessage :: Message -> Bool
isClientMessage (JoinGame _) = True
isClientMessage (MakeMove _) = True
isClientMessage (ChatMessage _) = True
isClientMessage LeaveGame = True
isClientMessage RequestRematch = True
isClientMessage Ping = True
isClientMessage _ = False

isServerMessage :: Message -> Bool
isServerMessage = not . isClientMessage

-- ============================================================
-- Message Logging
-- ============================================================

-- Format message for logging (hide sensitive data)
formatMessageLog :: Message -> String
formatMessageLog (JoinGame name) = "JoinGame(" ++ T.unpack name ++ ")"
formatMessageLog (MakeMove col) = "MakeMove(" ++ show col ++ ")"
formatMessageLog (ChatMessage _) = "ChatMessage(...)"
formatMessageLog (GameUpdate _) = "GameUpdate(...)"
formatMessageLog msg = show msg

-- ============================================================
-- Statistics
-- ============================================================

data MessageStats = MessageStats
  { totalMessagesSent :: Int
  , totalMessagesReceived :: Int
  , messagesByType :: [(String, Int)]
  , avgMessageSize :: Double
  } deriving (Show, Generic)

instance ToJSON MessageStats
instance FromJSON MessageStats

-- ============================================================
-- Example Usage
-- ============================================================

exampleMessages :: IO ()
exampleMessages = do
  putStrLn "=== Network Protocol Examples ==="
  
  -- Join game
  let joinMsg = JoinGame "Alice"
  putStrLn $ "\nJoin: " ++ show joinMsg
  putStrLn $ "Encoded: " ++ show (BL.length $ encodeMessage joinMsg) ++ " bytes"
  
  -- Make move
  let moveMsg = MakeMove 3
  putStrLn $ "\nMove: " ++ show moveMsg
  putStrLn $ "Encoded: " ++ show (BL.length $ encodeMessage moveMsg) ++ " bytes"
  
  -- Game update
  let state = newGame Red
  let updateMsg = GameUpdate state
  putStrLn $ "\nGame Update: " ++ show (BL.length $ encodeMessage updateMsg) ++ " bytes"
  
  -- Validation
  case validatePlayerName "" of
    Left err -> putStrLn $ "\nValidation error: " ++ T.unpack err
    Right _ -> return ()
  
  case validateMove 10 of
    Left err -> putStrLn $ "Move validation error: " ++ T.unpack err
    Right _ -> return ()