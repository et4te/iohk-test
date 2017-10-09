#!/bin/sh

send_for=3
wait_for=3
seed=1

while [ $# -gt 0 ]; do
    case "$1" in
        --send_for=*)
            send_for="${1#*=}"
            ;;
        --wait_for=*)
            wait_for="${1#*=}"
            ;;
        --seed=*)
            seed="${1#*=}"
            ;;
        *)
            printf "***************************\n"
            printf "* Error: Invalid argument.*\n"
            printf "***************************\n"
            exit 1
    esac
    shift
done

stack exec iohk-exe -- --host=localhost --port=4001 --seed=$seed &
stack exec iohk-exe -- --host=localhost --port=4002 --seed=$(($seed + 1)) &
stack exec iohk-exe -- --host=localhost --port=4003 --seed=$(($seed + 2)) &
stack exec iohk-exe -- --host=localhost --port=4004 --seed=$(($seed + 3)) &
stack exec iohk-exe -- --host=localhost --port=4005 --seed=$(($seed + 4)) &

# wait for the nodes to start
sleep 3

stack exec iohk-exe -- --node-type=master --host=localhost --port=4006 --send-for=$send_for --wait-for=$wait_for
