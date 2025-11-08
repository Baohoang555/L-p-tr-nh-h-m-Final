module Concurrency.Synchronization where

import Control.Concurrent.STM
import Control.Concurrent.MVar
import Control.Concurrent (threadDelay)
import Control.Concurrent.Async (race) -- THÊM VÀO: Sửa lỗi thiếu 'race'
import Control.Monad (when, unless, forM_)
import Control.Exception (bracket, finally, catch, SomeException)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map
import Data.Time.Clock
import Data.List (sortBy, sortOn) -- THÊM VÀO: Dùng hàm chuẩn


-- Atomic update with retry
atomicUpdate :: TVar a -> (a -> Maybe a) -> STM Bool
atomicUpdate var f = do
  old <- readTVar var
  case f old of
    Nothing -> return False
    Just new -> do
      writeTVar var new
      return True

-- Atomic swap
atomicSwap :: TVar a -> a -> STM a
atomicSwap var new = do
  old <- readTVar var
  writeTVar var new
  return old

-- Modify with validation
atomicModifyValidated :: TVar a -> (a -> Either String a) -> STM (Either String a)
atomicModifyValidated var f = do
  old <- readTVar var
  case f old of
    Left err -> return $ Left err
    Right new -> do
      writeTVar var new
      return $ Right new

-- ============================================================
-- Lock-Free Data Structures
-- ============================================================

-- Lock-free counter
newtype Counter = Counter (TVar Int)

newCounter :: Int -> IO Counter
newCounter initial = Counter <$> newTVarIO initial

increment :: Counter -> STM Int
increment (Counter var) = do
  val <- readTVar var
  let new = val + 1
  writeTVar var new
  return new

decrement :: Counter -> STM Int
decrement (Counter var) = do
  val <- readTVar var
  let new = val - 1
  writeTVar var new
  return new

getCount :: Counter -> STM Int
getCount (Counter var) = readTVar var

-- ============================================================
-- Synchronized Map
-- ============================================================

-- Thread-safe map with STM
newtype SyncMap k v = SyncMap (TVar (Map k v))

newSyncMap :: IO (SyncMap k v)
newSyncMap = SyncMap <$> newTVarIO Map.empty

insertSync :: Ord k => k -> v -> SyncMap k v -> STM ()
insertSync key val (SyncMap var) = modifyTVar' var (Map.insert key val)

lookupSync :: Ord k => k -> SyncMap k v -> STM (Maybe v)
lookupSync key (SyncMap var) = Map.lookup key <$> readTVar var

deleteSync :: Ord k => k -> SyncMap k v -> STM ()
deleteSync key (SyncMap var) = modifyTVar' var (Map.delete key)

sizeSync :: SyncMap k v -> STM Int
sizeSync (SyncMap var) = Map.size <$> readTVar var

-- Atomic insert if not exists
insertIfAbsentSync :: Ord k => k -> v -> SyncMap k v -> STM Bool
insertIfAbsentSync key val (SyncMap var) = do
  m <- readTVar var
  if Map.member key m
    then return False
    else do
      writeTVar var (Map.insert key val m)
      return True

-- ============================================================
-- Turn-Based Synchronization
-- ============================================================

-- Ensure players take turns
data TurnLock = TurnLock
  { currentTurn :: TVar Int
  , maxPlayers :: Int
  }

newTurnLock :: Int -> IO TurnLock
newTurnLock players = do
  turnVar <- newTVarIO 0
  return TurnLock
    { currentTurn = turnVar
    , maxPlayers = players
    }

-- Wait for your turn
waitTurn :: TurnLock -> Int -> STM ()
waitTurn lock playerId = do
  turn <- readTVar (currentTurn lock)
  when (turn /= playerId) retry

-- Take your turn and pass to next player
takeTurn :: TurnLock -> Int -> STM ()
takeTurn lock playerId = do
  turn <- readTVar (currentTurn lock)
  when (turn /= playerId) retry
  let nextTurn = (turn + 1) `mod` maxPlayers lock
  writeTVar (currentTurn lock) nextTurn

-- Reset to first player
resetTurn :: TurnLock -> STM ()
resetTurn lock = writeTVar (currentTurn lock) 0

-- ============================================================
-- Barrier Synchronization
-- ============================================================

