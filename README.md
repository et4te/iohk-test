# iohk

## Build Instructions

This example uses stack and thus to build:

`$ stack build`

## Running the Executable

There are four parameters passed to the executable, each of which is optional where 
the default values are k=5, l=5, s=1, dfps=3 and drain=False:

`$ stack exec iohk-exe -- --send-for=K --wait-for=L --seed=S --dfps=F --drain`

* K is the initial period of process communication.
* L is the grace period deadline
* S is the initial random seed which determines how the rng process is seeded.
* F is the amount of messages per second requested to a peer during the initial period.
* The drain flag can be used to lessen the wait time of receiving messages at the cost
  of potentially losing messages. It is less reliable and is here included mainly to
  show a divergent path I took during the implementation.

A successful series of runs should (hopefully) produce deterministic results whilst
varying the seed should perturb the state of successive runs.

## Node Configuration

Node configurations can be configured by modifying src/Lib.hs, where nodes participating
in the network are assigned a NodeConfig as shown below. 

```haskell
data NodeConfig = NodeConfig Host Port
  deriving (Show)

nodeA = NodeConfig "localhost" "5001"
nodeB = NodeConfig "localhost" "5002"
nodeC = NodeConfig "localhost" "5003"
nodeD = NodeConfig "localhost" "5004"
nodeE = NodeConfig "localhost" "5005"
nodeF = NodeConfig "localhost" "5006"

nodes :: [NodeConfig]
nodes = [ nodeA, nodeB, nodeC ]
```

To add a node simply add to the node configuration list.

## Choices Made / Further Explanation

In addition to the problem statement I added two extra options to the program 
detailed below, both of which are optional. (data frames per second and drain)

### Usage of ForkIO rather than separate processes

Initially I started implementing the solution using SimpleLocalnet with separate 
processes. I started to write a bash script to spawn all the nodes but realised it
would be quicker / simpler to fork the processes using Control.Concurrent instead 
so this was the choice in the end. 

The problem statement describes providing one initial seed (rather than a seed per 
node) within the command line arguments. For this reason it made more sense to me 
to take a seed in one main executable and increment -> send to forked processes
rather than spawn three executables each with independent seeds at the command line. 

The limits are also specified to be global over the set of nodes so it seemed 
simpler to go this route.

Using forkIO however had some unforeseen consequences:
* The random number generation was no longer deterministic initially using setStdGen
due to the forked processes reusing the same StdGen. To fix this I send a seed in
the rng process and mkStdGen on every iteration.
* Waiting on deadline made more sense by using an MVar to capture the children 
exiting or reaching the deadline.

### Data Frames Per Second

Specifying data frames per second varies the amount of messages attempted to be
sent per second. This causes the mailboxes to grow and thus the wait time must be
increased in order for the nodes to converge within the deadline.

### Drain vs ReceiveN

The option 'drain' changes the process used during the grace period to a less reliable
variant which does not block in order to receive messages. This decreases the wait
period required but means some messages may get lost. 
