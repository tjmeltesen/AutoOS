# Graph Report - AutoOS  (2026-06-20)

## Corpus Check
- 141 files · ~112,261 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 1008 nodes · 1353 edges · 28 communities detected
- Extraction: 86% EXTRACTED · 14% INFERRED · 0% AMBIGUOUS · INFERRED: 194 edges (avg confidence: 0.8)
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
- [[_COMMUNITY_Community 13|Community 13]]
- [[_COMMUNITY_Community 15|Community 15]]
- [[_COMMUNITY_Community 17|Community 17]]
- [[_COMMUNITY_Community 18|Community 18]]
- [[_COMMUNITY_Community 20|Community 20]]
- [[_COMMUNITY_Community 22|Community 22]]
- [[_COMMUNITY_Community 24|Community 24]]
- [[_COMMUNITY_Community 27|Community 27]]
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
2. `BrokerMain.run()` - 16 edges
3. `HW.require_proxy()` - 15 edges
4. `BrokerMain.build()` - 15 edges
5. `LaneWorker.execute()` - 15 edges
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
- `Protocols.parse()` --calls--> `Orchestrator:on_message()`  [INFERRED]
  subnet_broker\network_protocols.lua → orchestrator\orchestrator.lua
- `OUT:_write()` --calls--> `print()`  [INFERRED]
  references\cc_gtceu_multipurpose-main\multipurpose.lua → subnet_broker\find.lua
- `BrokerMain.build()` --calls--> `InterfaceStock.new()`  [INFERRED]
  subnet_broker\broker_main.lua → subnet_broker\interface_stock.lua

## Communities

### Community 0 - "Community 0"
Cohesion: 0.04
Nodes (44): CentralDispatch:_return_empty(), _build_steps(), lane_default(), LaneDispatch:_buffer_has_fluid(), LaneDispatch:_buffer_has_items(), LaneDispatch:_fluid_drained(), LaneDispatch:_fluid_pull_side(), LaneDispatch:handoff_from_central() (+36 more)

### Community 1 - "Community 1"
Cohesion: 0.06
Nodes (36): CentralDispatch:_lane_item_tp(), CircuitManager:scan_transposer(), find_machine(), try(), event.pull(), clear_all(), join(), list_lua() (+28 more)

### Community 2 - "Community 2"
Cohesion: 0.06
Nodes (34): ArrayWatch.new(), boot(), BrokerMain.build(), BrokerMain._build_impl(), BrokerMain.run(), BrokerMain.run_once(), print_lane_status(), CentralDispatch.new() (+26 more)

### Community 4 - "Community 4"
Cohesion: 0.05
Nodes (18): ConnectedPeripherals:_checkPeripherals(), ConnectedPeripherals:hasFluidsInInput(), ConnectedPeripherals:hasItemsInInput(), ConnectedPeripherals:pushFluids(), ConnectedPeripherals:pushItems(), findFileRecursive(), FormatTable(), isTableEmpty() (+10 more)

### Community 5 - "Community 5"
Cohesion: 0.05
Nodes (8): fingerprint_equal(), fingerprint_nonempty(), norm_fluid_label(), ROBDispatcher:_build_manifest(), ROBDispatcher:_fluids_from_central_tank(), ROBDispatcher.new(), ROBDispatcher:_step_buffer_monitor(), _stack_on_adapter()

### Community 6 - "Community 6"
Cohesion: 0.06
Nodes (8): Display.new(), Display:render(), on_off(), yes_no(), gpu.bind(), gpu.getResolution(), gpu.maxResolution(), gpu.setResolution()

### Community 7 - "Community 7"
Cohesion: 0.07
Nodes (19): Adapter.new(), Adapter:poll(), Adapter:poll_inventory(), detect_power_loss(), find_fluid(), parse_eu_pair(), parse_eu_rate(), parse_eu_usage_from_sensor() (+11 more)

### Community 8 - "Community 8"
Cohesion: 0.11
Nodes (16): ArrayWatch:_send_event(), ArrayWatch:_send_health(), clean(), num(), Protocols.broker_event(), Protocols.broker_health(), Protocols.broker_status(), Protocols.craft_ack() (+8 more)

### Community 9 - "Community 9"
Cohesion: 0.09
Nodes (25): CentralDispatch:_descriptor_iface(), CentralDispatch:_fluid_adapter(), CentralDispatch:_item_adapter(), CentralDispatch:_lane_fluid_tp(), CircuitManager:_transfer_with_retries(), component.list(), DescriptorCache:_db(), HW.on_network() (+17 more)

### Community 10 - "Community 10"
Cohesion: 0.07
Nodes (10): DescriptorCache.new(), entry_is_fluid_drop(), entry_is_item(), lower(), bold(), check(), color(), green() (+2 more)

