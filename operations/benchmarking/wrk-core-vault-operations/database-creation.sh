#!/bin/bash
set -o history -o histexpand
for i in {838..1000}
do
        vault write database"$i"/config/postgres"$i" plugin_name=postgresql-database-plugin connection_url="postgresql://{{username}}:{{password}}@$i.postgres.cloudruntime.eu:5432/perftest" allowed_roles="*" username="postgres" password="[]ts+vR8_es_+KXyN<"
        echo !:6-8
done
