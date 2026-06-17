# Graph Report - AutoOS  (2026-06-16)

## Corpus Check
- 123 files · ~75,984 words
- Verdict: corpus is large enough that graph structure adds value.

## Summary
- 680 nodes · 790 edges · 19 communities detected
- Extraction: 92% EXTRACTED · 8% INFERRED · 0% AMBIGUOUS · INFERRED: 67 edges (avg confidence: 0.8)
- Token cost: 0 input · 0 output

## Community Hubs (Navigation)
- [[_COMMUNITY_Community 0|Community 0]]
- [[_COMMUNITY_Community 2|Community 2]]
- [[_COMMUNITY_Community 3|Community 3]]
- [[_COMMUNITY_Community 4|Community 4]]
- [[_COMMUNITY_Community 6|Community 6]]
- [[_COMMUNITY_Community 7|Community 7]]
- [[_COMMUNITY_Community 8|Community 8]]
- [[_COMMUNITY_Community 10|Community 10]]
- [[_COMMUNITY_Community 11|Community 11]]
- [[_COMMUNITY_Community 12|Community 12]]
- [[_COMMUNITY_Community 14|Community 14]]
- [[_COMMUNITY_Community 16|Community 16]]
- [[_COMMUNITY_Community 17|Community 17]]
- [[_COMMUNITY_Community 19|Community 19]]
- [[_COMMUNITY_Community 22|Community 22]]
- [[_COMMUNITY_Community 23|Community 23]]
- [[_COMMUNITY_Community 24|Community 24]]
- [[_COMMUNITY_Community 27|Community 27]]
- [[_COMMUNITY_Community 28|Community 28]]

## God Nodes (most connected - your core abstractions)
1. `clean()` - 13 edges
2. `BrokerMain.run()` - 12 edges
3. `pcallR()` - 11 edges
4. `OrchestratorMain.build()` - 8 edges
5. `HW.require_proxy()` - 7 edges
6. `cmd_listen()` - 7 edges
7. `cmd_ping()` - 7 edges
8. `num()` - 7 edges
9. `Kernel.new()` - 6 edges
10. `modem_list()` - 6 edges

## Surprising Connections (you probably didn't know these)
- `build_oc_deps()` --calls--> `component.isAvailable()`  [INFERRED]
  legacy\main.lua → references\OC-GTNH-docs-main\docs\component.lua
- `Protocols.parse()` --calls--> `Orchestrator:on_message()`  [INFERRED]
  subnet_broker\network_protocols.lua → orchestrator\orchestrator.lua
- `BrokerMain.run()` --calls--> `MachinePoll.new()`  [INFERRED]
  subnet_broker\broker_main.lua → subnet_broker\machine_poll.lua
- `Adapter.new()` --calls--> `Kernel.new()`  [INFERRED]
  legacy\adapter.lua → legacy\main.lua
- `Arbitrator.new()` --calls--> `Kernel.new()`  [INFERRED]
  legacy\arbitrator.lua → legacy\main.lua

## Communities

### Community 0 - "Community 0"
Cohesion: 0.04
Nodes (33): CircuitManager:scan_transposer(), CircuitManager:_transfer_with_retries(), find_machine(), component.list(), HW.on_network(), HW.proxy(), HW.require_proxy(), HW.sleep() (+25 more)

### Community 2 - "Community 2"
Cohesion: 0.05
Nodes (17): ConnectedPeripherals:_checkPeripherals(), ConnectedPeripherals:hasFluidsInInput(), ConnectedPeripherals:hasItemsInInput(), ConnectedPeripherals:pushFluids(), ConnectedPeripherals:pushItems(), findFileRecursive(), FormatTable(), isTableEmpty() (+9 more)

### Community 3 - "Community 3"
Cohesion: 0.06
Nodes (8): Display.new(), Display:render(), on_off(), yes_no(), gpu.bind(), gpu.getResolution(), gpu.maxResolution(), gpu.setResolution()

### Community 4 - "Community 4"
Cohesion: 0.07
Nodes (14): ArrayWatch.new(), BrokerMain.run(), component.isAvailable(), Config.validate(), normalize_machine(), LaneDispatch.new(), me_proxy(), modem.broadcast() (+6 more)

### Community 6 - "Community 6"
Cohesion: 0.08
Nodes (9): Adapter.new(), Arbitrator:commit(), Arbitrator:_craft_slot_available(), Arbitrator.new(), machine_idle(), select_intent(), Kernel.new(), ProcessControl.new() (+1 more)

