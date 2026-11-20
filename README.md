# Rate Limiter

A mod for **Factorio 2.1** (Space Age supported, not required) that slows down any machine that produces something by a given percentage or down to a wanted output rate of one product: 100% is normal, 50% is half speed, 0% is stopped. Output, input, fuel, electricity and pollution scale together.

* Mod portal description (English and Russian): [docs/mod-portal-description.md](docs/mod-portal-description.md)
* In-game user guide (Russian): [rate-limiter/README.md](rate-limiter/README.md)

## Repository layout

    rate-limiter/              the mod itself (this folder goes into the archive)
        info.json              mod metadata, version
        changelog.txt          changelog shown in the game and on the mod portal
        data.lua               selection tool, shortcut, hotkey, alt-mode sprite
        settings.lua           map settings
        control.lua            events, commands
        scripts/
            types.lua          supported entity types, entity windows to attach the panel to
            limiter.lua        the limit itself: effects, pulses, scheduling, circuit reading
            rates.lua          what a machine makes and uses per second (products, inputs, fuel, power, emissions)
            persist.lua        blueprints, settings paste, ghosts, rebuild memory
            gui.lua            panel next to the machine window, selection tool dialog
            render.lua         alt-mode labels
        graphics/icons/        icons
        locale/en, locale/ru   translations
    tests/                     automated tests with Factorio API stubs
    tools/                     build scripts
    docs/                      texts and logo for the mod portal

## How the slowdown works

* **Machines with an effect receiver** (assembling machines, furnaces, mining drills, labs, rocket silo, agricultural tower) get `LuaEntity::local_effect` on speed and consumption (Factorio 2.1.13+). The mod measures the machine's own effect from modules and beacons and sets the local effect so that the total is exactly `limit × own`. Pollution follows power by itself. Productivity is untouched.
* The game clamps speed and consumption at −80% (×0.2). When `limit × own` is below that, the effect stays at ×0.2 and the machine also works in pulses for the remaining share.
* **Other machines** (boilers, generators, reactors, solar panels, offshore pumps, fusion, asteroid collectors) only work in pulses: `disabled_by_script` is on for part of every cycle. The fractional on-time is carried over between cycles, so the long-run share is exact even at 0.1%.
* **Rate mode** keeps a product and a wanted rate; on every re-check `rates.lua` computes the machine's maximum rate of that product (recipe, crafting/mining speed, modules, beacons, quality, productivity, resource yield) and the limit becomes `wanted / maximum`.
* If the game rounds the effect (0.01% resolution), the effect is rounded up and the remainder is taken off by rare pulses, so the result stays exact.
* If a machine does not take the effect (restricted recipe or machine), the mod falls back to pure pulses, which scale every quantity evenly.

## Building

The archive for the mods folder or the mod portal is written to `dist/` (not committed).

Windows:

    powershell -ExecutionPolicy Bypass -File tools/build.ps1

Linux / macOS:

    sh tools/build.sh

To install, copy `dist/rate-limiter_<version>.zip` to `%APPDATA%\Factorio\mods\`.

## Tests

The tests run the mod's logic outside the game against stubs of the Factorio API (Lua 5.2, the same version Factorio uses):

    lua5.2 tests/test.lua

They cover the effect and pulse math (average speed and power over many ticks), the effect floor, machines that refuse effects or cannot be switched off, blueprints, settings paste, rebuild memory, ghosts, the circuit network, the panel, the selection tool, alt-mode labels and the reset command. The stubs only imitate the game, so changes that touch the GUI or prototypes still need a check in Factorio.

## Debugging

`/rl-info` with the cursor over a machine prints its mode (`effect`, `mixed`, `duty`, `stopped`), the pulse share and the effect multipliers.
