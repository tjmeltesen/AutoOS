--[[
  AutoOS — Profiling Harness
  Wall-clock timing via os.clock(), N iterations, CSV output.

  Usage:
    local harness = ProfileHarness.new({ iterations = 100 })
    harness:measure("dispatch", function() do_work() end)
    harness:report()
]]

local ProfileHarness = {}
ProfileHarness.__index = ProfileHarness

function ProfileHarness.new(opts)
  opts = opts or {}
  return setmetatable({
    iterations = opts.iterations or 100,
    results = {},
  }, ProfileHarness)
end

function ProfileHarness:measure(name, fn)
  local times = {}
  for _ = 1, self.iterations do
    local start = os.clock()
    fn()
    local elapsed = os.clock() - start
    times[#times + 1] = elapsed
  end

  table.sort(times)
  local sum = 0
  local min_val = times[1]
  local max_val = times[#times]
  for _, t in ipairs(times) do
    sum = sum + t
  end
  local mean = sum / #times
  local median = times[math.ceil(#times / 2)]
  local p95_idx = math.ceil(#times * 0.95)
  local p95 = times[p95_idx]

  self.results[name] = {
    samples = #times,
    min = min_val,
    max = max_val,
    mean = mean,
    median = median,
    p95 = p95,
    total = sum,
  }
  return self.results[name]
end

function ProfileHarness:report()
  local lines = { "name,samples,total_s,mean_ms,median_ms,p95_ms,min_ms,max_ms" }
  for name, r in pairs(self.results) do
    lines[#lines + 1] = string.format("%s,%d,%.6f,%.3f,%.3f,%.3f,%.3f,%.3f",
      name, r.samples, r.total,
      r.mean * 1000, r.median * 1000, r.p95 * 1000,
      r.min * 1000, r.max * 1000)
  end
  return table.concat(lines, "\n")
end

function ProfileHarness:save_report(filepath)
  local f = io.open(filepath, "w")
  if f then
    f:write(self:report())
    f:write("\n")
    f:close()
  end
end

return ProfileHarness
