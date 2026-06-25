# Graph Report - AutoOS  (2026-06-23)

## Corpus Check
- 169 files · ~109,759 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 956 nodes · 1250 edges · 27 communities detected
- Extraction: 81% EXTRACTED · 19% INFERRED · 0% AMBIGUOUS · INFERRED: 234 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Community 0|Community 0]]
- [[_COMMUNITY_Community 1|Community 1]]
- [[_COMMUNITY_Community 2|Community 2]]
- [[_COMMUNITY_Community 3|Community 3]]
- [[_COMMUNITY_Community 5|Community 5]]
- [[_COMMUNITY_Community 6|Community 6]]
- [[_COMMUNITY_Community 7|Community 7]]
- [[_COMMUNITY_Community 8|Community 8]]
- [[_COMMUNITY_Community 9|Community 9]]
- [[_COMMUNITY_Community 10|Community 10]]
- [[_COMMUNITY_Community 11|Community 11]]
- [[_COMMUNITY_Community 13|Community 13]]
- [[_COMMUNITY_Community 15|Community 15]]
- [[_COMMUNITY_Community 17|Community 17]]
- [[_COMMUNITY_Community 19|Community 19]]
- [[_COMMUNITY_Community 22|Community 22]]
- [[_COMMUNITY_Community 23|Community 23]]
- [[_COMMUNITY_Community 24|Community 24]]
- [[_COMMUNITY_Community 27|Community 27]]
- [[_COMMUNITY_Community 28|Community 28]]
- [[_COMMUNITY_Community 29|Community 29]]
- [[_COMMUNITY_Community 30|Community 30]]
- [[_COMMUNITY_Community 31|Community 31]]
- [[_COMMUNITY_Community 34|Community 34]]
- [[_COMMUNITY_Community 35|Community 35]]
- [[_COMMUNITY_Community 36|Community 36]]
- [[_COMMUNITY_Community 40|Community 40]]

## God Nodes (most connected - your core abstractions)
1. `print()` - 24 edges
2. `clean()` - 13 edges
3. `BrokerMain.run()` - 13 edges
4. `component.isAvailable()` - 12 edges
5. `BrokerMain.build()` - 12 edges
6. `pcallR()` - 11 edges
7. `Registry.build()` - 11 edges
8. `RobTick.run()` - 11 edges
9. `ROBDispatcher:tick()` - 10 edges
10. `U.FG()` - 10 edges

## Surprising Connections (you probably didn't know these)
- `build_oc_deps()` --calls--> `component.isAvailable()`  [INFERRED]
  legacy\main.lua → references\OC-GTNH-docs-main\docs\component.lua
- `HW.require_proxy()` --calls--> `MachinePoll:refresh_proxies()`  [INFERRED]
  subnet_broker\hw.lua → subnet_broker\machine_poll.lua
- `Orchestrator.new()` --calls--> `OrchestratorMain.build()`  [INFERRED]
  orchestrator\orchestrator.lua → orchestrator\orchestrator_main.lua
- `BrokerMain.attach_tasks()` --calls--> `HW.clear_proxy_cache()`  [INFERRED]
  subnet_broker\broker_main.lua → subnet_broker\hw.lua
- `Scheduler.new()` --calls--> `make_sched()`  [INFERRED]
  subnet_broker\coroutine_scheduler.lua → tests\coroutine_scheduler_test.lua

## Communities

### Community 0 - "Community 0"
Cohesion: 0.05
Nodes (38): boot(), Bootstrap._build_impl(), detect_gpu(), detect_gpu(), BrokerMain.attach_tasks(), BrokerMain.build(), BrokerMain._build_impl(), BrokerMain.run() (+30 more)

### Community 1 - "Community 1"
Cohesion: 0.05
Nodes (44): AdmissionControl.count_circuits(), AdmissionControl.is_ok(), AdmissionControl.job_stabilize_s(), AdmissionControl.max_circuits(), BufferMonitor.build_fingerprint(), BufferMonitor.new(), BufferMonitor.step(), fingerprint_equal() (+36 more)

### Community 2 - "Community 2"
Cohesion: 0.04
Nodes (20): BrokerUI:run(), BasePage.new(), ConfigPage:handle_input(), ConfigPage.new(), ConfigPage:redraw_field(), ConfigPage:render(), serialize_config(), DashboardPage.new() (+12 more)

### Community 3 - "Community 3"
Cohesion: 0.06
Nodes (38): CircuitManager:_find_circuit_on_side(), CircuitManager:scan_transposer(), CircuitManager:_transfer_with_retries(), find_machine(), clear_all(), join(), list_lua(), main() (+30 more)

### Community 5 - "Community 5"
Cohesion: 0.06
Nodes (17): ConnectedPeripherals:_checkPeripherals(), ConnectedPeripherals:hasFluidsInInput(), ConnectedPeripherals:hasItemsInInput(), ConnectedPeripherals:pushFluids(), ConnectedPeripherals:pushItems(), findFileRecursive(), FormatTable(), isTableEmpty() (+9 more)

### Community 6 - "Community 6"
Cohesion: 0.06
Nodes (8): Display.new(), Display:render(), on_off(), yes_no(), gpu.bind(), gpu.getResolution(), gpu.maxResolution(), gpu.setResolution()

### Community 7 - "Community 7"
Cohesion: 0.06
Nodes (17): Adapter.new(), Arbitrator:commit(), Arbitrator:_craft_slot_available(), Arbitrator.new(), machine_idle(), select_intent(), build_oc_deps(), Kernel:_display_key() (+9 more)

