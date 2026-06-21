# Graph Report - AutoOS  (2026-06-20)

## Corpus Check
- 144 files · ~119,096 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 1047 nodes · 1417 edges · 30 communities detected
- Extraction: 86% EXTRACTED · 14% INFERRED · 0% AMBIGUOUS · INFERRED: 203 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Community 0|Community 0]]
- [[_COMMUNITY_Community 1|Community 1]]
- [[_COMMUNITY_Community 2|Community 2]]
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
- [[_COMMUNITY_Community 16|Community 16]]
- [[_COMMUNITY_Community 18|Community 18]]
- [[_COMMUNITY_Community 20|Community 20]]
- [[_COMMUNITY_Community 21|Community 21]]
- [[_COMMUNITY_Community 23|Community 23]]
- [[_COMMUNITY_Community 24|Community 24]]
- [[_COMMUNITY_Community 26|Community 26]]
- [[_COMMUNITY_Community 29|Community 29]]
- [[_COMMUNITY_Community 30|Community 30]]
- [[_COMMUNITY_Community 31|Community 31]]
- [[_COMMUNITY_Community 32|Community 32]]
- [[_COMMUNITY_Community 35|Community 35]]
- [[_COMMUNITY_Community 36|Community 36]]
- [[_COMMUNITY_Community 37|Community 37]]
- [[_COMMUNITY_Community 38|Community 38]]
- [[_COMMUNITY_Community 39|Community 39]]

## God Nodes (most connected - your core abstractions)
1. `print()` - 31 edges
2. `LaneWorker.execute()` - 17 edges
3. `BrokerMain.build()` - 16 edges
4. `BrokerMain.run()` - 16 edges
5. `HW.require_proxy()` - 15 edges
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
Nodes (46): CentralDispatch:_machine_available(), CentralDispatch:_return_empty(), _build_steps(), lane_default(), LaneDispatch:_buffer_has_fluid(), LaneDispatch:_buffer_has_items(), LaneDispatch:_fluid_drained(), LaneDispatch:_fluid_pull_side() (+38 more)

### Community 1 - "Community 1"
Cohesion: 0.05
Nodes (39): CentralDispatch:_lane_item_tp(), CircuitManager:scan_transposer(), find_machine(), try(), clear_all(), join(), list_lua(), main() (+31 more)

### Community 2 - "Community 2"
Cohesion: 0.05
Nodes (27): CentralDispatch:_descriptor_iface(), CentralDispatch:_fluid_adapter(), CentralDispatch:_item_adapter(), CentralDispatch:_lane_fluid_tp(), CircuitManager:_transfer_with_retries(), component.list(), DescriptorCache:_db(), HW.clear_proxy_cache() (+19 more)

### Community 4 - "Community 4"
Cohesion: 0.06
Nodes (17): ConnectedPeripherals:_checkPeripherals(), ConnectedPeripherals:hasFluidsInInput(), ConnectedPeripherals:hasItemsInInput(), ConnectedPeripherals:pushFluids(), ConnectedPeripherals:pushItems(), findFileRecursive(), FormatTable(), isTableEmpty() (+9 more)

### Community 5 - "Community 5"
Cohesion: 0.07
Nodes (25): ArrayWatch.new(), boot(), BrokerMain.build(), BrokerMain._build_impl(), BrokerMain.run(), BrokerMain.run_once(), print_lane_status(), BrokerUI.new() (+17 more)

### Community 6 - "Community 6"
Cohesion: 0.05
Nodes (8): fingerprint_equal(), fingerprint_nonempty(), norm_fluid_label(), ROBDispatcher:_build_manifest(), ROBDispatcher:_fluids_from_central_tank(), ROBDispatcher.new(), ROBDispatcher:_step_buffer_monitor(), _stack_on_adapter()

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
Cohesion: 0.06
Nodes (6): CentralDispatch:_batch_manifest(), CentralDispatch:_bus_empty(), CentralDispatch:_fluids_from_central_tank(), CentralDispatch:tick(), fingerprint_equal(), _norm_fluid_label()

### Community 11 - "Community 11"
Cohesion: 0.11
Nodes (28): CentralDispatch:_fluid_level(), FluidTanks.buffer_empty(), FluidTanks.fluid_rows(), FluidTanks.label_matches(), FluidTanks.non_empty_tanks(), FluidTanks.tank_capacity(), FluidTanks.tank_level(), lower() (+20 more)

### Community 12 - "Community 12"
Cohesion: 0.1
Nodes (19): bold(), check(), color(), green(), make_fixture(), new_fluid_tp(), new_item_tp(), red() (+11 more)

### Community 14 - "Community 14"
Cohesion: 0.22
Nodes (16): clean(), num(), Protocols.broker_event(), Protocols.broker_health(), Protocols.broker_status(), Protocols.craft_ack(), Protocols.craft_done(), Protocols.craft_fail() (+8 more)

### Community 15 - "Community 15"
Cohesion: 0.13
Nodes (11): BrokerUI:run(), FG(), fmtag(), fmtt(), GS(), handle_config_key(), pad(), render_config() (+3 more)

### Community 16 - "Community 16"
Cohesion: 0.09
Nodes (2): ArrayWatch:_send_event(), ArrayWatch:_send_health()

