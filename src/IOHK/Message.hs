module IOHK.Message ( generateMessage ) where

import           System.Random (getStdRandom, randomR)

------------------------------------------------------------------------------
-- | Generates a random sample.
generateMessage :: IO Double
generateMessage =
  getStdRandom $ randomR (minPositiveFloat 0.0, 1.0)

------------------------------------------------------------------------------
-- | The smallest possible float > 0.0 (0,1].
minPositiveFloat :: RealFloat a => a -> a
minPositiveFloat a =
  encodeFloat 1 $ fst (floatRange a) - floatDigits a
