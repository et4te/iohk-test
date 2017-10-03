module Lib
    (
      NodeConfig(..)

    , nodes
    ) where

------------------------------------------------------------------------------

type Host = String
type Port = String

data NodeConfig = NodeConfig Host Port
  deriving (Show)

------------------------------------------------------------------------------
-- Node Configurations
------------------------------------------------------------------------------

nodeA = NodeConfig "localhost" "5001"
nodeB = NodeConfig "localhost" "5002"
nodeC = NodeConfig "localhost" "5003"
nodeD = NodeConfig "localhost" "5004"
nodeE = NodeConfig "localhost" "5005"
nodeF = NodeConfig "localhost" "5006"

nodes :: [NodeConfig]
nodes = [ nodeA, nodeB, nodeC, nodeD, nodeE, nodeF ]

------------------------------------------------------------------------------
