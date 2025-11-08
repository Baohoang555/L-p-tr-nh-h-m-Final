{-# LANGUAGE DeriveGeneric #-}
module Storage.Statistics where

import Game.Types
import Data.Aeson
import qualified Data.Aeson as Aeson
import qualified Data.ByteString.Lazy as BL
import Data.List (sortBy)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Ord (comparing, Down(..))
import Data.Time.Clock (getCurrentTime, UTCTime)
import Data.Time.Format (formatTime, defaultTimeLocale)
import GHC.Generics
import System.Directory (createDirectoryIfMissing, doesFileExist)
import System.FilePath ((</>))

-- ============================================================
-- Player Profile
-- ============================================================

data PlayerProfile = PlayerProfile
  { playerName :: String
  , totalGames :: Int
  , wins :: Int
  , losses :: Int
  , draws :: Int
  , winStreak :: Int
  , bestWinStreak :: Int
  , totalMoves :: Int
  , averageMovesPerGame :: Double
  , rating :: Int           -- ELO-like rating
  , achievements :: [Achievement]
  , lastPlayed :: Maybe String
  } deriving (Show, Generic)

instance ToJSON PlayerProfile
instance FromJSON PlayerProfile

-- Initialize new player
newPlayer :: String -> PlayerProfile
newPlayer name = PlayerProfile
  { playerName = name
  , totalGames = 0
  , wins = 0
  , losses = 0
  , draws = 0
  , winStreak = 0
  , bestWinStreak = 0
  , totalMoves = 0
  , averageMovesPerGame = 0
  , rating = 1000  -- Starting rating
  , achievements = []
  , lastPlayed = Nothing
  }

-- Calculate win rate
winRate :: PlayerProfile -> Double
winRate profile
  | totalGames profile == 0 = 0
  | otherwise = fromIntegral (wins profile) / fromIntegral (totalGames profile) * 100

-- ============================================================
-- Game Statistics
-- ============================================================

data GameStats = GameStats
  { gameId :: String
  , player1Name :: String
  , player2Name :: String
  , winner :: Maybe String
  , totalMovesPlayed :: Int
  , duration :: Maybe Int  -- seconds
  , timestamp :: String
  } deriving (Show, Generic)

instance ToJSON GameStats
instance FromJSON GameStats

-- ============================================================
-- Achievements
-- ============================================================

data Achievement
  = FirstWin
  | WinStreak5
  | WinStreak10
  | PerfectGame        -- Win in minimum moves
  | ComebachVictory    -- Win after being behind
  | SpeedDemon         -- Win in under 30 seconds
  | Strategic          -- Win with 100+ rating
  | AISlayer           -- Beat hard AI
  deriving (Show, Eq, Generic)

instance ToJSON Achievement
instance FromJSON Achievement

achievementName :: Achievement -> String
achievementName FirstWin = "🏆 First Victory"
achievementName WinStreak5 = "🔥 On Fire (5 wins)"
achievementName WinStreak10 = "⚡ Unstoppable (10 wins)"
achievementName PerfectGame = "💎 Perfect Game"
achievementName ComebachVictory = "🎯 Comeback King"
achievementName SpeedDemon = "⚡ Speed Demon"
achievementName Strategic = "🧠 Strategic Master"
achievementName AISlayer = "🤖 AI Slayer"

-- ============================================================
-- Update Player Stats
-- ============================================================

data GameResult = Win Player | Draw
  deriving (Show, Eq)

-- Update profile after game
updateProfile :: PlayerProfile -> GameResult -> GameStats -> PlayerProfile
updateProfile profile result stats = 
  let profile1 = profile 
        { totalGames = totalGames profile + 1
        , totalMoves = totalMoves profile + totalMovesPlayed stats
        }
      profile2 = case result of
        Win _ -> profile1
          { wins = wins profile1 + 1
          , winStreak = winStreak profile1 + 1
          , bestWinStreak = max (bestWinStreak profile1) (winStreak profile1 + 1)
          }
        Draw -> profile1
          { draws = draws profile1 + 1
          , winStreak = 0
          }
      profile3 = profile2
        { averageMovesPerGame = fromIntegral (totalMoves profile2) / 
                                fromIntegral (totalGames profile2)
        }
  in checkAchievements profile3

-- Check and award achievements
checkAchievements :: PlayerProfile -> PlayerProfile
checkAchievements profile = 
  profile { achievements = newAchievements }
  where
    current = achievements profile
    newAchievements = current ++ checkNew
    
    checkNew = filter (`notElem` current)
      [ FirstWin | wins profile >= 1 ]
      ++ [ WinStreak5 | bestWinStreak profile >= 5 ]
      ++ [ WinStreak10 | bestWinStreak profile >= 10 ]
      ++ [ Strategic | rating profile >= 1100 ]

-- ============================================================
-- ELO Rating System
-- ============================================================

-- Calculate new ratings after a game
updateRatings :: Int -> Int -> GameResult -> (Int, Int)
updateRatings rating1 rating2 result = 
  let k = 32.0  -- K-factor
      expected1 = 1.0 / (1.0 + 10.0 ** ((fromIntegral rating2 - fromIntegral rating1) / 400.0))
      expected2 = 1.0 - expected1
      
      (actual1, actual2) = case result of
        Win p -> if playerWon p then (1.0, 0.0) else (0.0, 1.0)
        Draw -> (0.5, 0.5)
      
      newRating1 = rating1 + round (k * (actual1 - expected1))
      newRating2 = rating2 + round (k * (actual2 - expected2))
  in (newRating1, newRating2)
  where
    playerWon Red = True  -- Assume player 1 is Red
    playerWon Black = False

-- ============================================================
-- Leaderboard
-- ============================================================

data LeaderboardEntry = LeaderboardEntry
  { entryName :: String
  , entryRating :: Int
  , entryWins :: Int
  , entryGames :: Int
  , entryWinRate :: Double
  } deriving (Show, Generic)

instance ToJSON LeaderboardEntry
instance FromJSON LeaderboardEntry

-- Convert profile to leaderboard entry
toLeaderboardEntry :: PlayerProfile -> LeaderboardEntry
toLeaderboardEntry profile = LeaderboardEntry
  { entryName = playerName profile
  , entryRating = rating profile
  , entryWins = wins profile
  , entryGames = totalGames profile
  , entryWinRate = winRate profile
  }

-- Generate leaderboard from profiles
generateLeaderboard :: [PlayerProfile] -> [LeaderboardEntry]
generateLeaderboard profiles = 
  sortBy (comparing (Down . entryRating)) $
  map toLeaderboardEntry profiles

-- Top N players
topPlayers :: Int -> [PlayerProfile] -> [LeaderboardEntry]
topPlayers n profiles = take n (generateLeaderboard profiles)

-- ============================================================
-- Storage
-- ============================================================

statsDirectory :: FilePath
statsDirectory = "stats"

profilesFile :: FilePath
profilesFile = statsDirectory </> "profiles.json"

leaderboardFile :: FilePath
leaderboardFile = statsDirectory </> "leaderboard.json"

gamesHistoryFile :: FilePath
gamesHistoryFile = statsDirectory </> "games_history.json"

-- Initialize stats directory
initStatsDirectory :: IO ()
initStatsDirectory = createDirectoryIfMissing True statsDirectory

-- ============================================================
-- Save/Load Profiles
-- ============================================================

type ProfileDatabase = Map String PlayerProfile

-- Load all profiles
loadProfiles :: IO ProfileDatabase
loadProfiles = do
  initStatsDirectory
  exists <- doesFileExist profilesFile
  if not exists
    then return Map.empty
    else do
      content <- BL.readFile profilesFile
      case Aeson.decode content of
        Just db -> return db
        Nothing -> return Map.empty

-- Save all profiles
saveProfiles :: ProfileDatabase -> IO ()
saveProfiles db = do
  initStatsDirectory
  let content = Aeson.encode db
  BL.writeFile profilesFile content

-- Get or create profile
getProfile :: String -> IO PlayerProfile
getProfile name = do
  db <- loadProfiles
  return $ Map.findWithDefault (newPlayer name) name db

-- Update profile in database
updateProfileDB :: PlayerProfile -> IO ()
updateProfileDB profile = do
  db <- loadProfiles
  let db' = Map.insert (playerName profile) profile db
  saveProfiles db'

-- ============================================================
-- Save/Load Game History
-- ============================================================

type GamesHistory = [GameStats]

-- Load games history
loadGamesHistory :: IO GamesHistory
loadGamesHistory = do
  initStatsDirectory
  exists <- doesFileExist gamesHistoryFile
  if not exists
    then return []
    else do
      content <- BL.readFile gamesHistoryFile
      case Aeson.decode content of
        Just history -> return history
        Nothing -> return []

-- Save game to history
saveGameStats :: GameStats -> IO ()
saveGameStats stats = do
  history <- loadGamesHistory
  let history' = stats : history
  let content = Aeson.encode history'
  BL.writeFile gamesHistoryFile content

-- ============================================================
-- Leaderboard Management
-- ============================================================

-- Generate and save leaderboard
updateLeaderboard :: IO ()
updateLeaderboard = do
  db <- loadProfiles
  let profiles = Map.elems db
  let leaderboard = generateLeaderboard profiles
  let content = Aeson.encode leaderboard
  BL.writeFile leaderboardFile content

-- Load leaderboard
loadLeaderboard :: IO [LeaderboardEntry]
loadLeaderboard = do
  exists <- doesFileExist leaderboardFile
  if not exists
    then return []
    else do
      content <- BL.readFile leaderboardFile
      case Aeson.decode content of
        Just lb -> return lb
        Nothing -> return []

-- Print leaderboard
printLeaderboard :: Int -> IO ()
printLeaderboard n = do
  leaderboard <- loadLeaderboard
  let top = take n leaderboard
  
  putStrLn "\n🏆 LEADERBOARD 🏆"
  putStrLn $ replicate 70 '='
  putStrLn $ padRight 5 "Rank" ++ padRight 20 "Player" ++ padRight 10 "Rating" 
          ++ padRight 10 "Wins" ++ padRight 10 "Games" ++ padRight 15 "Win Rate"
  putStrLn $ replicate 70 '-'
  
  mapM_ printEntry (zip [1..] top)
  putStrLn $ replicate 70 '='
  where
    printEntry (rank, entry) = putStrLn $
      padRight 5 (show rank) ++
      padRight 20 (entryName entry) ++
      padRight 10 (show $ entryRating entry) ++
      padRight 10 (show $ entryWins entry) ++
      padRight 10 (show $ entryGames entry) ++
      padRight 15 (show (round $ entryWinRate entry) ++ "%")

-- ============================================================
-- Statistics Reports
-- ============================================================

-- Print player statistics
printPlayerStats :: String -> IO ()
printPlayerStats name = do
  profile <- getProfile name
  
  putStrLn $ "\n📊 Statistics for " ++ name
  putStrLn $ replicate 50 '='
  putStrLn $ "Total Games:       " ++ show (totalGames profile)
  putStrLn $ "Wins:              " ++ show (wins profile)
  putStrLn $ "Losses:            " ++ show (losses profile)
  putStrLn $ "Draws:             " ++ show (draws profile)
  putStrLn $ "Win Rate:          " ++ show (round $ winRate profile) ++ "%"
  putStrLn $ "Current Streak:    " ++ show (winStreak profile)
  putStrLn $ "Best Streak:       " ++ show (bestWinStreak profile)
  putStrLn $ "Rating:            " ++ show (rating profile)
  putStrLn $ "Avg Moves/Game:    " ++ show (round $ averageMovesPerGame profile)
  putStrLn $ "\n🏅 Achievements:"
  if null (achievements profile)
    then putStrLn "  No achievements yet"
    else mapM_ (\a -> putStrLn $ "  " ++ achievementName a) (achievements profile)
  putStrLn $ replicate 50 '='

-- ============================================================
-- Utilities
-- ============================================================

-- Pad string to right
padRight :: Int -> String -> String
padRight n s = s ++ replicate (n - length s) ' '

-- Pad string to left
padLeft :: Int -> String -> String
padLeft n s = replicate (n - length s) ' ' ++ s

-- ============================================================
-- Testing
-- ============================================================

testStatistics :: IO ()
testStatistics = do
  putStrLn "\n🧪 Testing Statistics"
  
  -- Create test profile
  let alice = newPlayer "Alice"
  
  -- Simulate some games
  let stats1 = GameStats "1" "Alice" "Bob" (Just "Alice") 20 (Just 60) "2025-01-01"
  let alice1 = updateProfile alice (Win Red) stats1
  
  let stats2 = GameStats "2" "Alice" "Charlie" (Just "Alice") 25 (Just 90) "2025-01-02"
  let alice2 = updateProfile alice1 (Win Red) stats2
  
  -- Save profile
  updateProfileDB alice2
  
  -- Load and print
  printPlayerStats "Alice"
  
  -- Test leaderboard
  updateLeaderboard
  printLeaderboard 10
  
  putStrLn "✅ Statistics test complete"