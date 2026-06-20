# Graph Report - AutoOS  (2026-06-20)

## Corpus Check
- 141 files · ~112,919 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 1009 nodes · 1356 edges · 28 communities detected
- Extraction: 86% EXTRACTED · 14% INFERRED · 0% AMBIGUOUS · INFERRED: 195 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Community 0|Community 0]]
- [[_COMMUNITY_Community 1|Community 1]]
- [[_COMMUNITY_Community 3|Community 3]]
- [[_COMMUNITY_Community 4|Community 4]]
- [[_COMMUNITY_Community 5|Community 5]]
- [[_COMMUNITY_Community 6|Community 6]]
- [[_COMMUNITY_Community 7|Community 7]]
- [[_COMMUNITY_Community 8|Community 8]]
- [[_COMMUNITY_Community 9|Community 9]]
- [[_COMMUNITY_Community 10|Community 10]]
- [[_COMMUNITY_Community 11|Community 11]]
- [[_COMMUNITY_Community 12|Community 12]]
- [[_COMMUNITY_Community 14|Community 14]]
- [[_COMMUNITY_Community 15|Community 15]]
- [[_COMMUNITY_Community 17|Community 17]]
- [[_COMMUNITY_Community 18|Community 18]]
- [[_COMMUNITY_Community 19|Community 19]]
- [[_COMMUNITY_Community 21|Community 21]]
- [[_COMMUNITY_Community 23|Community 23]]
- [[_COMMUNITY_Community 25|Community 25]]
- [[_COMMUNITY_Community 28|Community 28]]
- [[_COMMUNITY_Community 29|Community 29]]
- [[_COMMUNITY_Community 30|Community 30]]
- [[_COMMUNITY_Community 33|Community 33]]
- [[_COMMUNITY_Community 34|Community 34]]
- [[_COMMUNITY_Community 35|Community 35]]
- [[_COMMUNITY_Community 36|Community 36]]
- [[_COMMUNITY_Community 37|Community 37]]

## God Nodes (most connected - your core abstractions)
1. `print()` - 28 edges
2. `LaneWorker.execute()` - 17 edges
3. `BrokerMain.run()` - 16 edges
4. `HW.require_proxy()` - 15 edges
5. `BrokerMain.build()` - 15 edges
6. `clean()` - 13 edges
7. `HW.proxy()` - 12 edges
8. `LaneSides.bus_side()` - 12 edges
9. `pcallR()` - 11 edges
10. `Registry.build()` - 11 edges

## Surprising Connections (you probably didn't know these)
- `build_oc_deps()` --calls--> `component.isAvailable()`  [INFERRED]
  legacy\main.lua → references\OC-GTNH-docs-main\docs\component.lua
- `HW.require_proxy()` --calls--> `MachinePoll:refresh_proxies()`  [INFERRED]
  subnet_broker\hw.lua → subnet_broker\machine_poll.lua
- `Protocols.broker_health()` --calls--> `ArrayWatch:_send_health()`  [INFERRED]
  subnet_broker\network_protocols.lua → subnet_broker\array_watch.lua
- `Protocols.broker_event()` --calls--> `ArrayWatch:_send_event()`  [INFERRED]
  subnet_broker\network_protocols.lua → subnet_broker\array_watch.lua
- `Orchestrator.new()` --calls--> `OrchestratorMain.build()`  [INFERRED]
  orchestrator\orchestrator.lua → orchestrator\orchestrator_main.lua

## Communities

### Community 0 - "Community 0"
Cohesion: 0.04
Nodes (46): CentralDispatch:_bus_empty(), CentralDispatch:_return_empty(), _build_steps(), lane_default(), LaneDispatch:_buffer_has_fluid(), LaneDispatch:_buffer_has_items(), LaneDispatch:_fluid_drained(), LaneDispatch:_fluid_pull_side() (+38 more)

### Community 1 - "Community 1"
Cohesion: 0.06
Nodes (39): try(), event.pull(), clear_all(), join(), list_lua(), main(), print(), read_head() (+31 more)

### Community 3 - "Community 3"
Cohesion: 0.06
Nodes (31): CentralDispatch:_descriptor_iface(), CentralDispatch:_fluid_adapter(), CentralDispatch:_item_adapter(), CentralDispatch:_lane_fluid_tp(), CentralDispatch:_lane_item_tp(), CircuitManager:scan_transposer(), CircuitManager:_transfer_with_retries(), find_machine() (+23 more)

