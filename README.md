# 🐜 Underfoot

> One ant. One backyard. One day, the whole house.

**Underfoot** is a 2D colony-building strategy game. You wake up as a lone queen ant in an abandoned suburban backyard and grow a single burrow into a 10,000-ant empire that eventually invades the house.

The yard is enormous at ant scale: the sprinkler is a flood, the barbecue is a volcano, the garden gnome is a mountain, and the cat is a god.

---

## The two views

| View | Perspective | What you do |
|---|---|---|
| **The Nest** | 2D side-on cross-section (ant-farm style) | Dig tunnels, build chambers, raise brood, manage air, water and temperature |
| **The Surface** | 2D top-down, zoomable lawn | Lay pheromone trails, forage, scout, fight, found satellite nests |

Press **Tab** to switch instantly. Both views simulate at the same time.

## Core loop

1. **Dig.** Carve tunnels through soil layers (loam, clay, sand, rock, roots). Moisture and soil type decide whether a wall holds.
2. **Raise.** The queen lays eggs. Feed larvae different diets to choose a caste: worker, soldier, scout, nurse, and later major, minim and specialist castes.
3. **Forage.** Ants follow pheromones, not orders. You paint, strengthen and erase scent trails, and the colony works out the rest.
4. **Defend.** Spiders, beetles, rival colonies, birds, rainstorms, the lawnmower.
5. **Expand.** Satellite nests across the yard, then the shed, the patio, and finally the house.
6. **Evolve.** Each new queen inherits traits. Pick mutations to shape your species.

## Key features

- **Emergent logistics.** Pheromone networks you keep optimising, like a factory game made of ants.
- **Living architecture.** Ventilation, drainage, temperature and mould. Bad design floods.
- **Seasons.** Spring boom, summer heat, autumn stockpiling, a winter siege underground. Each year is harder.
- **Evolution tree.** 40+ traits across 5 branches: Jaws, Chemistry, Agriculture, Architecture, Swarm.
- **The House.** A late-game indoor campaign with crumbs, wall cavities, the cat, and an escalating human AI that ends in an exterminator boss.
- **Field Guide.** 60+ backyard species to catalogue, befriend (aphids), farm (fungus) or tame (one beetle mount).
- **Sandbox and Campaign** modes, plus a seeded "Endless Yard".

## Tech

- **Engine:** Godot 4.3+ (GDScript), 2D only
- **Platforms:** Windows, macOS, Linux; Web export for demos
- **Target:** 10,000 simulated ants at 60 fps on a mid-range laptop

## Getting started

```bash
git clone https://github.com/SubToFeralsloth11/Underfoot.git
cd Underfoot
godot --path .            # once project.godot exists (see BUILD.md, Phase 0)
```

## Docs

- **[BUILD.md](BUILD.md)** — full build directions for the whole game, phase by phase, with systems specs, data formats, milestones and acceptance tests.

## Status

Pre-production. Nothing is built yet; start at **BUILD.md → Phase 0**.