### Community 11 - "Community 11"
Cohesion: 0.06
Nodes (6): CentralDispatch:_batch_manifest(), CentralDispatch:_bus_empty(), CentralDispatch:_fluids_from_central_tank(), CentralDispatch:tick(), fingerprint_equal(), _norm_fluid_label()

### Community 12 - "Community 12"
Cohesion: 0.11
Nodes (28): CentralDispatch:_fluid_level(), FluidTanks.buffer_empty(), FluidTanks.fluid_rows(), FluidTanks.label_matches(), FluidTanks.non_empty_tanks(), FluidTanks.tank_capacity(), FluidTanks.tank_level(), lower() (+20 more)

### Community 13 - "Community 13"
Cohesion: 0.1
Nodes (19): bold(), check(), color(), green(), make_fixture(), new_fluid_tp(), new_item_tp(), red() (+11 more)

### Community 15 - "Community 15"
Cohesion: 0.13
Nodes (9): BrokerMain.attach_tasks(), event_matches(), normalize_wait(), Scheduler:_dispatch_event(), Scheduler:_resume(), Scheduler.sleep(), Scheduler.wait_event(), Scheduler.yield_now() (+1 more)

### Community 17 - "Community 17"
Cohesion: 0.12
Nodes (1): InterfaceStock.new()

### Community 18 - "Community 18"
Cohesion: 0.18
Nodes (8): CentralDispatch:_machine_available(), MachinePoll:build_idle_pool(), MachinePoll.is_idle(), MachinePoll:poll_machine(), MachinePoll:refresh_proxies(), MaintenanceParse.has_fault(), problems_count(), strip_format()

### Community 20 - "Community 20"
Cohesion: 0.24
Nodes (8): build_oc_deps(), Kernel:_display_key(), Kernel:log_tick(), Kernel:state_changed(), Kernel:tick(), log_sensor_lines(), sensor_line_noisy(), stable_craft_reason()

### Community 22 - "Community 22"
Cohesion: 0.31
Nodes (6): bold(), check(), color(), dim(), green(), red()

### Community 24 - "Community 24"
Cohesion: 0.42
Nodes (6): bold(), check(), color(), dim(), green(), red()

### Community 27 - "Community 27"
Cohesion: 0.62
Nodes (6): bold(), check(), color(), dim(), green(), red()

### Community 28 - "Community 28"
Cohesion: 0.38
Nodes (3): AE2.requestFluid(), AE2.requestItem(), getCraftableForItem()

### Community 29 - "Community 29"
Cohesion: 0.52
Nodes (6): bold(), check(), color(), green(), make_sched(), red()

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
- **Thin community `Community 17`** (16 nodes): `InterfaceStock:clear_fluid()`, `InterfaceStock:clear_interfaces()`, `InterfaceStock:clear_item()`, `InterfaceStock:_fluid_side()`, `InterfaceStock:_item_slot_limit()`, `InterfaceStock:_item_slot_start()`, `InterfaceStock.new()`, `InterfaceStock:_new_active()`, `InterfaceStock:_push_slot()`, `InterfaceStock:release_batch()`, `InterfaceStock:stock_batch()`, `InterfaceStock:stock_one_fluid()`, `InterfaceStock:stock_one_item()`, `InterfaceStock:wait_pull_ready()`, `stack_matches()`, `interface_stock.lua`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 30`** (6 nodes): `getRotorHolder()`, `metaMachineWrapper()`, `nullifyUndefined()`, `opt()`, `toInt()`, `greg_ex.js`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `print()` connect `Community 1` to `Community 2`, `Community 4`, `Community 12`, `Community 15`, `Community 20`?**
  _High betweenness centrality (0.119) - this node is a cross-community bridge._
- **Why does `BrokerMain.run()` connect `Community 2` to `Community 8`, `Community 1`, `Community 15`?**
  _High betweenness centrality (0.090) - this node is a cross-community bridge._
- **Why does `BrokerMain.build()` connect `Community 2` to `Community 17`, `Community 10`?**
  _High betweenness centrality (0.070) - this node is a cross-community bridge._
- **Are the 24 inferred relationships involving `print()` (e.g. with `try()` and `log_sensor_lines()`) actually correct?**
  _`print()` has 24 INFERRED edges - model-reasoned connections that need verification._
- **Are the 12 inferred relationships involving `BrokerMain.run()` (e.g. with `print()` and `Protocols.parse()`) actually correct?**
  _`BrokerMain.run()` has 12 INFERRED edges - model-reasoned connections that need verification._
- **Are the 11 inferred relationships involving `HW.require_proxy()` (e.g. with `CentralDispatch:_descriptor_iface()` and `CentralDispatch:_lane_item_tp()`) actually correct?**
  _`HW.require_proxy()` has 11 INFERRED edges - model-reasoned connections that need verification._
- **Are the 12 inferred relationships involving `BrokerMain.build()` (e.g. with `component.isAvailable()` and `modem.open()`) actually correct?**
  _`BrokerMain.build()` has 12 INFERRED edges - model-reasoned connections that need verification._