### Community 4 - "Community 4"
Cohesion: 0.05
Nodes (18): ConnectedPeripherals:_checkPeripherals(), ConnectedPeripherals:hasFluidsInInput(), ConnectedPeripherals:hasItemsInInput(), ConnectedPeripherals:pushFluids(), ConnectedPeripherals:pushItems(), findFileRecursive(), FormatTable(), isTableEmpty() (+10 more)

### Community 5 - "Community 5"
Cohesion: 0.05
Nodes (8): fingerprint_equal(), fingerprint_nonempty(), norm_fluid_label(), ROBDispatcher:_build_manifest(), ROBDispatcher:_fluids_from_central_tank(), ROBDispatcher.new(), ROBDispatcher:_step_buffer_monitor(), _stack_on_adapter()

### Community 6 - "Community 6"
Cohesion: 0.08
Nodes (26): ArrayWatch.new(), boot(), BrokerMain.build(), BrokerMain._build_impl(), BrokerMain.run(), BrokerMain.run_once(), print_lane_status(), CircuitManager.new() (+18 more)

### Community 7 - "Community 7"
Cohesion: 0.06
Nodes (8): Display.new(), Display:render(), on_off(), yes_no(), gpu.bind(), gpu.getResolution(), gpu.maxResolution(), gpu.setResolution()

### Community 8 - "Community 8"
Cohesion: 0.07
Nodes (19): Adapter.new(), Adapter:poll(), Adapter:poll_inventory(), detect_power_loss(), find_fluid(), parse_eu_pair(), parse_eu_rate(), parse_eu_usage_from_sensor() (+11 more)

### Community 9 - "Community 9"
Cohesion: 0.07
Nodes (10): DescriptorCache.new(), entry_is_fluid_drop(), entry_is_item(), lower(), bold(), check(), color(), green() (+2 more)

### Community 10 - "Community 10"
Cohesion: 0.11
Nodes (28): CentralDispatch:_fluid_level(), FluidTanks.buffer_empty(), FluidTanks.fluid_rows(), FluidTanks.label_matches(), FluidTanks.non_empty_tanks(), FluidTanks.tank_capacity(), FluidTanks.tank_level(), lower() (+20 more)

### Community 11 - "Community 11"
Cohesion: 0.07
Nodes (5): CentralDispatch:_batch_manifest(), CentralDispatch:_fluids_from_central_tank(), CentralDispatch:tick(), fingerprint_equal(), _norm_fluid_label()

### Community 12 - "Community 12"
Cohesion: 0.1
Nodes (19): bold(), check(), color(), green(), make_fixture(), new_fluid_tp(), new_item_tp(), red() (+11 more)

### Community 14 - "Community 14"
Cohesion: 0.22
Nodes (16): clean(), num(), Protocols.broker_event(), Protocols.broker_health(), Protocols.broker_status(), Protocols.craft_ack(), Protocols.craft_done(), Protocols.craft_fail() (+8 more)

### Community 15 - "Community 15"
Cohesion: 0.09
Nodes (2): ArrayWatch:_send_event(), ArrayWatch:_send_health()

### Community 17 - "Community 17"
Cohesion: 0.14
Nodes (8): BrokerMain.attach_tasks(), event_matches(), normalize_wait(), Scheduler:_dispatch_event(), Scheduler:_resume(), Scheduler.sleep(), Scheduler.wait_event(), Scheduler.yield_now()

### Community 18 - "Community 18"
Cohesion: 0.12
Nodes (1): InterfaceStock.new()

### Community 19 - "Community 19"
Cohesion: 0.18
Nodes (8): CentralDispatch:_machine_available(), MachinePoll:build_idle_pool(), MachinePoll.is_idle(), MachinePoll:poll_machine(), MachinePoll:refresh_proxies(), MaintenanceParse.has_fault(), problems_count(), strip_format()

### Community 21 - "Community 21"
Cohesion: 0.28
Nodes (12): CentralDispatch.new(), bold(), check(), color(), green(), make_fixture(), new_adapter(), new_fluid_adapter() (+4 more)

### Community 23 - "Community 23"
Cohesion: 0.31
Nodes (6): bold(), check(), color(), dim(), green(), red()

### Community 25 - "Community 25"
Cohesion: 0.42
Nodes (6): bold(), check(), color(), dim(), green(), red()

### Community 28 - "Community 28"
Cohesion: 0.62
Nodes (6): bold(), check(), color(), dim(), green(), red()

