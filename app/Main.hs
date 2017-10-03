{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric #-}

module Main where

import           GHC.Generics (Generic)
import           System.IO.Unsafe (unsafePerformIO)
import           System.Environment (getArgs, getProgName)
import           System.Console.GetOpt
import           System.Random
import           Control.Concurrent
import           Control.Concurrent.MVar
import           Control.Monad.IO.Class (liftIO)
import           Control.Monad (forever, forM, forM_, mzero, liftM)
import           Control.Monad.Trans.Class (lift)
import           Control.Monad.Trans.Either
import           Control.Distributed.Process
import           Control.Distributed.Process.Closure
import           Control.Distributed.Process.Node hiding (newLocalNode)
import           Control.Distributed.Process.Backend.SimpleLocalnet
import           Control.Distributed.Process.Extras.Time
import           Control.Distributed.Process.Extras.Timer
import           Network.Transport.TCP (createTransport, defaultTCPParameters)
import           Data.Time.Clock
import           Data.Time.Clock.POSIX
import           Data.Binary
import           Data.Maybe (fromJust, fromMaybe)
import           Data.List (insertBy, sortBy)
import           Data.Ord (comparing)
import           System.Exit
import           System.IO (hPutStrLn, stderr)
import           Lib (NodeConfig(..), nodes)

------------------------------------------------------------------------------
-- | Receive i messages or waits for them to arrive.
receiveN :: Int -> Process [(ProcessId, Double, Double)]
receiveN i = receiveN' i []
  where
    receiveN' 0 ms = return ms
    receiveN' i ms = do
      m <- receiveWait
        [ matchAny (\m -> do
                       s <- unwrapMessage m :: Process (Maybe (ProcessId, Double, Double))
                       return s
                   ) ]
      case m of
        Just m' ->
          receiveN' (i-1) (m':ms)
        Nothing -> do
          receiveN' i ms

------------------------------------------------------------------------------
-- | Drain all the messages in the mailbox and stop when Nothing is
-- | encountered.
drainAll :: Process [(ProcessId, Double, Double)]
drainAll = drain' []
  where
    drain' ms = do
      m <- receiveTimeout 1000
        [ matchAny (\m -> do
                       s <- unwrapMessage m :: Process (Maybe (ProcessId, Double, Double))
                       return s
                   ) ]
      case m of
        Just m' ->
          case m' of
            Just m'' ->
              drain' (m'':ms)
            Nothing ->
              drain' ms
        Nothing -> do
          return ms

------------------------------------------------------------------------------
-- The RNG process has two data types associated with it which are made
-- remotable.
--
-- RandomState is used to keep track of the state of the RNG process.
-- RandomMessage is used to communicate specific messages to the process and
--  potentially cause a perturbation of the state.
------------------------------------------------------------------------------

data RandomState =
    RandomInit Int [(ProcessId, Int)]  -- ^ The initial state.
  | RandomNext Int [(ProcessId, Int)]  -- ^ A state used to reset the process Id list.
  | Generate Int [(ProcessId, Int)] [(ProcessId, Int, RandomMessage)]
    -- ^ The state where the process is generating messages.
  deriving (Generic, Show)

instance Binary RandomState

data RandomMessage =
    GetRandom ProcessId                -- ^ Get a random message from the RNG process.
  | RandomResult Double Double         -- ^ RNG process sends a result.
  deriving (Generic, Show)

instance Binary RandomMessage

------------------------------------------------------------------------------
-- The peer process has a state and a set of messages, similar to the RNG
-- process.
------------------------------------------------------------------------------

data ProcessState =
    -- | The process must be provisioned with a root id to send results back to.
    Provisioning ProcessId
    -- | The process samples random numbers from the RNG process and sends to
    -- | peers.
  | Sampling ProcessId ProcessId [ProcessId]
    -- | After sampling the process accumulates all the messages sent to itself
    -- | and sends this back to the node which spawned the peer process.
  | Receiving ProcessId Int
    deriving (Generic, Show)

instance Binary ProcessState

