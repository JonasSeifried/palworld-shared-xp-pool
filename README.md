# Palworld Shared XP Pool

**Everyone in your world stays at the same level.**

Go off and do your own thing -- mine, build, hunt, explore -- and nobody falls
behind. Come back after a week away and you are level with everyone else.
Somebody joining your world for the first time starts where you are, not at
level 1.

It does not invent XP. The world progresses at the pace of whoever is doing
best, and everybody shares that pace. Playing side by side still works exactly
like vanilla; the job is making sure that *splitting up* costs nobody their
progress.

## Two parts

|  |  |
|---|---|
| **[mod/](mod/)** | The Palworld mod. Holds every connected player at the same XP total while you play. **This is the thing you install.** |
| **[save-editor/](save-editor/)** | A Python tool that converges a world once, offline. For worlds the mod has never run on, for repairs, or if you want the group average rather than the top. |

You do not need the save editor to use the mod.

## Installing the mod

On the **host's** machine only -- Palworld decides XP server-side, so joining
players need nothing.

Take `SharedXPPool-<version>.zip` from a [release](../../releases) and extract
it over your Palworld folder; it covers every UE4SS layout, so there is no Mods
folder to find. To work on the mod instead, junction it into the game:

```powershell
.\tools\install_ue4ss.ps1 -Dev
.\tools\link_mod.ps1
```

Full instructions, settings and the honest list of what it does not do are in
[mod/README.md](mod/README.md).

## Testing

```
lua mod/tests/test_pool.lua
```

The save editor's suite is separate; see [save-editor/](save-editor/). Both run
on every push, and tagging `v*` builds the release archives -- see
[.github/workflows/](.github/workflows/) and [mod/PUBLISHING.md](mod/PUBLISHING.md).

## Licence

MIT. See [LICENSE](LICENSE).