### Community 29 - "Community 29"
Cohesion: 0.38
Nodes (3): AE2.requestFluid(), AE2.requestItem(), getCraftableForItem()

### Community 30 - "Community 30"
Cohesion: 0.4
Nodes (2): nullifyUndefined(), opt()

### Community 33 - "Community 33"
Cohesion: 0.67
Nodes (5): bold(), check(), color(), green(), red()

### Community 34 - "Community 34"
Cohesion: 0.67
Nodes (5): bold(), check(), color(), green(), red()

### Community 35 - "Community 35"
Cohesion: 0.67
Nodes (5): bold(), check(), color(), green(), red()

### Community 36 - "Community 36"
Cohesion: 0.67
Nodes (5): bold(), check(), color(), green(), red()

### Community 37 - "Community 37"
Cohesion: 0.7
Nodes (4): Maintenance.evaluate(), Maintenance.has_fault(), problems_count(), strip_format()

## Knowledge Gaps
- **Thin community `Community 15`** (22 nodes): `ArrayWatch:_active_job_count()`, `ArrayWatch:_advance_scheduler_rr()`, `ArrayWatch:any_fast_tick()`, `ArrayWatch:_handle_central_events()`, `ArrayWatch:_handle_fault()`, `ArrayWatch:handle_poll_result()`, `ArrayWatch:_harvest_finished_jobs()`, `ArrayWatch:_lane_schedulable()`, `ArrayWatch:_machine_order()`, `ArrayWatch:_max_job_attempts()`, `ArrayWatch:_max_parallel_lanes()`, `ArrayWatch:_remove_job()`, `ArrayWatch:_run_lane_dispatch()`, `ArrayWatch:_send_event()`, `ArrayWatch:_send_health()`, `ArrayWatch:step_central()`, `ArrayWatch:step_heartbeat()`, `ArrayWatch:step_lane()`, `ArrayWatch:step_scheduler()`, `ArrayWatch:step_watchdog()`, `ArrayWatch:tick()`, `array_watch.lua`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 18`** (16 nodes): `InterfaceStock:clear_fluid()`, `InterfaceStock:clear_interfaces()`, `InterfaceStock:clear_item()`, `InterfaceStock:_fluid_side()`, `InterfaceStock:_item_slot_limit()`, `InterfaceStock:_item_slot_start()`, `InterfaceStock.new()`, `InterfaceStock:_new_active()`, `InterfaceStock:_push_slot()`, `InterfaceStock:release_batch()`, `InterfaceStock:stock_batch()`, `InterfaceStock:stock_one_fluid()`, `InterfaceStock:stock_one_item()`, `InterfaceStock:wait_pull_ready()`, `stack_matches()`, `interface_stock.lua`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 30`** (6 nodes): `getRotorHolder()`, `metaMachineWrapper()`, `nullifyUndefined()`, `opt()`, `toInt()`, `greg_ex.js`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `print()` connect `Community 1` to `Community 17`, `Community 10`, `Community 4`, `Community 6`?**
  _High betweenness centrality (0.123) - this node is a cross-community bridge._
- **Why does `BrokerMain.run()` connect `Community 6` to `Community 17`, `Community 1`, `Community 14`?**
  _High betweenness centrality (0.090) - this node is a cross-community bridge._
- **Why does `BrokerMain.build()` connect `Community 6` to `Community 9`, `Community 18`?**
  _High betweenness centrality (0.070) - this node is a cross-community bridge._
- **Are the 24 inferred relationships involving `print()` (e.g. with `try()` and `log_sensor_lines()`) actually correct?**
  _`print()` has 24 INFERRED edges - model-reasoned connections that need verification._
- **Are the 6 inferred relationships involving `LaneWorker.execute()` (e.g. with `log()` and `LaneSides.bus_side()`) actually correct?**
  _`LaneWorker.execute()` has 6 INFERRED edges - model-reasoned connections that need verification._
- **Are the 12 inferred relationships involving `BrokerMain.run()` (e.g. with `print()` and `Protocols.parse()`) actually correct?**
  _`BrokerMain.run()` has 12 INFERRED edges - model-reasoned connections that need verification._
- **Are the 11 inferred relationships involving `HW.require_proxy()` (e.g. with `CentralDispatch:_descriptor_iface()` and `CentralDispatch:_lane_item_tp()`) actually correct?**
  _`HW.require_proxy()` has 11 INFERRED edges - model-reasoned connections that need verification._