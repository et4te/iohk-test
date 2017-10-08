{-# LANGUAGE TemplateHaskell #-}
{-# LANGUAGE DeriveGeneric   #-}

module IOHKExercise where

import           GHC.Generics (Generic)
import           Control.Monad
import           Control.Distributed.Process
import           Control.Distributed.Process.Closure
import           IOHK.Clock
import           IOHK.Message
import           Data.Binary

------------------------------------------------------------------------------
-- Message Types
------------------------------------------------------------------------------

data Input =
    Start Integer Timestep Int
  | Compute [Output]
  | Receive Integer Double
  deriving (Show, Generic)

instance Binary Input

------------------------------------------------------------------------------

data Output = Message Integer Double
  deriving (Show, Generic)

instance Binary Output

------------------------------------------------------------------------------
-- | Receive N messages from the receive port.
receiveMessages :: ReceivePort Input -> Int -> Process [Output]
receiveMessages input n = receiveMessages' n []
  where
    receiveMessages' 0 acc = return acc
    receiveMessages' n acc = do
      (Receive i d) <- receiveChan input
      receiveMessages' (n - 1) (Message i d:acc)

------------------------------------------------------------------------------
-- | The slave message processor.
processMessage :: SendPort Output -> ReceivePort Input -> [Output] -> Input -> Process [Output]
processMessage output input _ (Start i _ npeers) = do
  -- Generate a message & send back to master
  d <- liftIO $ generateMessage
  let m = Message i d
  sendChan output m

  -- Wait to receive messages from other slaves
  ms <- receiveMessages input npeers

  return (m:ms)
processMessage _ _ _ (Compute messages) = do
  let score = foldl (+) 0 (map (\(Message _ d) -> (1.0 * d)) messages)
  liftIO $ putStrLn $ "< " ++ show (length messages) ++ ", " ++ show score ++ ">"
  return messages

------------------------------------------------------------------------------
-- | A slave receives input, processes messages and accumulates the result.
slave :: SendPort Output -> ReceivePort Input -> Process ()
slave output input = accumulate []
  where
    accumulate messages =
      receiveChan input >>= processMessage output input messages >>= accumulate

sdictTimestep :: SerializableDict Input
sdictTimestep = SerializableDict

remotable ['slave, 'sdictTimestep]

------------------------------------------------------------------------------
-- | Requests for the final computation to be made during the grace period.
waitUntilL :: Timestep -> [(Integer, SendPort Input)] -> Integer -> Integer -> [Output] -> Process Integer
waitUntilL uts slaves k l messages = do
  liftIO $ putStrLn "Entering grace period ..."
  liftIO nextTimestep >>= waitUntilL'
  where
    waitUntilL' ts
      | diffTimestep ts uts < secondsToDiff (k + l) = do
          forM_ slaves $ \(_, them) -> do
            sendChan them (Compute messages)
          return 0
      | otherwise = do
          return 0

------------------------------------------------------------------------------
-- | Distributes messages across the slaves.
distribute _ [] =
  return ()
distribute slaves (Message i d:messages) = do
  let others = filter (\(x, _) -> x /= i) slaves
  forM_ others $ \(_, them) -> do
    sendChan them (Receive i d)
  distribute slaves messages

------------------------------------------------------------------------------
-- | Requests messages from slaves and distributes them as a work queue.
sendUntilK :: Timestep -> [(Integer, SendPort Input)] -> ReceivePort Output -> Integer -> Integer -> Process Integer
sendUntilK uts slaves rport k l = do
  liftIO $ putStrLn "Entering communication period ..."
  liftIO nextTimestep >>= sendUntilK' []
  where
    sendUntilK' acc ts
      | diffTimestep ts uts < secondsToDiff k = do
          forM_ slaves $ \(i, them) -> do
            sendChan them (Start i ts (length slaves - 1))

          messages <- forM slaves $ \_ -> do
            m <- receiveChan rport
            return m

          distribute slaves messages

          liftIO nextTimestep >>= sendUntilK' (messages ++ acc)
      | otherwise = waitUntilL uts slaves k l acc

------------------------------------------------------------------------------
-- | Creates slave channels and starts the communication period.
master :: Integer -> Integer -> [NodeId] -> Process Integer
master k l slaves = do
  -- Initial timestamp
  uts <- liftIO $ nextTimestep

  -- master send / receive ports
  (sport, rport) <- newChan

  slaveSendPorts <- forM slaves $ \nid -> do
    spawnChannel $(mkStatic 'sdictTimestep) nid ($(mkClosure 'slave) sport)

  -- Until k is reached send nextTimestep and wait for slaves
  sendUntilK uts (zip [0..] slaveSendPorts) rport k l