data ProcessMessage =
    -- | The peer process initially receives a ProvisioningResult, meaning a
    -- | root pid and a list of others (pids spawned on peers).
    ProvisioningResult ProcessId [ProcessId]
    -- | The peer process receives a sample from the RNG process.
  | Sample (ProcessId, Double, Double)
    deriving (Generic, Show)

instance Binary ProcessMessage

------------------------------------------------------------------------------
-- | The smallest possible float > 0.0 (0,1].
minPositiveFloat :: RealFloat a => a -> a
minPositiveFloat a =
  encodeFloat 1 $ fst (floatRange a) - floatDigits a

------------------------------------------------------------------------------
-- | The random process which generates random numbers deterministically.
-- | An initial list of ProcessIds is expected at initialisation which helps
-- | the generator know the peer ordering.
rngProcess :: RandomState -> Process ()
rngProcess (RandomInit seed pidOrdList) = do
  rngProcess (Generate seed pidOrdList [])
rngProcess (RandomNext seed pidOrdList) = do
  rngProcess (Generate seed pidOrdList [])
rngProcess (Generate seed pidOrdList messages) = do
  if length messages >= length pidOrdList then do
    let messagesOrd = sortBy (comparing (\(_,i,_) -> i)) messages
    forM_ messagesOrd $ \(pid, _, m) -> do
      send pid m
    rngProcess (RandomNext seed pidOrdList)
    else do
    rm <- expect :: Process RandomMessage
    case rm of
      GetRandom rootPid -> do
        t <- liftIO $ getCurrentTime
        let s = realToFrac $ utcTimeToPOSIXSeconds t :: Double
        let (r, _) = randomR (minPositiveFloat 0.0, 1.0) (mkStdGen seed)
        let (Just i) = lookup rootPid pidOrdList
        rngProcess (Generate (seed + 1) pidOrdList ((rootPid, i, RandomResult r s):messages))
      _ -> do
        liftIO $ putStrLn "error: Unexpected state in RNG process."
        return ()

------------------------------------------------------------------------------
-- | The main peer process which is spawned n times on each peer, where n is
-- | determined by (k / dfps). The peer processes are expected to send a
-- | result back to the root process (the node in this case).
peerProcess :: ProcessState -> Process ()
peerProcess (Provisioning rootPid) = do
  pm <- expect :: Process ProcessMessage
  case pm of
    ProvisioningResult rngPid pidList -> do
      peerProcess (Sampling rootPid rngPid pidList)
      return ()
    _ -> do
      -- error: unexpected message for this state.
      return ()
peerProcess (Sampling rootPid rngPid pids) = do
  -- Request a random number from the seeded RNG process on this peer.
  self <- getSelfPid
  send rngPid (GetRandom self)
  rm <- expect :: Process RandomMessage
  case rm of
    RandomResult r t -> do
      -- Send random result to all other pids including self.
      forM_ (self:pids) $ \pid ->
        send pid (self, r, t)
      -- Switch to receive peer process messages.
      peerProcess (Receiving rootPid (length (self:pids)))
      return ()
    _ -> do
      -- error: unexpected message for this state.
      return ()
peerProcess (Receiving rootPid i) = do
  ms <- receiveN i
  forM_ ms $ \m -> do
    send rootPid m
  return ()

remotable ['rngProcess, 'peerProcess]

customRemoteTable :: RemoteTable
customRemoteTable =
  Main.__remoteTable initRemoteTable

------------------------------------------------------------------------------
-- | Send to each pid a list of the other pids in the network and the pid of
-- | this nodes rng process.
provision :: ProcessId -> [ProcessId] -> Process ()
provision rng pids = provision' pids []
  where
    provision' [] prev =
      return ()
    provision' (pid:pids) prev = do
      send pid (ProvisioningResult rng (prev ++ pids))
      provision' pids (pid:prev)

