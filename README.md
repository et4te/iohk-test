# iohk

## Build Instructions

This example uses stack and thus to build:

`$ stack build`

## Running the Executable

To run the example you can either use the start script:
```bash
$ ./start.sh --send\_for=3 --wait\_for=3 --seed=1
```

Or run N + 1 nodes where the last node is a master node:
```bash
stack exec iohk-exe -- --host=localhost --port=4001 --seed=1 &
stack exec iohk-exe -- --host=localhost --port=4002 --seed=2 &
stack exec iohk-exe -- --host=localhost --port=4003 --seed=3 &
stack exec iohk-exe -- --node-type=master --host=localhost --port=4006 --send-for=3 --wait-for=3
```

A successful run should produce the same result on each node.

## Node Configuration

Nodes can be configured by modifying the start.sh script:

## Choices Made / Further Explanation

The example uses SimpleLocalnet with typed channels. 
