#!/bin/bash
set -o history -o histexpand
for i in {1..1000}
do
        vault write database"$i"/roles/benchmarking"$i" db_name=postgres"$i" creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" default_ttl="4h" max_ttl="8h"
        echo !:6-8
        sleep 0.1
done
