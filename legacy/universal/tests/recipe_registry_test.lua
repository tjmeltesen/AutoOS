#!/usr/bin/env lua

local sep = package.config:sub(1, 1)
local script = (arg and arg[0]) or "universal/tests/recipe_registry_test.lua"
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
local RecipeRegistry = require("shared.recipe_registry")

H.summary("Universal — recipe registry")

local benzene = RecipeRegistry.lookup("Benzene")
H.check("Benzene known", benzene ~= nil)
H.check("Benzene machine_type", benzene and benzene.machine_type == "distillation_tower")
H.check("Benzene tools", benzene and benzene.tools[1] == "Circuit24")

H.check("unknown label nil", RecipeRegistry.lookup("NotAProduct") == nil)
H.check("known() true", RecipeRegistry.known("Toluene"))
H.check("known() false", not RecipeRegistry.known("Fake"))

H.check("has_tools match",
  RecipeRegistry.has_tools({ "Circuit24", "TowerMold" }, { "Circuit24" }))
H.check("has_tools missing",
  not RecipeRegistry.has_tools({ "Circuit25" }, { "Circuit24" }))
H.check("has_tools empty required", RecipeRegistry.has_tools({}, {}))

os.exit(H.report() and 0 or 1)
