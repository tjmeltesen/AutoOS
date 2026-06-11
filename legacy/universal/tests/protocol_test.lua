#!/usr/bin/env lua

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "universal/tests/protocol_test.lua"
local tests_dir = script:match("^(.*)[/\\]") or "universal/tests"
local universal_root = tests_dir .. sep .. ".."
local project_root = universal_root .. sep .. ".."
package.path = table.concat({
  universal_root .. sep .. "?.lua",
  tests_dir .. sep .. "?.lua",
  project_root .. sep .. "?.lua",
  package.path,
}, ";")

local H = require("test_harness")
local Protocol = require("shared.protocol")

H.summary("Universal — protocol encode/decode")

local req = Protocol.craft_req("Benzene:1:100", "Benzene", 16000, "fluid")
H.check("craft_req encode", req == "craft_req|Benzene:1:100|Benzene|16000|fluid")

local decoded = Protocol.decode(req)
H.check("craft_req decode type", decoded and decoded.type == "craft_req")
local parsed = Protocol.parse_craft_req(decoded.fields)
H.check("craft_req parse label", parsed and parsed.label == "Benzene")
H.check("craft_req parse amount", parsed and parsed.amount == 16000)
H.check("craft_req parse kind", parsed and parsed.kind == "fluid")

local ack = Protocol.craft_ack("job1", "dist_tower_a", "dist_array_1")
local ack_p = Protocol.parse_craft_ack(Protocol.decode(ack).fields)
H.check("craft_ack parse", ack_p and ack_p.machine_id == "dist_tower_a")

local done = Protocol.craft_done("job1", "dist_tower_a")
local done_p = Protocol.parse_craft_done(Protocol.decode(done).fields)
H.check("craft_done parse", done_p and done_p.job_id == "job1")

local fail = Protocol.craft_fail("job1", "no_available_machine")
local fail_p = Protocol.parse_craft_fail(Protocol.decode(fail).fields)
H.check("craft_fail parse", fail_p and fail_p.reason == "no_available_machine")

local adv = Protocol.capability_advertise("dist_array_1", "distillation_tower,chemical_reactor")
local adv_p = Protocol.parse_capability_advertise(Protocol.decode(adv).fields)
H.check("capability_advertise reserved decode",
  adv_p and adv_p.broker_id == "dist_array_1" and #adv_p.capabilities == 2)
H.check("capability_advertise is reserved", Protocol.is_reserved("capability_advertise"))

H.check("malformed decode nil", Protocol.decode("") == nil)

os.exit(H.report() and 0 or 1)
