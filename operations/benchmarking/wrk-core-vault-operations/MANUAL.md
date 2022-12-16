# Vault Consul Performance Testing

## Introduction

There are several reasons that someone might want to do performance testing against a mission critical service they rely on. Identify issues that might affect their service overall, focus on specific processes that drain resources, test changes that supposedly alleviate a specific issue or generally test the performance of a given upgrade path to name a few. In the following lines we will go through the performance testing of [terraform deployed environment](https://github.com/hashicorp/vault-guides/tree/master/operations/benchmarking/terraform-aws-vault-benchmark) which consists of:
* Vault
* Consul
* Telegraf for collecting telemetry information
* InfluxDB that stores and feeds telemetry to Grafana
* Envoy for monitoring Vault ingress data
* Grafana for visualization
* Bastion we can use to interact with our deployment
* Benchmark instance we will do our performance testing from

The terraform deployment process goes beyond the scope of this document, you can read more about it on [this](https://medium.com/hashicorp-engineering/hashicorp-vault-performance-benchmark-13d0ea7b703f) blogpost

## Test Subject

### Vault Secrets Engines

Vault does come with a plethora of options when it comes to the Secrets Engines to be used. There is no size fits all which would group the engines widely used, yet in our tests bellow we will be focusing on:
* [KV Secrets Engine](https://developer.hashicorp.com/vault/docs/secrets/kv/kv-v1)
* [PostgreSQL Database Secrets Engine](https://developer.hashicorp.com/vault/docs/secrets/databases/postgresql)

### Infrastructure changes

Even though we might not be facing an issue in this very moment, fine-tuning the resources that our services rely on could improve our overall user experience. We will be making changes to our infrastructure to underline the effect, if any, our changes have to our service pinpointing in that way how we can use the testing results in making informed, justifiable decisions.

## Testing Method

### WRK

[wrk](https://github.com/wg/wrk) has been around for a while and can be seen referenced in most benchmarking discussions around the internet. Although it receives very little updates, given it relies on simple HTTP requests we can successfully produce the traffic and the collect the results we are going for.

The options we are going to be using are (`wrk --help` for more):

`-t, --threads     <N>  Number of threads to use`

`-c, --connections <N>  Connections to keep open`

`-d, --duration    <T>  Duration of test`

`-H, --header      <H>  Add header to request`

### Lua Scripting Language

When it comes down to scripting there are several options. We've worked with bash scripting in the past to enable and configure database engines, create roles and a use a random secret reader. Hashicorp team and its contributors has taken it a step further with a useful information returned as part of the benchmarking process using a number of [lua scripts](https://github.com/hashicorp/vault-guides/tree/master/operations/benchmarking/wrk-core-vault-operations). Lets have a look at the read-secrets script:

* `thread`

```lua
json = require "json"

local counter = 1
local threads = {}

function setup(thread)
   thread:set("id", counter)
   table.insert(threads, thread)
   counter = counter + 1
end
```

In the beginning there is a counter set to 1 which assists in setting up a thread table. This will be fed by the number of threads defined on the `wrk` tool

* `init`

```lua
function init(args)
   if args[1] == nil then
      num_secrets = 1000
   else
      num_secrets = tonumber(args[1])
   end
   print("Number of secrets is: " .. num_secrets)
   if args[2] == nil then
      print_secrets = "false"
   else
      print_secrets = args[2]
   end
   requests  = 0
   reads = 0
   responses = 0
   method = "GET"
   body = ''
   -- give each thread different random seed
   math.randomseed(os.time() + id*1000)
   local msg = "thread %d created with print_secrets set to %s"
   print(msg:format(id, print_secrets))
end
```

There is a default value of secrets to be read set to `1000`, that may be altered by passing an argument. It also allows for a second argument to be passed resulting in printing the secrets read. If no argument is passed it defaults to `false`. I nullifies `requests`, `reads` and `responses` while it also defines the `GET` method for the request. Finally, it randomizes each thread and sets a message

* `request`

```lua
function request()
   reads = reads + 1
   -- randomize path to secret
   path = "/v1/secret/read-test/secret-" .. math.random(num_secrets)
   requests = requests + 1
   return wrk.format(method, path, nil, body)
end
```
A read counter which is increased by one is set, followed by a randomized path fed back to `wrk`.

* `response`

```lua
function response(status, headers, body)
   responses = responses + 1
   if print_secrets == "true" then
      body_object = json.decode(body)
      for k,v in pairs(body_object) do 
         if k == "data" then
            print("Secret path: " .. path)
            for k1,v1 in pairs(v) do
               local msg = "read secrets: %s : %s"
               print(msg:format(k1, v1)) 
            end
         end
      end
   end 
end
```

In this part of the script the response is captured and passed on tot the `done` function bellow

* `done`

```lua
function done(summary, latency, requests)
   for index, thread in ipairs(threads) do
      local id        = thread:get("id")
      local requests  = thread:get("requests")
      local reads     = thread:get("reads")
      local responses = thread:get("responses")
      local msg = "thread %d made %d requests including %d reads and got %d responses"
      print(msg:format(id, requests, reads, responses))
   end
end
```

This is where everything is put together and all the information of the request is fed back to us as a summary. We will go trough the outputs on Testing bellow

# Testing

## Prerequisites

The machine where the tests should be run from should have network access to the vault instance running:

* The repository with the testing scripts:

`git clone https://github.com/hashicorp/vault-guides.git`

`cd vault-guides/operations/benchmarking/wrk-core-vault-operations`

* Access to vault through environment variables

`export VAULT_ADDR=https://VAULT-ADDRESS-OR-IP:8200`

`export VAULT_TOKEN=VAULT_ROOT_TOKEN`


## Baseline

This is the ground zero for our performance testing. It is where we currently find ourselves and what we are our going to be comparing against when changes are introduced.

### KV Secrets Engine

In order to test the kv secrets engine we first need to enable it:

`vault secrets enable -path secret -version 1 kv`

* `write-secrets`

Before we can test reading secrets lwe should go ahead and write them first. In contrary to the other test we will be using a single thread, connection and ample duration given that this is the means to the `read-secrets` later:

`wrk -t1 -c1 -d10m -H "X-Vault-Token: $VAULT_TOKEN" -s write-secrets.lua $VAULT_ADDR -- 10000`

```
Number of secrets is: 10000
thread 1 created
Running 10m test @ https://vault.service.consul:8200
  1 threads and 1 connections
```

From our grafana dashboards, we can see that on vault's side:

* there's minimal cpu consumption (close to 9%)
* requests are handled within 10 ms
* there's a network I/O spike close to 2 MB
* little disk I/O (expected due to consul backend)
* an increased number of GC pauses though without a spike in their duration

![vault](assets/vault-write.png)

on consul's side:

* cpu closing to 17%
* Disk I/O closing to 100MB given it takes all the writes
* Network I/O spiking to 3 MB
* A spike in the RPC requests on two of the nodes up to 1.7k
* A spike to the raft.apply.count adding to the 10 secrets created (5.4k, 4.6k)
* while the raft.commit.time remaining unaffected
* kvs.apply.count increase ~ 850
* while the kvs.apply.time remains roughly the same ~ 5ms
* and an increase on the RPC requests by client from the vault leader

![cosnul](assets/consul-write.png)

* `read-secrets`

With secrets available for us to request lets do our first true benchmark. We are going to be using:

> 4 threads

> 16 connections

> 1 minute duration

> 10000 secrets

> no print

> export to vault-read-t4-c16-d1m.log

`wrk -t4 -c16 -d1m -H "X-Vault-Token: $VAULT_TOKEN" -s read-secrets.lua $VAULT_ADDR -- 10000 false > vault-read-t4-c16-d1m.log &`

This time around we notice the following on vault's side:

* significantly more cpu usage nearing 90%
* Network I/O spiking at 75MB
* much less request handle time ~ 0,750ms
* an considerably more GC pause time reaching 5ms

![vault-read](assets/vault-read.png)

* whereas a single GC time spike for consul when the test concluded ~ 15ms

![consul-read](assets/consul-read.png)

We also have the first output produced by the combination of `wrk` and the script:

`cat vault-read-t4-c16-d1m.log`

```yml
Number of secrets is: 10000
thread 1 created with print_secrets set to false
Number of secrets is: 10000
thread 2 created with print_secrets set to false
Number of secrets is: 10000
thread 3 created with print_secrets set to false
Number of secrets is: 10000
thread 4 created with print_secrets set to false
Running 1m test @ https://vault.service.consul:8200
  4 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency     6.25ms    5.65ms  70.20ms   88.18%
    Req/Sec   743.86    131.38     1.16k    66.50%
  177763 requests in 1.00m, 73.56MB read
Requests/sec:   2960.36
Transfer/sec:      1.22MB
thread 1 made 44186 requests including 44186 reads and got 44182 responses
thread 2 made 44628 requests including 44628 reads and got 44624 responses
thread 3 made 44288 requests including 44288 reads and got 44284 responses
thread 4 made 44677 requests including 44677 reads and got 44673 responses
```

Here we see our first hard evidence on the performance of our cluster:

* An average latency of 6.25ms with max being 70.20ms
* An average Request/sec od 743.86 with max being 1.16k
* 177763 total requests in 1 minute
* a total 2960.36 requests/sec
* responses for all our requests


Doing a rough comparison between the read and write test we can see a difference already as far as CPU and DISK I/O goes. We can use those differences to focus our introduced changes to the infrastructure so that we handle reads better by lets say increasing the CPU power or writes by increasing the I/O of the attached disks. 

* `delete-secrets`

By now we have created already a number of secrets. How does our cluster and the underlying infrastructure handle deletions. Although we most likely wont do this in a real deployment lets disable kv secret path altogether:

`vault secrets disable secret`

We see that:

* consul delete is handled at approximately 8ms on vaults side
* and cosnul's disk I/O is the one taking the hit

![vault-delete](assets/vault-delete.png)

![consul-delete](assets/consul-delete.png)


* `write-random-secrets`

So far we've written read and deleted secrets, all against a single path, which is essentially a single secret. What happens if we store the secrets in a dynamically created path:

> 4 threads

> 16 connections

> 1 minute duration

> 10000 secrets

> no print

> export to vault-random-write-t4-c16-d1m.log

`wrk -t4 -c16 -d1m -H "X-Vault-Token: $VAULT_TOKEN" -s write-random-secrets.lua $VAULT_ADDR -- 10000 > vault-random-write-t4-c16-d1m.log &`

```yml
Number of secrets is: 10000
thread 1 created
Number of secrets is: 10000
thread 2 created
Number of secrets is: 10000
thread 3 created
Number of secrets is: 10000
thread 4 created
Running 1m test @ https://vault.service.consul:8200
  4 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency    20.89ms    7.89ms 106.50ms   80.89%
    Req/Sec   194.25     38.45   290.00     73.08%
  46485 requests in 1.00m, 5.36MB read
Requests/sec:    773.75
Transfer/sec:     91.43KB
thread 1 made 11600 requests including 11600 writes and got 11595 responses
thread 2 made 11644 requests including 11644 writes and got 11640 responses
thread 3 made 11628 requests including 11628 writes and got 11624 responses
thread 4 made 11630 requests including 11630 writes and got 11626 responses
```
* An average latency of 20.89ms with max being 106.50ms
* An average Request/sec od 194.25 with max being 290
* 177763 total requests in 1 minute
* a total 773.75 requests/sec
* responses for all our requests

![vault-write-random](assets/vault-write-random.png)
![consul-write-random](assets/consul-write-random.png)

On vault we see:

* cpu usage hovering over 50%
* Network I/O over 10MB
* Request handle time under 25ms

and on consul:

* cpu usage under 60% with all nodes doing their part
* Considerable Disk I/O around 400MB
* Network I/O spiking at 15MB for the master
* RPC Requests hovering around 10k for the duration of the test
* a little over 40k Raft transactions
* GC time spiking at 4ms
* KV rites under 8k and around 10ms
* and the total of RPC requests done from the same client



* `read-db-secrets`

**single role**

Just like in the KV engine we ought to enable the database engine

`vault secrets enable database`

With the database enabled, we ought to configure the engine base on the details pertaining to our database:

```yml
database:       postgres
plugin_name:    postgresql-database-plugin
allowed_roles:  "*"
database url:   vault-perf-test.cdtsqchlcyec.us-east-1.rds.amazonaws.com
database port:  5432
database name:  "perftest"
username:  "postgres"
password:  "[]ts+vR8_es_+KXyN<"
```

using the details above with the `vault write` on the `database/config` path specific to postgres

```sh
vault write database/config/postgres \
plugin_name=postgresql-database-plugin allowed_roles="*" \
connection_url="postgresql://{{username}}:{{password}}@vault-perf-test.cdtsqchlcyec.us-east-1.rds.amazonaws.com:5432/perftest" \
username="postgres" password="[]ts+vR8_es_+KXyN<"
```

With the engine enabled and configured, our last step is to create the database role for those secrets. With the following details:

```yml
role:                   benchmarking
db_name:                postgres
creation_statements:    "CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
                        GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
                        default_ttl="24h" max_ttl="48h"
```

using `vault write` on the `database/roles` for the `benchmarking` role:

```
vault write database/roles/benchmarking \
db_name=postgres \
creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; \
GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" \
default_ttl="24h" max_ttl="48h"
```

Now we are ready to test reading secrets using `read-db-secrets.lua` which creates the following request:

```lua
function request()
   reads = reads + 1
   -- randomize path to secret
   path = "/v1/database/creds/benchmarking" 
   requests = requests + 1
   return wrk.format(method, path, nil, body)
end
```

To maintain a comparable baseline, we will use the same options:

> 4 threads

> 16 connections

> 1 minute duration

> 10000 secrets

> no print

> export to vault-read-db-secrets-t4-c16-d1m.log

`wrk -t4 -c16 -d1m -H "X-Vault-Token: $VAULT_TOKEN" -s read-db-secrets.lua $VAULT_ADDR -- 10000 false > vault-read-db-secrets-t4-c16-d1m.log &`

```yml
thread 1 created with print_secrets set to false
thread 2 created with print_secrets set to false
thread 3 created with print_secrets set to false
thread 4 created with print_secrets set to false
Running 1m test @ https://vault.service.consul:8200
  4 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   179.47ms   25.32ms 454.46ms   88.78%
    Req/Sec    22.48      8.08    50.00     77.16%
  5344 requests in 1.00m, 2.26MB read
Requests/sec:     88.92
Transfer/sec:     38.47KB
thread 1 made 1341 requests including 1341 reads and got 1336 responses
thread 2 made 1338 requests including 1338 reads and got 1334 responses
thread 3 made 1341 requests including 1341 reads and got 1337 responses
thread 4 made 1341 requests including 1341 reads and got 1337 responses
```

Comparing between secrets engines we can clearly see a difference in the number of requests handled for tht same amount of time, connections and threads:

* An average latency of 179.47ms with max being 454.46ms
* An average Request/sec od 22.48 with max being 50
* 5344 total requests in 1 minute
* a total 88.92 requests/sec
* responses for all our requests

A rough comparison between kv and database engines would be that the former can produce 30 times as much secrets compared to the latter. There are several reasons for it:

* An additional node/hop is added to each request
* Network latency is introduced for each request towards the database
* Network latency is introduced for each response from the database
* An extra step to store the credentials on consul

Visually:

![vault-read-db](assets/vault-read-db.png)

![consul-read-db](assets/consul-read-db.png)


On the vault side of things we can notice that:

* There is far less cpu usage spiking at and around 12%
* Far less network I/O ~ 5MB
* Significantly larger time to handle each request

and on Consul:

* There is more cpu usage spiking at and around 25%
* More network I/O > 5MB
* 3 times as much Disk I/O spiking at 300MB
* approximately the same number of RPC requests
* Higher number of Raft transactions
* Twice as many kv apply counts at ~1.8k
* and an increase in the apply time itself to 7.5ms

It is important to note that the database secrets engine is by definition a synthetic test. It not only reads the secret, it also writes the secret produced from the database it is connecting to.

**multiple-roles**

Our last test went through a single database, configuration and role. This is rarely going to be the case in production environments. In the following lines we will be creating:

* 1k databases
* 1k configurations
* 1k roles

--1k databases

Using the following script we will enable 1k databases

```
#!/bin/bash
set -o history -o histexpand
for i in {1..1000}
do
        vault secrets enable -path=database"$i" database
        sleep 0.1
done
```

--1k configurations

This script will create a configuration par for each of the databases created

```
#!/bin/bash
set -o history -o histexpand
for i in {1..1000}
do
        vault write database"$i"/config/postgres"$i" plugin_name=postgresql-database-plugin connection_url="postgresql://{{username}}:{{password}}@$i.postgres.cloudruntime.eu:5432/perftest" allowed_roles="*" username="postgres" password="[]ts+vR8_es_+KXyN<"
        echo !:6-8
done
```

--1k roles

Finally, 1k of roles will be created for each of the configured databases:

```
#!/bin/bash
set -o history -o histexpand
for i in {1..1000}
do
        vault write database"$i"/roles/benchmarking"$i" db_name=postgres"$i" creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}';GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";" default_ttl="4h" max_ttl="8h"
        echo !:6-8
        sleep 0.1
done
```

For the test request itself, we are extending the previous script on a dynamic path which ranges from 1-1000 making sure that each request uses the correct pair between database number and the role number.

```lua
function request()
   reads = reads + 1
   -- randomize path to secret
   randomrole = math.random(num_roles)
   path = "/v1/database" .. randomrole .. "/creds/benchmarking" .. randomrole
   requests = requests + 1
   return wrk.format(method, path, nil, body)
end
```

Again, to maintain a comparable baseline, we will use the same options:

> 4 threads

> 16 connections

> 1 minute duration

> 1000 secrets

> no print

> export to vault-read-random-db-secrets-t4-c16-d1m.log


`wrk -t4 -c16 -d1m -H "X-Vault-Token: $VAULT_TOKEN" -s read-random-db-secrets.lua $VAULT_ADDR -- false > vault-read-random-db-secrets-t4-c16-d1m.log &`

```
Number of secrets is: 1000
thread 1 created with print_secrets set to false
Number of secrets is: 1000
thread 2 created with print_secrets set to false
Number of secrets is: 1000
thread 3 created with print_secrets set to false
Number of secrets is: 1000
thread 4 created with print_secrets set to false
Running 1m test @ https://vault.service.consul:8200
  4 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   124.43ms  133.03ms   1.14s    83.09%
    Req/Sec    49.53     27.48   121.00     49.67%
  10815 requests in 1.00m, 4.63MB read
Requests/sec:    180.02
Transfer/sec:     78.90KB
thread 1 made 2660 requests including 2660 reads and got 2655 responses
thread 2 made 2750 requests including 2750 reads and got 2746 responses
thread 3 made 2696 requests including 2696 reads and got 2692 responses
thread 4 made 2726 requests including 2726 reads and got 2722 responses
```

This time around, we can see the following results:

* An average latency of 124.43ms with max being 1.14s
* An average Request/sec of 49.53 with max being 121
* 10815 total requests in 1 minute
* a total 180.02 requests/sec
* responses for all our requests

Compared to the single database/role we can see that providing multiple databases, configurations and roles has allowed vault to make twice as many requests even though the database itself remains the same as before.

Visually, we can confirm the findings above:

![vault-read-random-db](assets/vault-read-random-db.png)
![consul-read-random-db](assets/consul-read-random-db.png)

on vault side of things:

* considerably more cpu spiking at 75%
* much higher network I/O reaching 100MB
* uneven spread of Request Handle Time spiking at 300ms

whereas on consul side of things:

* higher cpu usage spiking under 50%
* higher disk I/O over and around 300MB
* 4 times as much as Network I/O at 20MB
* 4 times as many RPC requests
* twice as many Raft Transactions
* and unevenly distributes Requests by client

* authenticate

All tests were run from a system that was already authenticated against vault. In production environments we either expect new authentications to be done against vault or older ones to be revoked. Let's see how vault handles that for us:

First lets enable userpass and pass some credentials:

`vault auth enable -token-type="batch" userpass`
`vault write auth/userpass/users/loadtester password=benchmark policies=default`

Once again, to maintain a comparable baseline, we will use the same options:

> 4 threads

> 16 connections

> 1 minute duration

> no print

> export to vault-authenticate.log

`wrk -t4 -c16 -d1m -H "X-Vault-Token: $VAULT_TOKEN" -s authenticate.lua $VAULT_ADDR > vault-authenticate.log &`

```yml
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   865.08ms   85.05ms   1.32s    68.97%
    Req/Sec     6.23      4.34    20.00     89.70%
  1102 requests in 1.00m, 639.25KB read
Requests/sec:     18.34
Transfer/sec:     10.64KB
thread 1 made 283 authentications and 0 revocations and got 278 responses
thread 2 made 277 authentications and 0 revocations and got 273 responses
thread 3 made 280 authentications and 0 revocations and got 276 responses
thread 4 made 279 authentications and 0 revocations and got 275 responses
[5]+  Done                    wrk -t4 -c16 -d1m -H "X-Vault-Token: $VAULT_TOKEN" -s authenticate.lua $VAULT_ADDR > vault-authenticate.log
```

To our surprise (it definitely was for me at least), this is the lowest number of requests handled in the same duration as all of our tests:

* An average latency of 865.08ms with max being 1.32s
* An average Request/sec of 6.23 with max being 20.00
* 1102 total requests in 1 minute
* a total 18.34 requests/sec
* responses for all our requests

An we can clearly see why that happens:

![vault-authenticate](assets/vault-authenticate.png)
![consul-authenticate](assets/consul-authenticate.png)

The authentication takes a great toll on vault:

* cpu spiking at 100%
* low network I/O close to 1MB
* Consul GETs around 5ms
* consul PUTs on the other hand up to 100ms

And a differently painted picture for consul altogether:

* little CPU consumption
* average Disk I/O under 100MB
* low network I/O under 2MB
* Under 750 RPC requests

We've seen before that when providing a different database, config and role for our databases, vault was able to go through more requests in exactly the same time. Lets have a look on that scenario:

* vault-authenticate-random

To begin with lets create 1k users:

```bash
#!/bin/bash
set -o history -o histexpand
for i in {1..1000}
do
        vault write auth/userpass/users/loadtester"$i" password=benchmark policies=default
        sleep 0.1
done
```

> 4 threads

> 16 connections

> 1 minute duration

> no print

> export to vault-authenticate-random.log

`wrk -t4 -c16 -d1m -H "X-Vault-Token: $VAULT_TOKEN" -s authenticate-random.lua $VAULT_ADDR > vault-authenticate-random.log &`

```yml
thread 1 created
thread 2 created
thread 3 created
thread 4 created
Running 1m test @ https://vault.service.consul:8200
  4 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   867.12ms  112.72ms   1.28s    71.40%
    Req/Sec     5.90      3.92    20.00     65.37%
  1098 requests in 1.00m, 640.00KB read
Requests/sec:     18.27
Transfer/sec:     10.65KB
thread 1 made 279 authentications and 0 revocations and got 274 responses
thread 2 made 279 authentications and 0 revocations and got 275 responses
thread 3 made 279 authentications and 0 revocations and got 275 responses
thread 4 made 278 authentications and 0 revocations and got 274 responses
```

With close to identical results we can rest assured that the unique number of users we authenticate against has no effect when compared to a single user.

* delete-secrets (continued)

Given that we wouldn't expect to disable an engine each time we want to run a test, and the fact that the `write-random` has already provided us with a number of secrets to delete, lets use that path to test deletion:

First lets confirm the path our secrets rely in:

`vault list secret`

```
Keys
----
read-test/
write-delete-test/
write-random-test-1
write-random-test-10
write-random-test-100
write-random-test-1000
write-random-test-10000
write-random-test-1001
write-random-test-1002
write-random-test-1003
```

Depending on your deployment's speed, you might want to increase the number of secrets available for deletion. In our case, we saw that there were close to 50k requests going through so we increased the number of secrets rerunning the command to 100k and a duration of 10 minutes, making sure that the results would be tied to secrets being deleted and not just the 1 minute duration:

`wrk -t1 -c32 -d10m -H "X-Vault-Token: $VAULT_TOKEN" -s write-random-secrets.lua $VAULT_ADDR -- 100000 > vault-random-write-t4-c16-d1m.log &`


Given the way each path is calculated this time around we changes the number of threads to `1` and the number of connections to `32`

> 1 threads

> 32 connections

> 1 minute duration

> path `secret`

> secret name `write-random-test-`

> number of secrets `100000`

> no print

> export to vault-delete-random-secrets-t4-c16-d1m.log

`wrk -t1 -c32 -d1m -H "X-Vault-Token: $VAULT_TOKEN" -s delete-secrets.lua $VAULT_ADDR -- secret write-random-test- 100000 > vault-delete-random-secrets.log &`

```yml
thread 1 created
thread 2 created
thread 3 created
thread 4 created
Running 1m test @ https://vault.service.consul:8200
  4 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency    19.72ms    7.86ms 133.72ms   84.30%
    Req/Sec   206.72     43.40   313.00     71.14%
  49426 requests in 1.00m, 5.70MB read
Requests/sec:    822.83
Transfer/sec:     97.23KB
thread 1 made 12372 requests including  12371 deletes and got 12367 responses
thread 2 made 12362 requests including  12361 deletes and got 12358 responses
thread 3 made 12358 requests including  12357 deletes and got 12354 responses
thread 4 made 12351 requests including  12350 deletes and got 12347 responses
```

* An average latency of 19.72ms with max being 133.72
* An average Request/sec of 206.72 with max being 313
* 49426 total requests in 1 minute
* a total 822.83 requests/sec
* responses for all our requests


# Synthetic testing

So far we've either written, read or deleted secrets, and all done against a specific engine. Unfortunately for our results, or fortunately for us and the workload that we expect vault to handle, this is never the case for any type of workload. That said let's see our options below as far as synthetic testing goes:

* write-delete

The write delete test is slightly more intricate than the others, given that for each write there is a matching delete. Given the even numbers of connections and threads we used so far, we can continue the test using exactly the same t4-c16 as before:

> 4 threads

> 16 connections

> 1 minute duration

> 1000 secrets

> no print

> export to vault-write-delete-secrets.log

`wrk -t4 -c16 -d1m -H "X-Vault-Token: $VAULT_TOKEN" -s write-delete-secrets.lua $VAULT_ADDR -- 1 10000 > vault-write-delete-secrets.log &`

```yml
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency    26.36ms   13.33ms 176.59ms   84.17%
    Req/Sec   156.82     33.65   222.00     69.85%
  37526 requests in 1.00m, 4.33MB read
Requests/sec:    624.59
Transfer/sec:     73.80KB
thread 1 made 9404 requests including 4701 writes and 4703 deletes and got 9399 responses
thread 2 made 9388 requests including 4693 writes and 4695 deletes and got 9384 responses
thread 3 made 9370 requests including 4684 writes and 4686 deletes and got 9366 responses
thread 4 made 9381 requests including 4689 writes and 4692 deletes and got 9377 responses
```

* An average latency of 26.36ms with max being 176.59ms
* An average Request/sec of 156.82 with max being 222
* 37526 total requests in 1 minute
* a total 624.59 requests/sec
* responses for all our requests

We can quickly see that there is an approximately 20% drop on the number of requests handled in total compared to the random-writes earlier, whereas only half of them are writes. 

The same story is to be told by our graphs:

![vault-write-delete](assets/vault-write-delete.png)
![consul-write-delete](assets/consul-write-delete.png)

On vault we see:

* cpu spiking close to 50%
* network I/O a little under 10MB
* request handle time hovering a little over 20ms
* consul PUTs and DELETEs close to 20ms

On consul:

* under 50% cpu usage
* Disk I/O under 500MB
* Network I/O under 15MB
* RPC Requests under 10k
* Raft apply transactions equal to the total number of requests ~ > 30k
* Raft transaction time spiking a little over 15ms

To sum up our first synthetic test, as expected, when we ask to do more at the same time, there is so much that can be done. We also see that our current infrastructure gracefully handles the combination of those requests.

* authenticate-revoke

We saw already that authentication is vault's Achilles' heel. What happens if we add revocation in the mix:

> 4 threads

> 16 connections

> 1 minute duration

> no print

> export to vault-authenticate.log

`wrk -t4 -c16 -d1m -H "X-Vault-Token: $VAULT_TOKEN" -s authenticate-and-revoke.lua $VAULT_ADDR > vault-authenticate-and-revoke.log &`

```yml
thread 1 created
thread 2 created
thread 3 created
thread 4 created
Running 1m test @ https://vault.service.consul:8200
  4 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   542.71ms  223.58ms   1.64s    64.58%
    Req/Sec     8.49      4.30    30.00     81.63%
  1764 requests in 1.00m, 614.00KB read
Requests/sec:     29.36
Transfer/sec:     10.22KB
thread 1 made 222 authentications and 225 revocations and got 442 responses
thread 2 made 222 authentications and 224 revocations and got 442 responses
thread 3 made 221 authentications and 223 revocations and got 440 responses
thread 4 made 221 authentications and 223 revocations and got 440 responses
[1]+  Done                    wrk -t4 -c16 -d1m -H "X-Vault-Token: $VAULT_TOKEN" -s authenticate-and-revoke.lua $VAULT_ADDR > vault-authenticate-and-revoke.log
```

We can see that although they are about 20% less authentications compared to when authentication was run on its own, vault managed to squeeze in an equal amount of revocations:

* An average latency of 542.71ms with max being 1.64s
* An average Request/sec of 8.49 with max being 30.00
* 1764 total requests in 1 minute
* a total 29.36 requests/sec
* responses for all our requests

Visually:

![vault-authenticate-revoke](assets/vault-authenticate-revoke.png)
![consul-authenticate-revoke](assets/consul-authenticate-revoke.png)

Vault:

* take the same strain spiking at 100% cpu usage
* we notice some disk I/O
* twice as much network I/O at 4MB
* request handle time under 750ms
* Consul GETs close to 15ms
* Consul PUTs LISTs and DELETEs hovering around 40ms

Consul:

* a bit more CPU usage, still unnoticeable
* twice as much Disk I/O at around 150MB
* considerably more Network I/O reaching close to 10MB
* Much more RPC requests at around 4k
* twice as many Raft transaction above 5k
* twice as many KV apply counts

Lets bind everything we've done do far together:

* read-write-delete auth-revoke kv/db

Now that we've gone through most of the available tests let's go ahead and create a simple single bash script that binds them together:

```bash
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
```

> 4 threads

> 16 connections

> 1 minute duration

> 10000 secrets

> automatically exported to sythetic-$date.log

`./synthetic.sh -t 4 -c 16 -d 1m -n 10000`

`cat synthetic-2022.11.24-13.20.36.log`

```bash
Synthetic test started at Thu Nov 24 13:20:36 UTC 2022 with the following options:

Theads: 4 
Connections: 16
Duration: 1m
Number of Secrets: 10000

#################################################################################
###########################  Read Random DB Secrets  ############################
#################################################################################

Number of secrets is: 1000
thread 1 created with print_secrets set to false
Number of secrets is: 1000
thread 2 created with print_secrets set to false
Number of secrets is: 1000
thread 3 created with print_secrets set to false
Number of secrets is: 1000
thread 4 created with print_secrets set to false
Running 1m test @ https://vault.service.consul:8200
  4 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   186.96ms   86.33ms 888.59ms   89.59%
    Req/Sec    23.51     10.54    50.00     59.67%
  5268 requests in 1.00m, 2.25MB read
Requests/sec:     87.73
Transfer/sec:     38.45KB
thread 1 made 1328 requests including 1328 reads and got 1323 responses
thread 2 made 1310 requests including 1310 reads and got 1306 responses
thread 3 made 1323 requests including 1323 reads and got 1319 responses
thread 4 made 1324 requests including 1324 reads and got 1320 responses

#################################################################################
############################  Write Delete Secrets  #############################
#################################################################################

Number of secrets is: 10000
thread 1 created
Number of secrets is: 10000
thread 2 created
Number of secrets is: 10000
thread 3 created
Number of secrets is: 10000
thread 4 created
Running 1m test @ https://vault.service.consul:8200
  4 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency    95.22ms   55.16ms 762.72ms   88.71%
    Req/Sec    44.91     14.80    80.00     53.30%
  10595 requests in 1.00m, 1.22MB read
Requests/sec:    176.32
Transfer/sec:     20.84KB
thread 1 made 2645 requests including 1321 writes and 1324 deletes and got 2640 responses
thread 2 made 2657 requests including 1327 writes and 1330 deletes and got 2653 responses
thread 3 made 2633 requests including 1315 writes and 1318 deletes and got 2629 responses
thread 4 made 2677 requests including 1337 writes and 1340 deletes and got 2673 responses

#################################################################################
##############################  Auth Revoke Users  ##############################
#################################################################################

thread 1 created
thread 2 created
thread 3 created
thread 4 created
Running 1m test @ https://vault.service.consul:8200
  4 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency    61.08ms   50.40ms 674.04ms   86.58%
    Req/Sec    72.97     26.00   190.00     70.78%
  17261 requests in 1.00m, 2.53MB read
  Non-2xx or 3xx responses: 8630
Requests/sec:    287.27
Transfer/sec:     43.06KB
thread 1 made 2162 authentications and 2164 revocations and got 2161 responses
thread 2 made 2157 authentications and 2159 revocations and got 2156 responses
thread 3 made 2158 authentications and 2161 revocations and got 2158 responses
thread 4 made 2156 authentications and 2159 revocations and got 2156 responses

#################################################################################
############################  Write Random Secrets  #############################
#################################################################################

Number of secrets is: 10000
thread 1 created
Number of secrets is: 10000
thread 2 created
Number of secrets is: 10000
thread 3 created
Number of secrets is: 10000
thread 4 created
Running 1m test @ https://vault.service.consul:8200
  4 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency    82.05ms   45.56ms 651.27ms   89.53%
    Req/Sec    51.71     16.44   100.00     66.16%
  12197 requests in 1.00m, 1.41MB read
Requests/sec:    202.98
Transfer/sec:     23.98KB
thread 1 made 3072 requests including 3072 writes and got 3067 responses
thread 2 made 3034 requests including 3034 writes and got 3030 responses
thread 3 made 3041 requests including 3041 writes and got 3037 responses
thread 4 made 3067 requests including 3067 writes and got 3063 responses

#################################################################################
################################  Read Secrets  #################################
#################################################################################

Number of secrets is: 10000
thread 1 created with print_secrets set to false
Number of secrets is: 10000
thread 2 created with print_secrets set to false
Number of secrets is: 10000
thread 3 created with print_secrets set to false
Number of secrets is: 10000
thread 4 created with print_secrets set to false
Running 1m test @ https://vault.service.consul:8200
  4 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency    37.42ms   42.26ms 639.36ms   93.67%
    Req/Sec   126.79     64.21   545.00     74.51%
  30036 requests in 1.00m, 12.43MB read
Requests/sec:    499.82
Transfer/sec:    211.78KB
thread 1 made 7626 requests including 7626 reads and got 7624 responses
thread 2 made 7501 requests including 7501 reads and got 7497 responses
thread 3 made 7476 requests including 7476 reads and got 7472 responses
thread 4 made 7446 requests including 7446 reads and got 7443 responses
```

# Comparing between configurations

## Noisy Neighbor

One way or another we have all either lived or heard about a noisy neighbor that kept us or the storyteller up at night. The same concept is [transferable](https://docs.aws.amazon.com/wellarchitected/latest/saas-lens/noisy-neighbor.html) to our instances running on a cloud provider. In our testing process we stopped and started the entirety of our cluster which as a [result](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/Stop_Start.html) *the instances were migrated to new underlying host computers*. Without any other changes, and although we had left enough time for the instances to build a cpu burst balance we could clearly see a degradation on the service:

```bash
Synthetic test started at Fri Dec 16 07:02:27 UTC 2022 with the following options:

Theads: 4 
Connections: 16
Duration: 1m
Number of Secrets: 10000

#################################################################################
############################  Write Random Secrets  #############################
#################################################################################

Number of secrets is: 10000
thread 1 created
Number of secrets is: 10000
thread 2 created
Number of secrets is: 10000
thread 3 created
Number of secrets is: 10000
thread 4 created
Running 1m test @ https://vault.service.consul:8200
  4 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency    96.03ms   38.06ms 378.37ms   78.56%
    Req/Sec    43.03     14.40    90.00     70.66%
  10076 requests in 1.00m, 1.16MB read
Requests/sec:    167.85
Transfer/sec:     19.83KB
thread 1 made 2545 requests including 2545 writes and got 2540 responses
thread 2 made 2510 requests including 2510 writes and got 2506 responses
thread 3 made 2531 requests including 2531 writes and got 2527 responses
thread 4 made 2507 requests including 2507 writes and got 2503 responses

#################################################################################
############################  Write Delete Secrets  #############################
#################################################################################

Number of secrets is: 10000
thread 1 created
Number of secrets is: 10000
thread 2 created
Number of secrets is: 10000
thread 3 created
Number of secrets is: 10000
thread 4 created
Running 1m test @ https://vault.service.consul:8200
  4 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   101.83ms   41.23ms 420.65ms   78.85%
    Req/Sec    40.53     13.48    90.00     75.04%
  9520 requests in 1.00m, 1.10MB read
Requests/sec:    158.55
Transfer/sec:     18.73KB
thread 1 made 2416 requests including 1207 writes and 1209 deletes and got 2411 responses
thread 2 made 2385 requests including 1191 writes and 1194 deletes and got 2381 responses
thread 3 made 2370 requests including 1184 writes and 1186 deletes and got 2366 responses
thread 4 made 2366 requests including 1182 writes and 1184 deletes and got 2362 responses

#################################################################################
################################  Read Secrets  #################################
#################################################################################

Number of secrets is: 10000
thread 1 created with print_secrets set to false
Number of secrets is: 10000
thread 2 created with print_secrets set to false
Number of secrets is: 10000
thread 3 created with print_secrets set to false
Number of secrets is: 10000
thread 4 created with print_secrets set to false
Running 1m test @ https://vault.service.consul:8200
  4 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency    70.29ms   35.67ms 335.93ms   75.73%
    Req/Sec    59.59     20.58   151.00     80.88%
  14030 requests in 1.00m, 5.81MB read
Requests/sec:    233.47
Transfer/sec:     98.93KB
thread 1 made 3528 requests including 3528 reads and got 3523 responses
thread 2 made 3525 requests including 3525 reads and got 3521 responses
thread 3 made 3492 requests including 3492 reads and got 3488 responses
thread 4 made 3502 requests including 3502 reads and got 3498 responses

#################################################################################
##############################  Auth Revoke Users  ##############################
#################################################################################

thread 1 created
thread 2 created
thread 3 created
thread 4 created
Running 1m test @ https://vault.service.consul:8200
  4 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency    82.40ms   39.77ms 362.94ms   75.95%
    Req/Sec    50.69     17.20   110.00     66.18%
  11919 requests in 1.00m, 1.74MB read
  Non-2xx or 3xx responses: 5956
Requests/sec:    198.33
Transfer/sec:     29.73KB
thread 1 made 1483 authentications and 1486 revocations and got 1483 responses
thread 2 made 1490 authentications and 1493 revocations and got 1491 responses
thread 3 made 1489 authentications and 1492 revocations and got 1489 responses
thread 4 made 1500 authentications and 1503 revocations and got 1500 responses

#################################################################################
###########################  Read Random DB Secrets  ############################
#################################################################################

Number of secrets is: 1000
thread 1 created with print_secrets set to false
Number of secrets is: 1000
thread 2 created with print_secrets set to false
Number of secrets is: 1000
thread 3 created with print_secrets set to false
Number of secrets is: 1000
thread 4 created with print_secrets set to false
Running 1m test @ https://vault.service.consul:8200
  4 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   160.86ms   58.05ms 583.32ms   76.96%
    Req/Sec    26.21     11.58    60.00     53.42%
  5990 requests in 1.00m, 2.56MB read
Requests/sec:     99.68
Transfer/sec:     43.69KB
thread 1 made 1508 requests including 1508 reads and got 1503 responses
thread 2 made 1505 requests including 1505 reads and got 1501 responses
thread 3 made 1499 requests including 1499 reads and got 1495 responses
thread 4 made 1495 requests including 1495 reads and got 1491 responses
```

* Write Random Secrets  10076 vs 12203
* Write Delete Secrets   9520 vs 10839
* Read Secrets          14030 vs 29270
* Auth Revoke Users     11919 vs 17209

There are several other reasons than could have an effect on the numbers such us expiring credentials, other operations happening on the backend, network congestion etc, yet we will classify this under the noisy neighbor umbrella.

## Dedicate IOPS consul 

We know that a lot of our tests rely on disk activity and its performance. In our example below we have change from GP2 to Dedicated IOPS of 2.5k:

```bash
Synthetic test started at Fri Dec 16 08:47:06 UTC 2022 with the following options:

Theads: 4 
Connections: 16
Duration: 1m
Number of Secrets: 10000

#################################################################################
###########################  Read Random DB Secrets  ############################
#################################################################################

Number of secrets is: 1000
thread 1 created with print_secrets set to false
Number of secrets is: 1000
thread 2 created with print_secrets set to false
Number of secrets is: 1000
thread 3 created with print_secrets set to false
Number of secrets is: 1000
thread 4 created with print_secrets set to false
Running 1m test @ https://vault.service.consul:8200
  4 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   156.92ms   60.51ms 521.79ms   76.86%
    Req/Sec    27.08     11.98    70.00     46.47%
  6165 requests in 1.00m, 2.64MB read
Requests/sec:    102.60
Transfer/sec:     44.97KB
thread 1 made 1548 requests including 1548 reads and got 1543 responses
thread 2 made 1537 requests including 1537 reads and got 1533 responses
thread 3 made 1545 requests including 1545 reads and got 1541 responses
thread 4 made 1552 requests including 1552 reads and got 1548 responses

#################################################################################
##############################  Auth Revoke Users  ##############################
#################################################################################

thread 1 created
thread 2 created
thread 3 created
thread 4 created
Running 1m test @ https://vault.service.consul:8200
  4 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency    80.92ms   43.32ms 418.20ms   78.16%
    Req/Sec    52.50     18.58   120.00     74.32%
  12284 requests in 1.00m, 1.80MB read
  Non-2xx or 3xx responses: 6139
Requests/sec:    204.41
Transfer/sec:     30.64KB
thread 1 made 1537 authentications and 1539 revocations and got 1536 responses
thread 2 made 1531 authentications and 1533 revocations and got 1531 responses
thread 3 made 1541 authentications and 1543 revocations and got 1541 responses
thread 4 made 1537 authentications and 1540 revocations and got 1537 responses

#################################################################################
################################  Read Secrets  #################################
#################################################################################

Number of secrets is: 10000
thread 1 created with print_secrets set to false
Number of secrets is: 10000
thread 2 created with print_secrets set to false
Number of secrets is: 10000
thread 3 created with print_secrets set to false
Number of secrets is: 10000
thread 4 created with print_secrets set to false
Running 1m test @ https://vault.service.consul:8200
  4 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency    69.74ms   38.90ms 365.22ms   78.74%
    Req/Sec    61.03     21.86   140.00     76.50%
  14302 requests in 1.00m, 5.92MB read
Requests/sec:    237.99
Transfer/sec:    100.84KB
thread 1 made 3593 requests including 3593 reads and got 3588 responses
thread 2 made 3568 requests including 3568 reads and got 3564 responses
thread 3 made 3582 requests including 3582 reads and got 3578 responses
thread 4 made 3576 requests including 3576 reads and got 3572 responses

#################################################################################
############################  Write Delete Secrets  #############################
#################################################################################

Number of secrets is: 10000
thread 1 created
Number of secrets is: 10000
thread 2 created
Number of secrets is: 10000
thread 3 created
Number of secrets is: 10000
thread 4 created
Running 1m test @ https://vault.service.consul:8200
  4 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   101.64ms   44.93ms 438.56ms   79.93%
    Req/Sec    41.19     14.62    80.00     69.24%
  9587 requests in 1.00m, 1.11MB read
Requests/sec:    159.54
Transfer/sec:     18.85KB
thread 1 made 2436 requests including 1217 writes and 1219 deletes and got 2431 responses
thread 2 made 2375 requests including 1186 writes and 1189 deletes and got 2371 responses
thread 3 made 2380 requests including 1189 writes and 1191 deletes and got 2376 responses
thread 4 made 2413 requests including 1205 writes and 1208 deletes and got 2409 responses

#################################################################################
############################  Write Random Secrets  #############################
#################################################################################

Number of secrets is: 10000
thread 1 created
Number of secrets is: 10000
thread 2 created
Number of secrets is: 10000
thread 3 created
Number of secrets is: 10000
thread 4 created
Running 1m test @ https://vault.service.consul:8200
  4 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency    94.07ms   41.35ms 421.74ms   79.24%
    Req/Sec    44.53     15.63   161.00     79.10%
  10384 requests in 1.00m, 1.20MB read
Requests/sec:    172.79
Transfer/sec:     20.42KB
thread 1 made 2611 requests including 2611 writes and got 2606 responses
thread 2 made 2583 requests including 2583 writes and got 2579 responses
thread 3 made 2613 requests including 2613 writes and got 2609 responses
thread 4 made 2594 requests including 2594 writes and got 2590 responses
```

* Write Random Secrets    10384 vs 10076
* Write Delete Secrets     9587 vs  9520
* Read Secrets            14302 vs 14030
* Auth Revoke Users       12284 vs 11919
* Read Random DB Secrets   6165 vs  5990

For the intensity and load of our tests, using volume with dedicated IOPS had no effect whatsoever. 

## Using magnetic storage consul

We already saw that SSD (gp2) and Dedicated IOPS drive had insignificant differences ofr our tests. What happens if we go for magnetic type volumes for the database backend:

```bash
Synthetic test started at Fri Dec 16 13:52:49 UTC 2022 with the following options:

Theads: 4 
Connections: 16
Duration: 1m
Number of Secrets: 10000

#################################################################################
############################  Write Delete Secrets  #############################
#################################################################################

Number of secrets is: 10000
thread 1 created
Number of secrets is: 10000
thread 2 created
Number of secrets is: 10000
thread 3 created
Number of secrets is: 10000
thread 4 created
Running 1m test @ https://vault.service.consul:8200
  4 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   326.04ms  354.10ms   1.94s    83.47%
    Req/Sec    30.38     18.28    80.00     51.59%
  4259 requests in 1.00m, 503.26KB read
  Socket errors: connect 0, read 0, write 0, timeout 2
Requests/sec:     70.95
Transfer/sec:      8.38KB
thread 1 made 1089 requests including 543 writes and 546 deletes and got 1084 responses
thread 2 made 1075 requests including 536 writes and 539 deletes and got 1071 responses
thread 3 made 1052 requests including 525 writes and 527 deletes and got 1048 responses
thread 4 made 1060 requests including 529 writes and 531 deletes and got 1056 responses

#################################################################################
##############################  Auth Revoke Users  ##############################
#################################################################################

thread 1 created
thread 2 created
thread 3 created
thread 4 created
Running 1m test @ https://vault.service.consul:8200
  4 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency    58.66ms  112.49ms   1.07s    93.99%
    Req/Sec   126.62     75.14   300.00     57.30%
  28113 requests in 1.00m, 4.12MB read
  Non-2xx or 3xx responses: 14052
Requests/sec:    467.80
Transfer/sec:     70.12KB
thread 1 made 3521 authentications and 3523 revocations and got 3520 responses
thread 2 made 3506 authentications and 3509 revocations and got 3507 responses
thread 3 made 3515 authentications and 3517 revocations and got 3515 responses
thread 4 made 3518 authentications and 3521 revocations and got 3519 responses

#################################################################################
############################  Write Random Secrets  #############################
#################################################################################

Number of secrets is: 10000
thread 1 created
Number of secrets is: 10000
thread 2 created
Number of secrets is: 10000
thread 3 created
Number of secrets is: 10000
thread 4 created
Running 1m test @ https://vault.service.consul:8200
  4 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   293.36ms  326.12ms   1.81s    83.20%
    Req/Sec    34.25     20.10   100.00     60.19%
  4888 requests in 1.00m, 577.59KB read
  Socket errors: connect 0, read 0, write 0, timeout 1
Requests/sec:     81.34
Transfer/sec:      9.61KB
thread 1 made 1250 requests including 1250 writes and got 1245 responses
thread 2 made 1234 requests including 1234 writes and got 1230 responses
thread 3 made 1212 requests including 1212 writes and got 1208 responses
thread 4 made 1209 requests including 1209 writes and got 1205 responses

#################################################################################
###########################  Read Random DB Secrets  ############################
#################################################################################

Number of secrets is: 1000
thread 1 created with print_secrets set to false
Number of secrets is: 1000
thread 2 created with print_secrets set to false
Number of secrets is: 1000
thread 3 created with print_secrets set to false
Number of secrets is: 1000
thread 4 created with print_secrets set to false
Running 1m test @ https://vault.service.consul:8200
  4 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   432.27ms  391.66ms   1.99s    83.42%
    Req/Sec    19.57     12.62    50.00     67.30%
  2672 requests in 1.00m, 1.14MB read
  Socket errors: connect 0, read 0, write 0, timeout 3
Requests/sec:     44.46
Transfer/sec:     19.48KB
thread 1 made 674 requests including 674 reads and got 669 responses
thread 2 made 680 requests including 680 reads and got 676 responses
thread 3 made 673 requests including 673 reads and got 669 responses
thread 4 made 662 requests including 662 reads and got 658 responses

#################################################################################
################################  Read Secrets  #################################
#################################################################################

Number of secrets is: 10000
thread 1 created with print_secrets set to false
Number of secrets is: 10000
thread 2 created with print_secrets set to false
Number of secrets is: 10000
thread 3 created with print_secrets set to false
Number of secrets is: 10000
thread 4 created with print_secrets set to false
Running 1m test @ https://vault.service.consul:8200
  4 threads and 16 connections
  Thread Stats   Avg      Stdev     Max   +/- Stdev
    Latency   158.08ms  241.57ms   1.73s    86.36%
    Req/Sec    76.39     42.89   484.00     69.99%
  14285 requests in 1.00m, 5.91MB read
Requests/sec:    237.71
Transfer/sec:    100.72KB
thread 1 made 3580 requests including 3580 reads and got 3575 responses
thread 2 made 3482 requests including 3482 reads and got 3478 responses
thread 3 made 3745 requests including 3745 reads and got 3742 responses
thread 4 made 3494 requests including 3494 reads and got 3490 responses
```

We can clearly see that the performance has halved for the write operations, even for our small duration and number of secrets tested:

* Write Random Secrets    4888 vs 10076
* Write Delete Secrets    4259 vs 9520
* Read Secrets            14285 vs 14030
* Auth Revoke Users       28113 vs 11919
* Read Random DB Secrets  2672 vs 5990

As far as the increase in the Auth Revoke results we can assume that whichever background process or disc warmup has finished, and allowed the engine to go trough more requests.

** Configuration conclusion

Although the strongest and the fastest infrastructure will always yeld better results, this is directly connected to the engine used, the duration and the number of secrets used. Depending on your implementation you can use the above tests to underline changes for a number of changes:

* Instance Sizes
* Disk Types
* Availability Zones
* Regions and expected delays between VPC peering
* Optimization settings for Vault/Consul
* Version Changes

Happy testing!