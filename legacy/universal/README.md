# Universal Craft Brokers (Experiment)

Isolated experiment for capability-based manufacturing dispatch. **Not** part of the main AutoOS kernel (`main.lua` at repo root).

## Architecture

```text
Product → recipe_registry.lua → machine_type + tools → idle multi → subnet ME craft
```

| Role | Network | Knows |
|------|---------|-------|
| **Coordinator** | Main ME | Stock bands, product names |
| **Broker** | Subnet ME | Machine capabilities, installed tools |
| **Recipe registry** | Shared file | How each product is made |

Coordinator broadcasts `craft_req` to all brokers. Brokers resolve routing locally. Coordinator never maps products to machines or brokers.

---

## Quick setup (in-game)

You need **two kinds of PC** (minimum one coordinator + one broker), plus an **ME bridge** so crafted items reach the main network.

### What you need

| PC | Cards / blocks | Network |
|----|----------------|---------|
| **Coordinator** | Network card, ME Interface or Controller | **Main** ME |
| **Broker** | Network card, ME Interface, Adapter per multiblock (or MFU) | **Subnet** ME (where patterns run) |

All PCs must share a **modem link** (wired cable or wireless). Modem port is **4410**.

### Step 1 — Copy files

Put the whole `universal/` folder on each computer:

```text
/home/universal/
  shared/
  coordinator/
  broker/
```

Use `wget` from your repo raw URLs, or copy from a floppy/USB.

### Step 2 — Wire the world

1. **Main ME** — coordinator ME adapter here (reads stock).
2. **Subnet ME** — broker ME adapter + AE patterns for your multis.
3. **ME bridge** — move crafted fluids/items from subnet → main (quantum bridge, interface pair, etc.).
4. **Modem** — coordinator and every broker on the same wired network (or wireless in range).
5. **Multiblocks** — each tower/reactor has an Adapter (or MFU → Adapter within 16 blocks).

### Step 3 — Find UUIDs

On each PC, run in the OC shell:

```lua
local c = require("component")
for addr, name in c.list() do print(name, addr) end
```

You need:

- Each **computer** address (for modem `brokers` list on coordinator).
- Each **gt_machine** address (for broker `multis` list).

### Step 4 — Recipe registry (once, shared file)

Edit `/home/universal/shared/recipe_registry.lua` — this is **how** each product is made:

```lua
Benzene = {
  machine_type = "distillation_tower",
  tools = { "Circuit24" },
},
```

- `machine_type` must match a string in the broker’s `capabilities`.
- `tools` must be listed in the chosen machine’s `installed_tools` (declarative only — you load the real circuits/molds in-game).

### Step 5 — Configure the broker PC

Edit `/home/universal/broker/start.lua`:

1. Set `broker_id` (unique name, e.g. `"dist_array_1"`).
2. Paste each multiblock UUID into `multis[].address`.
3. Set `capabilities` and `installed_tools` per machine (not product names).
4. Optional: pin `coordinator_addr = "<coordinator-computer-uuid>"`.

Boot the broker:

```lua
loadfile("/home/universal/broker/start.lua")()
```

Or set the computer’s startup to run that file.

### Step 6 — Configure the coordinator PC

Edit `/home/universal/coordinator/start.lua`:

1. Paste each broker **computer** UUID into `brokers[].address`.
2. Set `targets` — product name + stock bands only (no broker, no machine):

```lua
{ label = "Benzene", kind = "fluid", low = 8000, high = 32000, max_craft = 16000 },
```

`label` must match ME stock name **and** an entry in `recipe_registry.lua`.

Boot the coordinator:

```lua
loadfile("/home/universal/coordinator/start.lua")()
```

### Step 7 — Verify

1. Coordinator prints `[Universal] Coordinator started on port 4410`.
2. Broker prints `[Universal] Broker dist_array_1 started...`.
3. Drop main-net stock below `low` for a configured product.
4. Coordinator logs `craft_req`; broker logs `ack` then `done` after the job finishes.
5. Stock on **main** ME rises after the bridge delivers output.

### Adding a new product later

1. Add entry to `shared/recipe_registry.lua`.
2. Add AE pattern on the **subnet** interface.
3. Add a `targets` row on the coordinator (stock bands only).
4. Ensure some broker machine has the right `capabilities` + `installed_tools`.

You do **not** assign products to brokers or machines in the coordinator config.

---

## Folder layout

```text
universal/
├── shared/
│   ├── protocol.lua
│   └── recipe_registry.lua
├── coordinator/
│   ├── start.lua
│   ├── main.lua
│   ├── stock_watcher.lua
│   └── broker_client.lua
├── broker/
│   ├── start.lua
│   ├── main.lua
│   ├── registry.lua
│   ├── dispatcher.lua
│   ├── adapter.lua
│   └── executor.lua
└── tests/
```

## In-game wiring

1. **Coordinator PC** — Network card, ME adapter on **main** net, files under `/home/universal/`.
2. **Broker PC(s)** — Network card, ME adapter on **subnet**, one `gt_machine` adapter (or MFU) per multi UUID.
3. **Modem link** — Wired or wireless between coordinator and all brokers (port `4410`).
4. **ME bridge** — Operator-built subnet → main transfer (quantum bridge, interface pair, etc.).
5. **Patterns** — AE autocraft patterns on subnet interfaces the broker ME proxy sees.

## Configuration

**Add products** in `shared/recipe_registry.lua`:

```lua
MyProduct = {
  machine_type = "distillation_tower",
  tools = { "Circuit24" },
},
```

**Coordinator** (`coordinator/start.lua`) — targets only:

```lua
{ label = "Benzene", kind = "fluid", low = 8000, high = 32000, max_craft = 16000 },
```

**Broker** (`broker/start.lua`) — capabilities per machine:

```lua
{
  id = "dist_tower_a",
  address = "<gt_machine-uuid>",
  capabilities = { "distillation_tower" },
  installed_tools = { "Circuit24", "TowerMold" },
},
```

## Completion semantics

Broker sends `craft_done` only when **all** are true:

1. AE crafting job finished (not failed/canceled)
2. `gt_machine` idle (`not hasWork`, `not isMachineActive`)
3. **15s grace** after AE job done (GT multiblocks may still process)

## Modem protocol (port 4410)

Pipe-delimited strings. See `shared/protocol.lua`.

| Message | Direction |
|---------|-----------|
| `craft_req` | Coordinator → brokers (broadcast) |
| `craft_ack` | Broker → coordinator |
| `craft_done` | Broker → coordinator |
| `craft_fail` | Broker → coordinator |
| `ping` / `pong` | Health check |
| `capability_advertise` | Reserved (decode only in v1) |

## Desktop tests

From repo root:

```bash
lua universal/tests/protocol_test.lua
lua universal/tests/recipe_registry_test.lua
lua universal/tests/dispatcher_test.lua
lua universal/tests/coordinator_broker_test.lua
```

## Limitations (v1)

- No live tool scanning or locking
- No `capability_advertise` discovery on coordinator
- Tools are declarative metadata only
- One active job per broker
- Not integrated with AutoOS Phase 1–4 kernel