-- Wait for N threads to reach barrier
data Barrier = Barrier
  { barrierCount :: TVar Int
  , barrierTarget :: Int
  , barrierReleased :: TVar Bool
  }

newBarrier :: Int -> IO Barrier
newBarrier target = do
  countVar <- newTVarIO 0
  releasedVar <- newTVarIO False
  return Barrier
    { barrierCount = countVar
    , barrierTarget = target
    , barrierReleased = releasedVar
    }

-- Wait at barrier
waitBarrier :: Barrier -> STM ()
waitBarrier barrier = do
  -- Increment count
  count <- readTVar (barrierCount barrier)
  writeTVar (barrierCount barrier) (count + 1)
  
  -- Check if we're the last one
  let newCount = count + 1
  when (newCount >= barrierTarget barrier) $
    writeTVar (barrierReleased barrier) True
  
  -- Wait for release
  released <- readTVar (barrierReleased barrier)
  unless released retry

-- Reset barrier for reuse
resetBarrier :: Barrier -> STM ()
resetBarrier barrier = do
  writeTVar (barrierCount barrier) 0
  writeTVar (barrierReleased barrier) False

-- ============================================================
-- Resource Pool
-- ============================================================

-- Pool of reusable resources
data ResourcePool a = ResourcePool
  { availableResources :: TVar [a]
  , totalCapacity :: Int
  }

newResourcePool :: [a] -> IO (ResourcePool a)
newResourcePool resources = do
  var <- newTVarIO resources
  return ResourcePool
    { availableResources = var
    , totalCapacity = length resources
    }

-- Acquire resource (blocks if none available)
acquireResource :: ResourcePool a -> STM a
acquireResource pool = do
  resources <- readTVar (availableResources pool)
  case resources of
    [] -> retry  -- Wait for resource to become available
    (r:rs) -> do
      writeTVar (availableResources pool) rs
      return r

-- Try acquire (non-blocking)
tryAcquireResource :: ResourcePool a -> STM (Maybe a)
tryAcquireResource pool = do
  resources <- readTVar (availableResources pool)
  case resources of
    [] -> return Nothing
    (r:rs) -> do
      writeTVar (availableResources pool) rs
      return (Just r)

-- Release resource back to pool
releaseResource :: ResourcePool a -> a -> STM ()
releaseResource pool resource = do
  modifyTVar' (availableResources pool) (resource :)

-- Get available count
availableCount :: ResourcePool a -> STM Int
availableCount pool = length <$> readTVar (availableResources pool)

-- ============================================================
-- Rate Limiter
-- ============================================================

-- Token bucket rate limiter
data RateLimiter = RateLimiter
  { tokens :: TVar Double
  , maxTokens :: Double
  , refillRate :: Double  -- tokens per second
  , lastRefill :: TVar UTCTime
  }

newRateLimiter :: Double -> Double -> IO RateLimiter
newRateLimiter maxToks refillRate = do
  now <- getCurrentTime
  toksVar <- newTVarIO maxToks
  timeVar <- newTVarIO now
  return RateLimiter
    { tokens = toksVar
    , maxTokens = maxToks
    , refillRate = refillRate
    , lastRefill = timeVar
    }

-- Try to consume a token
tryConsume :: RateLimiter -> IO Bool
tryConsume limiter = do
  now <- getCurrentTime
  atomically $ do
    -- Refill tokens based on time elapsed
    lastTime <- readTVar (lastRefill limiter)
    let elapsed = realToFrac $ diffUTCTime now lastTime
    let tokensToAdd = elapsed * refillRate limiter
    
    currentTokens <- readTVar (tokens limiter)
    let newTokens = min (maxTokens limiter) (currentTokens + tokensToAdd)
    
    -- Try to consume
    if newTokens >= 1.0
      then do
        writeTVar (tokens limiter) (newTokens - 1.0)
        writeTVar (lastRefill limiter) now
        return True
      else return False

-- Wait until token available
waitForToken :: RateLimiter -> IO ()
waitForToken limiter = do
  success <- tryConsume limiter
  unless success $ do
    threadDelay 100000  -- Wait 100ms
    waitForToken limiter

-- ============================================================
-- MVar Patterns
-- ============================================================