### Community 7 - "Community 7"
Cohesion: 0.24
Nodes (16): ArrayWatch:_send_event(), ArrayWatch:_send_health(), clean(), num(), Protocols.broker_event(), Protocols.broker_health(), Protocols.broker_status(), Protocols.craft_ack() (+8 more)

### Community 8 - "Community 8"
Cohesion: 0.14
Nodes (10): CircuitManager.new(), bold(), check(), color(), green(), make_fixture(), new_fluid_tp(), new_item_tp() (+2 more)

### Community 10 - "Community 10"
Cohesion: 0.25
Nodes (9): event.pull(), cmd_info(), cmd_listen(), cmd_ping(), get_modem(), modem_list(), open_ports(), print_rx() (+1 more)

### Community 11 - "Community 11"
Cohesion: 0.28
Nodes (10): Adapter:poll(), Adapter:poll_inventory(), detect_power_loss(), find_fluid(), parse_eu_pair(), parse_eu_rate(), parse_eu_usage_from_sensor(), parse_stored_eu_from_sensor() (+2 more)

### Community 12 - "Community 12"
Cohesion: 0.27
Nodes (10): filter_match(), Mock.new(), bold(), check(), color(), dim(), green(), pc_rm_kernel() (+2 more)

### Community 14 - "Community 14"
Cohesion: 0.24
Nodes (8): build_oc_deps(), Kernel:_display_key(), Kernel:log_tick(), Kernel:state_changed(), Kernel:tick(), log_sensor_lines(), sensor_line_noisy(), stable_craft_reason()

### Community 16 - "Community 16"
Cohesion: 0.21
Nodes (7): MachinePoll:build_idle_pool(), MachinePoll.is_idle(), MachinePoll.new(), MachinePoll:poll_machine(), MaintenanceParse.has_fault(), problems_count(), strip_format()

### Community 17 - "Community 17"
Cohesion: 0.31
Nodes (6): bold(), check(), color(), dim(), green(), red()

### Community 19 - "Community 19"
Cohesion: 0.42
Nodes (6): bold(), check(), color(), dim(), green(), red()

### Community 22 - "Community 22"
Cohesion: 0.62
Nodes (6): bold(), check(), color(), dim(), green(), red()

### Community 23 - "Community 23"
Cohesion: 0.38
Nodes (3): AE2.requestFluid(), AE2.requestItem(), getCraftableForItem()

### Community 24 - "Community 24"
Cohesion: 0.4
Nodes (2): nullifyUndefined(), opt()

### Community 27 - "Community 27"
Cohesion: 0.67
Nodes (5): bold(), check(), color(), green(), red()

### Community 28 - "Community 28"
Cohesion: 0.7
Nodes (4): Maintenance.evaluate(), Maintenance.has_fault(), problems_count(), strip_format()

## Knowledge Gaps
- **Thin community `Community 24`** (6 nodes): `getRotorHolder()`, `metaMachineWrapper()`, `nullifyUndefined()`, `opt()`, `toInt()`, `greg_ex.js`
  Too small to be a meaningful cluster - may be noise or needs more connections extracted.

## Suggested Questions
_Questions this graph is uniquely positioned to answer:_

- **Why does `BrokerMain.run()` connect `Community 4` to `Community 16`, `Community 8`, `Community 10`, `Community 7`?**
  _High betweenness centrality (0.071) - this node is a cross-community bridge._
- **Why does `component.isAvailable()` connect `Community 4` to `Community 0`, `Community 10`, `Community 14`?**
  _High betweenness centrality (0.053) - this node is a cross-community bridge._
- **Why does `Kernel.new()` connect `Community 6` to `Community 12`, `Community 14`?**
  _High betweenness centrality (0.043) - this node is a cross-community bridge._
- **Are the 11 inferred relationships involving `BrokerMain.run()` (e.g. with `Config.validate()` and `component.isAvailable()`) actually correct?**
  _`BrokerMain.run()` has 11 INFERRED edges - model-reasoned connections that need verification._
- **Are the 6 inferred relationships involving `OrchestratorMain.build()` (e.g. with `Config.validate()` and `component.isAvailable()`) actually correct?**
  _`OrchestratorMain.build()` has 6 INFERRED edges - model-reasoned connections that need verification._
- **Are the 3 inferred relationships involving `HW.require_proxy()` (e.g. with `CircuitManager:scan_transposer()` and `LaneDispatch:_item_tp()`) actually correct?**
  _`HW.require_proxy()` has 3 INFERRED edges - model-reasoned connections that need verification._
- **Should `Community 0` be split into smaller, more focused modules?**
  _Cohesion score 0.04 - nodes in this community are weakly interconnected._