### Community 18 - "Community 18"
Cohesion: 0.14
Nodes (8): BrokerMain.attach_tasks(), event_matches(), normalize_wait(), Scheduler:_dispatch_event(), Scheduler:_resume(), Scheduler.sleep(), Scheduler.wait_event(), Scheduler.yield_now()

### Community 20 - "Community 20"
Cohesion: 0.19
Nodes (7): MachinePoll:build_idle_pool(), MachinePoll.is_idle(), MachinePoll:poll_machine(), MachinePoll:refresh_proxies(), MaintenanceParse.has_fault(), problems_count(), strip_format()

### Community 21 - "Community 21"
Cohesion: 0.28
Nodes (12): CentralDispatch.new(), bold(), check(), color(), green(), make_fixture(), new_adapter(), new_fluid_adapter() (+4 more)

### Community 23 - "Community 23"
Cohesion: 0.31
Nodes (6): bold(), check(), color(), dim(), green(), red()

### Community 24 - "Community 24"
Cohesion: 0.58
Nodes (8): cmd_info(), cmd_listen(), cmd_ping(), get_modem(), modem_list(), open_ports(), print_rx(), resolve_mode()

### Community 26 - "Community 26"
Cohesion: 0.42
Nodes (6): bold(), check(), color(), dim(), green(), red()

### Community 29 - "Community 29"
Cohesion: 0.62
Nodes (6): bold(), check(), color(), dim(), green(), red()

### Community 30 - "Community 30"
Cohesion: 0.38
Nodes (3): AE2.requestFluid(), AE2.requestItem(), getCraftableForItem()

### Community 31 - "Community 31"
Cohesion: 0.52
Nodes (6): bold(), check(), color(), green(), make_sched(), red()

### Community 32 - "Community 32"
Cohesion: 0.4
Nodes (2): nullifyUndefined(), opt()

### Community 35 - "Community 35"
Cohesion: 0.67
Nodes (5): bold(), check(), color(), green(), red()

### Community 36 - "Community 36"
Cohesion: 0.67
Nodes (5): bold(), check(), color(), green(), red()

### Community 37 - "Community 37"
Cohesion: 0.67
Nodes (5): bold(), check(), color(), green(), red()

### Community 38 - "Community 38"
Cohesion: 0.67
Nodes (5): bold(), check(), color(), green(), red()

### Community 39 - "Community 39"
Cohesion: 0.7
Nodes (4): Maintenance.evaluate(), Maintenance.has_fault(), problems_count(), strip_format()

## Knowledge Gaps
- **Thin community `Community 16`** (22 nodes): `ArrayWatch:_active_job_count()`, `ArrayWatch:_advance_scheduler_rr()`, `ArrayWatch:any_fast_tick()`, `ArrayWatch:_handle_central_events()`, `ArrayWatch:_handle_fault()`, `ArrayWatch:handle_poll_result()`, `ArrayWatch:_harvest_finished_jobs()`, `ArrayWatch:_lane_schedulable()`, `ArrayWatch:_machine_order()`, `ArrayWatch:_max_job_attempts()`, `ArrayWatch:_max_parallel_lanes()`, `ArrayWatch:_remove_job()`, `ArrayWatch:_run_lane_dispatch()`, `ArrayWatch:_send_event()`, `ArrayWatch:_send_health()`, `ArrayWatch:step_central()`, `ArrayWatch:step_heartbeat()`, `ArrayWatch:step_lane()`, `ArrayWatch:step_scheduler()`, `ArrayWatch:step_watchdog()`, `ArrayWatch:tick()`, `array_watch.lua`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 32`** (6 nodes): `getRotorHolder()`, `metaMachineWrapper()`, `nullifyUndefined()`, `opt()`, `toInt()`, `greg_ex.js`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `print()` connect `Community 1` to `Community 4`, `Community 5`, `Community 11`, `Community 15`, `Community 18`, `Community 24`?**
  _High betweenness centrality (0.150) - this node is a cross-community bridge._
- **Why does `BrokerMain.run()` connect `Community 5` to `Community 1`, `Community 18`, `Community 14`?**
  _High betweenness centrality (0.105) - this node is a cross-community bridge._
- **Why does `BrokerMain.build()` connect `Community 5` to `Community 9`, `Community 2`?**
  _High betweenness centrality (0.067) - this node is a cross-community bridge._
- **Are the 27 inferred relationships involving `print()` (e.g. with `main()` and `try()`) actually correct?**
  _`print()` has 27 INFERRED edges - model-reasoned connections that need verification._
- **Are the 6 inferred relationships involving `LaneWorker.execute()` (e.g. with `log()` and `LaneSides.bus_side()`) actually correct?**
  _`LaneWorker.execute()` has 6 INFERRED edges - model-reasoned connections that need verification._
- **Are the 13 inferred relationships involving `BrokerMain.build()` (e.g. with `BrokerUIMain.start()` and `component.isAvailable()`) actually correct?**
  _`BrokerMain.build()` has 13 INFERRED edges - model-reasoned connections that need verification._
- **Are the 12 inferred relationships involving `BrokerMain.run()` (e.g. with `print()` and `Protocols.parse()`) actually correct?**
  _`BrokerMain.run()` has 12 INFERRED edges - model-reasoned connections that need verification._