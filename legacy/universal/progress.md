# Universal Experiment Progress Log

Append-only changelog for the `universal/` experiment (not root `progress.md`).

---

## 2026-06-10 — Initial capability-based broker experiment

- Added `universal/` tree: shared protocol + recipe registry, coordinator (stock watcher, broker client, main loop), broker (registry, dispatcher, adapter, executor, main loop)
- Capability dispatch: product → registry → machine_type + tools → idle multi
- Coordinator broadcasts `craft_req`; no product→broker routing in config
- Triple completion gate: AE done + machine idle + 15s grace
- Reserved `capability_advertise` in protocol (decode only)
- Desktop tests under `universal/tests/`

## 2026-06-10 — Quick setup guide in README

- Changed `universal/README.md`: added step-by-step in-game setup (hardware, UUIDs, registry, broker/coordinator config, verify)
