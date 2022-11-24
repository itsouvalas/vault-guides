#! /bin/bash
Help()
{
   echo "Runs a synthetic test against vault"
   echo
   echo "Expects VAULT_ADDR and VAULT_TOKEN environment variables"
   echo "Executed in the same directory with:"
   echo "   - read-secrets.lua"
   echo "   - write-random-secrets.lua"
   echo "   - read-random-db-secrets.lua"
   echo "   - write-delete-secrets.lua"
   echo "   - authenticate-and-revoke.lua"
   echo
   echo "Syntax: scriptTemplate [-t|c|d|n|h]"
   echo "options:"
   echo "     t     Threads."
   echo "     c     Connections."
   echo "     d     Duration in s/m/h i.e. 1s 2m 3h."
   echo "     h     prints this help."
   echo
   echo "i.e. ./synthetic.sh -t 4 -c 16 -d 5m -n 10000"
   echo
}

while getopts t:c:d:n:h flag
do
    case "${flag}" in
        t) threads=${OPTARG};;
        c) connections=${OPTARG};;
        d) duration=${OPTARG};;
        n) number=${OPTARG};;
        h) Help 
           exit;;
    esac
done

start=$(date "+%Y.%m.%d-%H.%M.%S")
logfile=synthetic-$start.log
printf "Synthetic test started at $(date) with the following options:\n\n" > $logfile
printf "Theads: $threads \nConnections: $connections\nDuration: $duration\nNumber of Secrets: $number\n" >> $logfile

# Read Secrets
wrk -t$threads -c$connections -d$duration -H "X-Vault-Token: $VAULT_TOKEN" -s read-secrets.lua $VAULT_ADDR -- $number false >> $logfile &
# Write Secrets
wrk -t$threads -c$connections -d$duration -H "X-Vault-Token: $VAULT_TOKEN" -s write-random-secrets.lua $VAULT_ADDR -- $number >> $logfile &
# Read Random db secrets
wrk -t$threads -c$connections -d$duration -H "X-Vault-Token: $VAULT_TOKEN" -s read-random-db-secrets.lua  $VAULT_ADDR -- false >> $logfile &
# Write delete secrets
wrk -t$threads -c$connections -d$duration -H "X-Vault-Token: $VAULT_TOKEN" -s write-delete-secrets.lua $VAULT_ADDR -- 1 $number >> $logfile &
# Authenticate and revoke
wrk -t$threads -c$connections -d$duration -H "X-Vault-Token: $VAULT_TOKEN" -s authenticate-and-revoke.lua $VAULT_ADDR >> $logfile &

echo "Results will be appended on $logfile once completed"