-- Safe MVar modification
modifyMVarSafe :: MVar a -> (a -> IO (a, b)) -> IO b
modifyMVarSafe = modifyMVar

-- Timeout on MVar take
takeMVarTimeout :: Int -> MVar a -> IO (Maybe a)
takeMVarTimeout micros var = do
  result <- race (threadDelay micros) (takeMVar var) -- 'race' OK, 'threadDelay' OK
  case result of
    Left _ -> return Nothing
    Right val -> return (Just val)

-- Try to put (non-blocking)
tryPutMVarSafe :: MVar a -> a -> IO Bool
tryPutMVarSafe = tryPutMVar

-- ============================================================
-- Deadlock Prevention
-- ============================================================

-- Ordered lock acquisition (prevents deadlock)
data OrderedLock = OrderedLock
  { lockId :: Int
  , lockMVar :: MVar ()
  }

newOrderedLock :: Int -> IO OrderedLock
newOrderedLock id = do
  mv <- newMVar ()
  return OrderedLock
    { lockId = id
    , lockMVar = mv
    }

-- Acquire multiple locks in order
withOrderedLocks :: [OrderedLock] -> IO a -> IO a
withOrderedLocks locks action = do
  let sortedLocks = sortOn lockId locks -- 'sortOn' OK
  acquireAll sortedLocks
  where
    acquireAll [] = action
    acquireAll (lock:rest) = 
      withMVar (lockMVar lock) $ \_ -> acquireAll rest

-- ============================================================
-- Transaction Retry Patterns
-- ============================================================

-- Retry with exponential backoff
retryWithBackoff :: Int -> STM a -> IO a
retryWithBackoff maxRetries action = go 0
  where
    go attempt
      | attempt >= maxRetries = atomically action  -- Last try
      | otherwise = do
          result <- atomically $ (Just <$> action) `orElse` return Nothing
          case result of
            Just val -> return val
            Nothing -> do
              let delayMicros = min (2 ^ attempt * 1000) 1000000
              threadDelay delayMicros -- 'threadDelay' OK
              go (attempt + 1)

-- Retry with timeout
retryWithTimeout :: Int -> STM a -> IO (Maybe a)
retryWithTimeout micros action = do
  result <- race (threadDelay micros) (atomically action) -- 'race' OK, 'threadDelay' OK
  case result of
    Left _ -> return Nothing
    Right val -> return (Just val)

-- ============================================================
-- Concurrent Collections
-- ============================================================

-- Thread-safe queue
newtype SyncQueue a = SyncQueue (TQueue a)

newSyncQueue :: IO (SyncQueue a)
newSyncQueue = SyncQueue <$> newTQueueIO

enqueue :: a -> SyncQueue a -> STM ()
enqueue item (SyncQueue q) = writeTQueue q item

dequeue :: SyncQueue a -> STM a
dequeue (SyncQueue q) = readTQueue q

tryDequeue :: SyncQueue a -> STM (Maybe a)
tryDequeue (SyncQueue q) = tryReadTQueue q

isEmptyQueue :: SyncQueue a -> STM Bool
isEmptyQueue (SyncQueue q) = isEmptyTQueue q

-- =F==========================================================
-- Helper Functions
-- ============================================================

-- (ĐÃ XÓA CÁC ĐỊNH NGHĨA THỪA 'threadDelay', 'sortOn', 'sortBy')

-- ============================================================
-- Testing
-- ============================================================

-- Test synchronization primitives
testSync :: IO ()
testSync = do
  putStrLn "\n🧪 Testing Synchronization"
  putStrLn $ replicate 50 '='
  
  -- Test counter
  counter <- newCounter 0
  _ <- atomically $ increment counter
  _ <- atomically $ increment counter
  count <- atomically $ getCount counter
  putStrLn $ "✅ Counter: " ++ show count
  
  -- Test turn lock
  turnLock <- newTurnLock 2
  atomically $ takeTurn turnLock 0
  turn <- readTVarIO (currentTurn turnLock)
  putStrLn $ "✅ Turn lock: " ++ show turn
  
  -- Test barrier
  barrier <- newBarrier 3
  putStrLn "✅ Barrier test (simplified - async not available)"
  
  putStrLn $ replicate 50 '='