#!/bin/bash
set -o history -o histexpand
for i in {1..1000}
do
        vault write auth/userpass/users/loadtester"$i" password=benchmark policies=default
        sleep 0.1
done
