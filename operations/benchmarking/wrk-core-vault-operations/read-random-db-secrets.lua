-- Script that reads secrets from database secrets engine in Vault
-- Example with print secrets on: wrk -t1 -c1 -d5m -H "X-Vault-Token: $VAULT_TOKEN" -s read-db-secrets.lua "${VAULT_ADDR}" -- true
-- Example without printing secrets: wrk -t1 -c1 -d5m -H "X-Vault-Token: $VAULT_TOKEN" -s read-db-secrets.lua "${VAULT_ADDR}" -- false

local str =
[[

#################################################################################
###########################  Read Random DB Secrets  ############################
#################################################################################
]]

json = require "json"

local counter = 1
local threads = {}

function setup(thread)
   thread:set("id", counter)
   table.insert(threads, thread)
   counter = counter + 1
end

function init(args)
   if args[1] == nil then
      print_secrets = "false"
   else
      print_secrets = args[1]
   end
   
   if args[2] == nil then
      num_roles = 1000
   else
      num_roles = tonumber(args[2])
   end
   if id == 1 then
      print(str)
   end
   print("Number of secrets is: " .. num_roles)
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

function request()
   reads = reads + 1
   -- randomize path to secret
   randomrole = math.random(num_roles)
   path = "/v1/database" .. randomrole .. "/creds/benchmarking" .. randomrole
   requests = requests + 1
   return wrk.format(method, path, nil, body)
end

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
