# Graph Report - AutoOS  (2026-06-17)

## Corpus Check
- 129 files · ~87,613 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 800 nodes · 1003 edges · 23 communities detected
- Extraction: 88% EXTRACTED · 12% INFERRED · 0% AMBIGUOUS · INFERRED: 125 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Community 0|Community 0]]
- [[_COMMUNITY_Community 2|Community 2]]
- [[_COMMUNITY_Community 3|Community 3]]
- [[_COMMUNITY_Community 4|Community 4]]
- [[_COMMUNITY_Community 5|Community 5]]
- [[_COMMUNITY_Community 6|Community 6]]
- [[_COMMUNITY_Community 7|Community 7]]
- [[_COMMUNITY_Community 9|Community 9]]
- [[_COMMUNITY_Community 10|Community 10]]
- [[_COMMUNITY_Community 11|Community 11]]
- [[_COMMUNITY_Community 12|Community 12]]
- [[_COMMUNITY_Community 14|Community 14]]
- [[_COMMUNITY_Community 15|Community 15]]
- [[_COMMUNITY_Community 16|Community 16]]
- [[_COMMUNITY_Community 19|Community 19]]
- [[_COMMUNITY_Community 20|Community 20]]
- [[_COMMUNITY_Community 21|Community 21]]
- [[_COMMUNITY_Community 23|Community 23]]
- [[_COMMUNITY_Community 26|Community 26]]
- [[_COMMUNITY_Community 27|Community 27]]
- [[_COMMUNITY_Community 28|Community 28]]
- [[_COMMUNITY_Community 31|Community 31]]
- [[_COMMUNITY_Community 32|Community 32]]

## God Nodes (most connected - your core abstractions)
1. `print()` - 23 edges
2. `BrokerMain.run()` - 15 edges
3. `BrokerMain.build()` - 14 edges
4. `clean()` - 13 edges
5. `HW.require_proxy()` - 11 edges
6. `pcallR()` - 11 edges
7. `run_probe_embedded()` - 9 edges
8. `cmd_listen()` - 8 edges
9. `cmd_ping()` - 8 edges
10. `OrchestratorMain.build()` - 8 edges

## Surprising Connections (you probably didn't know these)
- `build_oc_deps()` --calls--> `component.isAvailable()`  [INFERRED]
  legacy\main.lua → references\OC-GTNH-docs-main\docs\component.lua
- `Protocols.parse()` --calls--> `Orchestrator:on_message()`  [INFERRED]
  subnet_broker\network_protocols.lua → orchestrator\orchestrator.lua
- `BrokerMain.build()` --calls--> `InterfaceStock.new()`  [INFERRED]
  subnet_broker\broker_main.lua → subnet_broker\interface_stock.lua
- `Adapter.new()` --calls--> `Kernel.new()`  [INFERRED]
  legacy\adapter.lua → legacy\main.lua
- `Arbitrator.new()` --calls--> `Kernel.new()`  [INFERRED]
  legacy\arbitrator.lua → legacy\main.lua

## Communities

### Community 0 - "Community 0"
Cohesion: 0.06
Nodes (35): CentralDispatch:_lane_item_tp(), CircuitManager:scan_transposer(), find_machine(), try(), clear_all(), join(), list_lua(), main() (+27 more)

### Community 2 - "Community 2"
Cohesion: 0.06
Nodes (17): ConnectedPeripherals:_checkPeripherals(), ConnectedPeripherals:hasFluidsInInput(), ConnectedPeripherals:hasItemsInInput(), ConnectedPeripherals:pushFluids(), ConnectedPeripherals:pushItems(), findFileRecursive(), FormatTable(), isTableEmpty() (+9 more)

### Community 3 - "Community 3"
Cohesion: 0.06
Nodes (24): CentralDispatch:_bus_empty(), CentralDispatch:_machine_available(), CentralDispatch:_return_empty(), lane_default(), LaneDispatch:_buffer_has_fluid(), LaneDispatch:_buffer_has_items(), LaneDispatch:_fluid_drained(), LaneDispatch:_fluid_pull_side() (+16 more)

### Community 4 - "Community 4"
Cohesion: 0.06
Nodes (8): Display.new(), Display:render(), on_off(), yes_no(), gpu.bind(), gpu.getResolution(), gpu.maxResolution(), gpu.setResolution()

### Community 5 - "Community 5"
Cohesion: 0.08
Nodes (20): ArrayWatch.new(), BrokerMain.build(), BrokerMain.run(), BrokerMain.run_once(), print_lane_status(), CircuitManager.new(), component.isAvailable(), Config.validate() (+12 more)

### Community 6 - "Community 6"
Cohesion: 0.06
Nodes (14): CentralDispatch:_item_adapter(), CentralDispatch:_lane_fluid_tp(), CircuitManager:_transfer_with_retries(), component.list(), DescriptorCache:_db(), HW.on_network(), HW.proxy(), HW.require_proxy() (+6 more)

### Community 7 - "Community 7"
Cohesion: 0.08
Nodes (11): DescriptorCache:_find_fluid_drop(), DescriptorCache.new(), entry_is_fluid_drop(), entry_is_item(), lower(), bold(), check(), color() (+3 more)

### Community 9 - "Community 9"
Cohesion: 0.08
Nodes (9): Adapter.new(), Arbitrator:commit(), Arbitrator:_craft_slot_available(), Arbitrator.new(), machine_idle(), select_intent(), Kernel.new(), ProcessControl.new() (+1 more)

