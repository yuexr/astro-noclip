![Noclip Collision Toggle](./img/noclip-banner.png)

# 👻 Noclip Collision Toggle 👻

Fly through terrain! Easy console-command toggle to pass through terrain & objects during flight mode without being ejected, while also preventing wonky camera adjustments/repositioning.

Impacts collision only while in EVA or creative flight mode.

Multiplayer tested.

## Installation

Vortex or AstroModLoader-Classic installation recommended.

[Please see detailed installation guide here.](https://yuexr.github.io/astro/mods/installation.html)

UE4SS (and UE4SS ConsoleCommandsMod) required. Both automatically installed through instructions above.

**Multiplayer:** This is a client-side mod. 
Fine to use in multiplayer; mod only impacts user behaviour, regardless of whether or not the host/other guests have the mod.

## Noclip Toggle

Noclip is OFF by default.

> [!NOTE]  
> **Use EVA or creative flight mode to pass through terrain.**  
> Walking still collides with terrain, even with noclip enabled.

Press F10 (or tilde key) once to open the console input field or twice to see the full console.

Available commands:
```
noclip on
noclip off
noclip status
```
![Noclip Collision Toggle Commands](./img/noclip-commands.png)

> [!CAUTION]  
> If Noclip is switched to OFF while in terrain, or if Noclip is ON and player switches to walk mode while in terrain, expect normal game handling to occur upon which player is ejected upwards until no longer colliding with terrain. Be careful, can cause player fall damage!

Noclip resets to OFF when the game is restarted.

---

Uses [MinHook](https://github.com/TsudaKageyu/minhook). License included.
