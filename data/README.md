# Synthetic wind-turbine fleet digital twin

A neutral, **fully synthetic** demo dataset for the private Neo4j. Everything is
invented by [`generate.py`](generate.py) — a fictional operator (*Aeolus
Renewables*), fictional turbine models, generated serials, and simulated
sensor/maintenance data. **No real companies, products, people, or customer
data.** Swap in a real schema later without touching the infrastructure.

## Generate

```bash
uv run data/generate.py     # writes data/seed.cypher (deterministic; fixed seed)
```

The seed is a single self-contained `.cypher` file (schema constraints + batched
`UNWIND` inserts) — no external CSVs — loadable with `cypher-shell -f seed.cypher`.
`load-data.sh` runs it on the private Neo4j VM through Azure Run Command.

## Graph model

```text
(:Site) <-[:LOCATED_AT]- (:Turbine) -[:HAS_SYSTEM]-> (:System)
(:System) -[:HAS_COMPONENT]-> (:Component)
(:System) -[:HAS_SENSOR]->   (:Sensor) -[:GENERATES]-> (:Reading)
(:Component) -[:HAS_EVENT]-> (:MaintenanceEvent) -[:AFFECTS]-> (:Turbine)
```

| Label | Count | Notes |
| --- | --- | --- |
| Turbine | 24 | model, operator, rated_power_mw, commissioned_year |
| System | 96 | Rotor / Drivetrain / Generator / YawSystem |
| Component | 288 | blades, gearbox, bearings, … |
| Sensor | 120 | GearboxTemp, Vibration, RotorRPM, PowerOutput, WindSpeed |
| Reading | 28,800 | 30 days, sampled every 3h; mild degradation trend |
| Site | 4 | fictional wind-farm locations |
| MaintenanceEvent | 180 | fault, severity, corrective_action |

Tune scale via the constants at the top of `generate.py` (`FLEET_SIZE`, `DAYS`,
`READING_EVERY_HOURS`, `MAINT_EVENTS`).

## Example questions for the agent

- "Which turbines have the most high-severity maintenance events, and which
  components are involved?"
- "What's the average GearboxTemp per turbine model over the period?"
- "List turbines at the Kattegat Shoal site and their most recent faults."