### Community 10 - "Community 10"
Cohesion: 0.22
Nodes (16): ArrayWatch:_send_event(), ArrayWatch:_send_health(), clean(), num(), Protocols.broker_event(), Protocols.broker_health(), Protocols.broker_status(), Protocols.craft_ack() (+8 more)

### Community 11 - "Community 11"
Cohesion: 0.09
Nodes (2): CentralDispatch:tick(), fingerprint_equal()

### Community 12 - "Community 12"
Cohesion: 0.15
Nodes (9): bold(), check(), color(), green(), make_fixture(), new_fluid_tp(), new_item_tp(), red() (+1 more)

### Community 14 - "Community 14"
Cohesion: 0.25
Nodes (9): event.pull(), cmd_info(), cmd_listen(), cmd_ping(), get_modem(), modem_list(), open_ports(), print_rx() (+1 more)

### Community 15 - "Community 15"
Cohesion: 0.28
Nodes (10): Adapter:poll(), Adapter:poll_inventory(), detect_power_loss(), find_fluid(), parse_eu_pair(), parse_eu_rate(), parse_eu_usage_from_sensor(), parse_stored_eu_from_sensor() (+2 more)

### Community 16 - "Community 16"
Cohesion: 0.27
Nodes (10): filter_match(), Mock.new(), bold(), check(), color(), dim(), green(), pc_rm_kernel() (+2 more)

### Community 19 - "Community 19"
Cohesion: 0.3
Nodes (11): CentralDispatch.new(), bold(), check(), color(), green(), make_fixture(), new_adapter(), new_fluid_tp() (+3 more)

### Community 20 - "Community 20"
Cohesion: 0.31
Nodes (6): bold(), check(), color(), dim(), green(), red()

### Community 21 - "Community 21"
Cohesion: 0.24
Nodes (6): MachinePoll:build_idle_pool(), MachinePoll.is_idle(), MachinePoll:poll_machine(), MaintenanceParse.has_fault(), problems_count(), strip_format()

### Community 23 - "Community 23"
Cohesion: 0.42
Nodes (6): bold(), check(), color(), dim(), green(), red()

### Community 26 - "Community 26"
Cohesion: 0.62
Nodes (6): bold(), check(), color(), dim(), green(), red()

### Community 27 - "Community 27"
Cohesion: 0.38
Nodes (3): AE2.requestFluid(), AE2.requestItem(), getCraftableForItem()

### Community 28 - "Community 28"
Cohesion: 0.4
Nodes (2): nullifyUndefined(), opt()

### Community 31 - "Community 31"
Cohesion: 0.67
Nodes (5): bold(), check(), color(), green(), red()

### Community 32 - "Community 32"
Cohesion: 0.7
Nodes (4): Maintenance.evaluate(), Maintenance.has_fault(), problems_count(), strip_format()

## Knowledge Gaps
- **Thin community `Community 11`** (24 nodes): `CentralDispatch:_adapter_side()`, `CentralDispatch:_advance_rr_after_assign()`, `CentralDispatch:any_fast_tick()`, `CentralDispatch:_batch_manifest()`, `CentralDispatch:_central_admission_ok()`, `CentralDispatch:_central_cfg()`, `CentralDispatch:_chest_start()`, `CentralDispatch:_count_circuits()`, `CentralDispatch:find_available_machine_rr()`, `CentralDispatch:find_handoff_target_rr()`, `CentralDispatch:_fingerprint_nonempty()`, `CentralDispatch:_fluid_level()`, `CentralDispatch:get_debug()`, `CentralDispatch:_item_fingerprint()`, `CentralDispatch:_reset_stabilizing()`, `CentralDispatch:_slot_count()`, `CentralDispatch:_slot_count_on_adapter()`, `CentralDispatch:_slot_size()`, `CentralDispatch:_slot_size_on_adapter()`, `CentralDispatch:_stabilize_s()`, `CentralDispatch:_stack_on_adapter()`, `CentralDispatch:tick()`, `fingerprint_equal()`, `central_dispatch.lua`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.
- **Thin community `Community 28`** (6 nodes): `getRotorHolder()`, `metaMachineWrapper()`, `nullifyUndefined()`, `opt()`, `toInt()`, `greg_ex.js`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `print()` connect `Community 0` to `Community 2`, `Community 5`, `Community 14`?**
  _High betweenness centrality (0.118) - this node is a cross-community bridge._
- **Why does `BrokerMain.run()` connect `Community 5` to `Community 0`, `Community 10`, `Community 14`?**
  _High betweenness centrality (0.099) - this node is a cross-community bridge._
- **Why does `Kernel.new()` connect `Community 9` to `Community 0`, `Community 16`?**
  _High betweenness centrality (0.059) - this node is a cross-community bridge._
- **Are the 19 inferred relationships involving `print()` (e.g. with `try()` and `log_sensor_lines()`) actually correct?**
  _`print()` has 19 INFERRED edges - model-reasoned connections that need verification._
- **Are the 12 inferred relationships involving `BrokerMain.run()` (e.g. with `print()` and `event.pull()`) actually correct?**
  _`BrokerMain.run()` has 12 INFERRED edges - model-reasoned connections that need verification._
- **Are the 11 inferred relationships involving `BrokerMain.build()` (e.g. with `Config.validate()` and `component.isAvailable()`) actually correct?**
  _`BrokerMain.build()` has 11 INFERRED edges - model-reasoned connections that need verification._
- **Are the 7 inferred relationships involving `HW.require_proxy()` (e.g. with `CentralDispatch:_lane_item_tp()` and `CentralDispatch:_lane_fluid_tp()`) actually correct?**
  _`HW.require_proxy()` has 7 INFERRED edges - model-reasoned connections that need verification._