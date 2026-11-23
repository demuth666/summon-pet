# Summon Pet

Roblox automation script for **Summon a Pet Army**, built with [BPUI](https://github.com/bypasshubpremium/BPUINEW).

## Features

- Zone and multi-rarity selection
- Auto Farm with pad-based zone travel
- Streaming detection and wild-pet rendering
- Follower catch-up check before punching
- Auto Summon using the game's summon remote
- Auto Equip Best
- Night-cycle pause and return-home handling
- Home wait for the next spawn-cycle announcement (adjustable in the UI)
- Automatic drumming at home while waiting for the next cycle
- Announcement matching for selected zones and rarities
- Cross-zone announcement sniping: matching rarities are chased into whatever zone they spawned
- Anti-AFK keepalive toggle in the Settings tab

## Usage

1. Join **Summon a Pet Army**.
2. Execute `PetArmyZonePunch.luau` with your executor.
3. In the **Main** tab, select a zone and one or more rarities.
4. Enable **Auto Farm**, **Auto Summon**, and/or **Auto Equip Best**.
5. Keep **Snipe Matching Announcements** enabled to automatically travel to a matching rarity's zone.

## Notes

- The script uses game remotes and may break when the game updates.
- Use at your own risk.