------------------------------------------------------------------------------
-- | Runs the main peer process during the initial period.
runPeerProcess :: NodeId -> ProcessId -> [NodeId] -> MVar Int -> Int -> Integer -> Process ()
runPeerProcess this self peers count seed dfps = do
  let npeers = length peers

  i <- liftIO $ takeMVar count
  liftIO $ putMVar count (i + npeers)

  -- Spawn a process on each peer which waits to be provisioned.
  pidList <- forM peers $ \peer -> do
    pid <- spawn peer $ $(mkClosure 'peerProcess) (Provisioning self)
    return pid

  let pidOrdList = zipWith (\pid i -> (pid, i)) pidList [0..npeers]

  rng <- spawn this $ $(mkClosure 'rngProcess) (RandomInit seed pidOrdList)

  -- Provision each process with the list of other pids.
  provision rng pidList

  -- Here there is a thread delay according to the data frames per second.
  let delay = round (1000000.0 / fromIntegral dfps)
  liftIO $ threadDelay delay

------------------------------------------------------------------------------
-- | From an initial node configuration, start a node with deadlines 'k' and
-- | 'l' where k is the amount of time where processes should send random
-- | values between (0,1] to one another and l is the grace period.
runNode :: NodeConfig -> Integer -> Integer -> Int -> Bool -> Integer -> IO ()
runNode (NodeConfig host port) k l seed drain dfps = do
  -- Initialise a backend with a custom remoteTable.
  backend <- initializeBackend host port customRemoteTable

  -- Wait for the peers to boot up.
  threadDelay 5000

  node    <- newLocalNode backend
  peers   <- findPeers backend 1000000

  count <- newMVar 0

  runProcess node $ do
    self <- getSelfPid
    this <- getSelfNode

    liftIO . putStrLn $ "Found " ++ show (length peers) ++ " peers @ " ++ show self

    liftIO . putStrLn $ "Starting communications @ " ++ show self

    --------------------------------------------------------------------------------
    -- Communication Period
    --------------------------------------------------------------------------------

    ut <- liftIO $ getCurrentTime
    loop $ do
      now <- liftIO $ getCurrentTime

      -- Work out difference in time between start and now and the time limit imposed
      -- by k.
      let dt = diffUTCTime now ut
      let tlim = realToFrac $ secondsToDiffTime k

      -- If the time limit has been reached a check is made to ensure that this node
      -- has sent sufficient messages (mlim). If it hasnt then it tries catch up to the
      -- others by sending up to the amount expected.

      -- The amount of messages we expect is the data frames per second rate times the
      -- length of the period given by k multiplied by the amount of peers we are
      -- connected to.
      let mlim = dfps * k * (fromIntegral $ length peers)
      if dt > tlim then do
        i <- lift $ liftIO $ takeMVar count
        if fromIntegral i >= mlim then do
          -- lift $ liftIO $ putStrLn ("dfps * k * len(P) = " ++ show mlim)
          lift $ liftIO $ putMVar count i
          quit ()
          else do
          lift $ liftIO $ putMVar count i
          lift $ runPeerProcess this self peers count seed dfps
        else do
        lift $ runPeerProcess this self peers count seed dfps
        return ()

    --------------------------------------------------------------------------------
    -- Grace Period
    --------------------------------------------------------------------------------

    -- Now that the communication loop has ended, enter the grace period. (now + l)
    liftIO $ putStrLn $ "Entering grace period @ " ++ show self

    i <- liftIO $ takeMVar count

    lst <- if drain then do
      lst <- drainAll
      return lst
      else do
      lst <- receiveN (i * length peers)
      return lst

    let acc = sortBy (comparing snd) $ map (\ (_, r, t) -> (1.0 * r, t)) lst
    let (rs, ts) = unzip acc

    let len = length acc

    let prod = foldr (+) 0.0 rs

    liftIO $ putStrLn $ "RESULT => < " ++ show len ++ ", " ++ show prod  ++ " > @ " ++ show self
    return ()

  return ()

------------------------------------------------------------------------------
-- | Forks a node to a concurrent process and increments the seed per peer.
runNodes :: [NodeConfig] -> Integer -> Integer -> Int -> Bool -> Integer -> IO ()
runNodes [] _ _ _ _ _ = return ()
runNodes (nodeConfig:nodes) k l seed drain dfps = do
  _ <- forkChild (runNode nodeConfig k l seed drain dfps)
  runNodes nodes k l (seed + 1) drain dfps

------------------------------------------------------------------------------
-- | Wait for the nodes to converge or exit if deadline has been reached.
children :: MVar [MVar ()]
children = unsafePerformIO (newMVar [])

waitUntil ut deadline = do
  cs <- tryTakeMVar children
  case cs of
    Just [] -> do
      putStrLn "Exiting (nodes converged)"
      return ()
    Just (m:ms) -> do
      now <- getCurrentTime
      if now > deadline then do
        putStrLn "Exiting (deadline reached)"
        return ()
        else do
        putMVar children ms
        takeMVar m
        waitUntil ut deadline
    Nothing -> do
      now <- getCurrentTime
      if now > deadline then do
        putStrLn "Exiting (deadline reached)"
        return ()
        else do
        threadDelay 1000
        waitUntil ut deadline

forkChild :: IO () -> IO ThreadId
forkChild io = do
  mvar <- newEmptyMVar
  cs <- takeMVar children
  putMVar children (mvar:cs)
  forkFinally io (\_ -> putMVar mvar ())

------------------------------------------------------------------------------
-- | Application entry point.
main :: IO ()
main = do
  args <- getArgs

  let (actions, nonOptions, errors) = getOpt RequireOrder options args

  opts <- foldl (>>=) (return defaultOptions) actions

  -- Program should exit at k + l regardless of what happens.
  ut <- getCurrentTime
  let seconds = realToFrac $ secondsToDiffTime (optSendFor opts + optWaitFor opts)
  let deadline = addUTCTime seconds ut

  runNodes nodes (optSendFor opts) (optWaitFor opts) (optSeed opts) (optDrain opts) (optDFPS opts)

  waitUntil ut deadline

------------------------------------------------------------------------------
-- Utilities for looping gracefully forever
------------------------------------------------------------------------------

loop :: Monad m => EitherT e m a -> m e
loop = liftM (either id id) . runEitherT . forever

quit :: Monad m => e -> EitherT e m r
quit = left

------------------------------------------------------------------------------
-- Console Options
------------------------------------------------------------------------------

data Options = Options
  { optSendFor :: Integer
  , optWaitFor :: Integer
  , optSeed :: Int
  , optDrain :: Bool
  , optDFPS :: Integer
  } deriving (Show)

defaultOptions = Options
  { optSendFor = 5
  , optWaitFor = 5
  , optSeed = 1
  , optDrain = False
  , optDFPS = 3
  }

options :: [OptDescr (Options -> IO Options)]
options =
  [ Option [] ["send-for"] (OptArg inputK "k") "The initial deadline in seconds."
  , Option [] ["wait-for"] (OptArg inputL "l") "The grace period in seconds."
  , Option [] ["seed"] (OptArg inputS "s") "The RNG seed (Int)."
  , Option [] ["drain"] (NoArg inputD) "The process used to accumulate messages in the grace period."
  , Option [] ["dfps"] (OptArg inputF "dfps") "The amount of data frames to send per second. Increasing this value makes the network less reliable."
  , Option [] ["help"] (NoArg printHelp) "Displays usage information."
  ]

inputK :: Maybe String -> Options -> IO Options
inputK arg opt =
  return opt { optSendFor = read $ fromMaybe "5" arg }

inputL :: Maybe String -> Options -> IO Options
inputL arg opt =
  return opt { optWaitFor = read $ fromMaybe "5" arg }

inputS :: Maybe String -> Options -> IO Options
inputS arg opt =
  return opt { optSeed = read $ fromMaybe "1" arg }

inputD :: Options -> IO Options
inputD opt =
  return opt { optDrain = True }

inputF :: Maybe String -> Options -> IO Options
inputF arg opt =
  return opt { optDFPS = read $ fromMaybe "3" arg }

printHelp :: Options -> IO Options
printHelp opt = do
  prg <- getProgName
  hPutStrLn stderr (usageInfo prg options)
  exitWith ExitSuccess
