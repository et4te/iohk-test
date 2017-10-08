{-# LANGUAGE DeriveGeneric #-}

module IOHK.Clock
  (
    Timestep(..)

  , nextTimestep
  , diffTimestep
  , secondsToDiff
  ) where

import           GHC.Generics (Generic)
import           Data.Time.Clock
import           Data.Time.Clock.POSIX
import           Data.Binary

------------------------------------------------------------------------------

data Timestep = Timestep Double
  deriving (Generic, Show)

instance Binary Timestep

------------------------------------------------------------------------------
-- | Fetches the next timestep.
nextTimestep :: IO Timestep
nextTimestep = do
  t <- getCurrentTime
  return (Timestep (realToFrac $ utcTimeToPOSIXSeconds t))

------------------------------------------------------------------------------
-- | Takes the difference between two timesteps.
diffTimestep :: Timestep -> Timestep -> NominalDiffTime
diffTimestep (Timestep s1) (Timestep s2) =
  let
    t1 = posixSecondsToUTCTime $ realToFrac s1
    t2 = posixSecondsToUTCTime $ realToFrac s2
  in
    diffUTCTime t1 t2

------------------------------------------------------------------------------
-- | Returns seconds as diff time.
secondsToDiff :: Integer -> NominalDiffTime
secondsToDiff = realToFrac . secondsToDiffTime
