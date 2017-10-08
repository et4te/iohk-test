{-# LANGUAGE RecordWildCards #-}

module Main where

import           Control.Distributed.Process
import           Control.Distributed.Process.Node (initRemoteTable)
import           Control.Distributed.Process.Backend.SimpleLocalnet
import           System.Environment (getArgs, getProgName)
import           System.Console.GetOpt
import           System.Random (mkStdGen, setStdGen)
import           System.Exit
import           System.IO (hPutStrLn, stderr)
import           Data.Maybe (fromMaybe)
import qualified IOHKExercise

------------------------------------------------------------------------------

rtable :: RemoteTable
rtable = IOHKExercise.__remoteTable initRemoteTable

------------------------------------------------------------------------------

main :: IO ()
main = do
  args <- getArgs

  let (actions, _nonOptions, _errors) = getOpt RequireOrder options args

  Options{..} <- foldl (>>=) (return defaultOptions) actions

  case optNodeType of
    Master -> do
      backend <- initializeBackend optHost optPort rtable
      startMaster backend $ \slaves -> do
        result <- IOHKExercise.master optSendFor optWaitFor slaves
        liftIO $ print result
        terminateAllSlaves backend
    Slave -> do
      setStdGen (mkStdGen optSeed)
      backend <- initializeBackend optHost optPort rtable
      startSlave backend

------------------------------------------------------------------------------
-- Console Options
------------------------------------------------------------------------------

data NodeType = Master | Slave
  deriving (Show)

asNodeType "master" =
  Master
asNodeType "slave" =
  Slave
asNodeType _ =
  error "Invalid nodeType"

data Options = Options
  { optNodeType :: NodeType
  , optHost :: String
  , optPort :: String
  , optSendFor :: Integer
  , optWaitFor :: Integer
  , optSeed :: Int
  } deriving (Show)

defaultOptions :: Options
defaultOptions = Options
  { optNodeType = Slave
  , optHost = "localhost"
  , optPort = "4001"
  , optSendFor = 3
  , optWaitFor = 3
  , optSeed = 1
  }

options :: [OptDescr (Options -> IO Options)]
options =
  [ Option [] ["node-type"] (OptArg inputNode "node") "Node type (e.g master / slave)."
  , Option [] ["host"] (OptArg inputHost "host") "Hostname (e.g localhost)"
  , Option [] ["port"] (OptArg inputPort "port") "Port (e.g 4001)"
  , Option [] ["send-for"] (OptArg inputK "k") "The initial deadline in seconds."
  , Option [] ["wait-for"] (OptArg inputL "l") "The grace period in seconds."
  , Option [] ["seed"] (OptArg inputS "s") "The RNG seed (Int)."
  , Option [] ["help"] (NoArg printHelp) "Displays usage information."
  ]

inputNode :: Maybe String -> Options -> IO Options
inputNode arg opt =
  return opt { optNodeType = asNodeType $ fromMaybe "slave" arg }

inputHost :: Maybe String -> Options -> IO Options
inputHost arg opt =
  return opt { optHost = fromMaybe "localhost" arg }

inputPort :: Maybe String -> Options -> IO Options
inputPort arg opt =
  return opt { optPort = fromMaybe "4001" arg }

inputK :: Maybe String -> Options -> IO Options
inputK arg opt =
  return opt { optSendFor = read $ fromMaybe "5" arg }

inputL :: Maybe String -> Options -> IO Options
inputL arg opt =
  return opt { optWaitFor = read $ fromMaybe "5" arg }

inputS :: Maybe String -> Options -> IO Options
inputS arg opt =
  return opt { optSeed = read $ fromMaybe "1" arg }

printHelp :: Options -> IO Options
printHelp _ = do
  prg <- getProgName
  hPutStrLn stderr (usageInfo prg options)
  exitWith ExitSuccess