### Community 8 - "Community 8"
Cohesion: 0.06
Nodes (17): Diagnostics.print_lane_status(), PollCache.mark_dirty(), PollCache.write(), TestTick.run_once(), event_matches(), normalize_wait(), Scheduler:_dispatch_event(), Scheduler:_resume() (+9 more)

### Community 9 - "Community 9"
Cohesion: 0.07
Nodes (10): DescriptorCache.new(), entry_is_fluid_drop(), entry_is_item(), lower(), bold(), check(), color(), green() (+2 more)

### Community 10 - "Community 10"
Cohesion: 0.16
Nodes (18): EventBus.drain(), clean(), num(), Protocols.broker_event(), Protocols.broker_health(), Protocols.broker_status(), Protocols.craft_ack(), Protocols.craft_done() (+10 more)

### Community 11 - "Community 11"
Cohesion: 0.11
Nodes (16): bold(), check(), color(), green(), red(), check(), filter_match(), Mock.new() (+8 more)

### Community 13 - "Community 13"
Cohesion: 0.24
Nodes (16): DescriptorCache:_db(), HW.clear_proxy_cache(), HW.on_network(), HW.proxy(), HW.require_proxy(), HW.sleep(), proxy_cache_key(), bind_methods() (+8 more)

### Community 15 - "Community 15"
Cohesion: 0.28
Nodes (10): Adapter:poll(), Adapter:poll_inventory(), detect_power_loss(), find_fluid(), parse_eu_pair(), parse_eu_rate(), parse_eu_usage_from_sensor(), parse_stored_eu_from_sensor() (+2 more)

### Community 17 - "Community 17"
Cohesion: 0.19
Nodes (7): MachinePoll:build_idle_pool(), MachinePoll.is_idle(), MachinePoll:poll_machine(), MachinePoll:refresh_proxies(), MaintenanceParse.has_fault(), problems_count(), strip_format()

### Community 19 - "Community 19"
Cohesion: 0.31
Nodes (6): bold(), check(), color(), dim(), green(), red()

### Community 22 - "Community 22"
Cohesion: 0.33
Nodes (8): _ensure_ring(), FaultNet.bind(), FaultNet.capture(), FaultNet.guard(), _file_append(), _ring_append(), _timestamp(), Task.spawn()

### Community 23 - "Community 23"
Cohesion: 0.42
Nodes (6): bold(), check(), color(), dim(), green(), red()

### Community 24 - "Community 24"
Cohesion: 0.36
Nodes (7): FluidTanks.buffer_empty(), FluidTanks.fluid_rows(), FluidTanks.label_matches(), FluidTanks.non_empty_tanks(), FluidTanks.tank_level(), lower(), normalize_label()

### Community 27 - "Community 27"
Cohesion: 0.62
Nodes (6): bold(), check(), color(), dim(), green(), red()

### Community 28 - "Community 28"
Cohesion: 0.38
Nodes (3): AE2.requestFluid(), AE2.requestItem(), getCraftableForItem()

### Community 29 - "Community 29"
Cohesion: 0.33
Nodes (2): LockManager.release(), LockManager.release_all()

### Community 30 - "Community 30"
Cohesion: 0.52
Nodes (6): bold(), check(), color(), green(), make_sched(), red()

### Community 31 - "Community 31"
Cohesion: 0.4
Nodes (2): nullifyUndefined(), opt()

### Community 34 - "Community 34"
Cohesion: 0.47
Nodes (4): build_pump_coroutine(), drain_pump(), file_log(), incremental_poll()

### Community 35 - "Community 35"
Cohesion: 0.7
Nodes (4): dirname(), download_file(), ensure_dir(), main()

### Community 36 - "Community 36"
Cohesion: 0.7
Nodes (4): Maintenance.evaluate(), Maintenance.has_fault(), problems_count(), strip_format()

### Community 40 - "Community 40"
Cohesion: 0.83
Nodes (3): document_module(), sniff_proxy(), w()

## Knowledge Gaps
- **Thin community `Community 29`** (7 nodes): `LockManager.acquire()`, `LockManager.build_resources()`, `LockManager.get_locks()`, `LockManager.release()`, `LockManager.release_all()`, `LockManager.release_transport()`, `lock_manager.lua`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 31`** (6 nodes): `getRotorHolder()`, `metaMachineWrapper()`, `nullifyUndefined()`, `opt()`, `toInt()`, `greg_ex.js`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `print()` connect `Community 0` to `Community 2`, `Community 35`, `Community 3`, `Community 5`, `Community 7`, `Community 8`, `Community 22`?**
  _High betweenness centrality (0.171) - this node is a cross-community bridge._
- **Why does `BrokerMain.run()` connect `Community 0` to `Community 10`?**
  _High betweenness centrality (0.085) - this node is a cross-community bridge._
- **Why does `Kernel.new()` connect `Community 7` to `Community 11`?**
  _High betweenness centrality (0.077) - this node is a cross-community bridge._
- **Are the 20 inferred relationships involving `print()` (e.g. with `main()` and `try()`) actually correct?**
  _`print()` has 20 INFERRED edges - model-reasoned connections that need verification._
- **Are the 10 inferred relationships involving `BrokerMain.run()` (e.g. with `print()` and `Protocols.parse()`) actually correct?**
  _`BrokerMain.run()` has 10 INFERRED edges - model-reasoned connections that need verification._
- **Are the 11 inferred relationships involving `component.isAvailable()` (e.g. with `build_oc_deps()` and `me_proxy()`) actually correct?**
  _`component.isAvailable()` has 11 INFERRED edges - model-reasoned connections that need verification._
- **Are the 9 inferred relationships involving `BrokerMain.build()` (e.g. with `component.isAvailable()` and `modem.open()`) actually correct?**
  _`BrokerMain.build()` has 9 INFERRED edges - model-reasoned connections that need verification._