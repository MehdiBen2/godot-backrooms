# Godot Project: The Backrooms Recreation

> **CRITICAL CONTEXT FOR CLAUDE & AI ASSISTANTS**

This is the **Godot Engine recreation** of the Backrooms game.

---

## Project Structure & Paths

- **Current Active Project (Godot):**
  - **Path:** `c:/Users/alhyu/Documents/backrooms`
  - **Engine:** Godot Engine 4.x (`project.godot`)
  - **Key Directories:** `scenes/`, `scripts/`, `levels/`, `models/`, `textures/`, `audio/`
  - **Purpose:** Primary active development target for all gameplay, scenes, nodes, shaders, and GDScript code.

- **Legacy Reference Project (Three.js / Web):**
  - **Path:** `c:/Users/alhyu/Documents/GitHub/backrooms`
  - **Stack:** JavaScript, Three.js, Node.js (`server.js`)
  - **Purpose:** Reference repository containing the original gameplay logic, entity AI patterns, weapon systems (e.g. `crowbar.js`), level designs, and source assets.

---

## Guidelines for Development

1. **Recreation Target**: Implement gameplay, player controllers, camera mechanics, physics, and interactions using standard Godot 4 best practices and GDScript (`.gd`).
2. **Referencing Original Logic**: When porting features from the original web version, inspect `c:/Users/alhyu/Documents/GitHub/backrooms/` for the original logic, parameters, and asset files.
