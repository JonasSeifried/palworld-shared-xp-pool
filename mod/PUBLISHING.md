# Publishing

Two places, one source. Tag a release and the archives both come out of CI.

```bash
git tag v1.0.0 && git push origin v1.0.0
```

That runs the tests, and only if they pass builds two archives and publishes
them on the GitHub release:

| | |
|---|---|
| `SharedXPPool-<version>.zip` | For Nexus and manual installs. Extracts over the Palworld folder and covers every UE4SS layout. |
| `SharedXPPool-<version>-workshop.zip` | The Steam Workshop payload. `Scripts/` only, no `enabled.txt`. Not for players. |

To check the archives without committing to a version, run the release
workflow manually with a version, or build them locally:

```bash
python tools/build_release.py 1.0.0
```

[`tools/build_release.py`](../tools/build_release.py) explains what goes in
each one and why.

## Nexus

Page text is [`nexus-description.bbcode`](nexus-description.bbcode). Upload
`SharedXPPool-<version>.zip` as the main file.

- **Category:** Gameplay. It is what the mod changes. *Scripts* describes the
  implementation rather than the effect, and buries it from anyone searching
  for shared XP; *Utilities* is for tools like save editors.
- **Requirements:** use *Mod requirements (legacy)*, not file-to-file. The
  dependency is UE4SS, which is off-site, and file-to-file pins exact file
  versions — which go stale every time UE4SS tracks a game patch.
- **Permissions:** the defaults are maximally restrictive and would contradict
  the MIT licence shipped in the archive. Allow uploading, modification,
  conversion and asset use without permission.

## Steam Workshop

Palworld gained Workshop support in 0.7.0. It still runs on UE4SS underneath —
there is no official modding API — but it handles dependencies and installation
for the user, and it is where most Palworld UE4SS installs are.

Uploading needs the **Palworld Mod Uploader**, a separate tool that appears in
your Steam library if you own Palworld. It is a GUI, so this part is manual.

1. Launch the Mod Uploader. Hold **Shift** while clicking *Create a Mod* to
   create the item locally without publishing it yet; without Shift it
   immediately creates a hidden Workshop item.
2. Choose type **Lua**. It creates a folder named after the Workshop item id,
   containing `Info.json`, `thumbnail.png` and `Scripts/`.
3. Replace that `Scripts/` with the contents of
   `SharedXPPool-<version>-workshop.zip`.
4. Fill in Mod Information:
   - **Mod Name:** `Shared XP Pool`
   - **Package Name:** `SharedXPPool` — this becomes the installed folder
     name, so alphanumerics only and no spaces. It must match, or the config
     path in the description is wrong.
   - **Version:** the release version. Increment it every upload or the game
     will not see an update.
   - **Author:** your Steam name.
   - **Thumbnail:** under 1MB, or the upload fails with
     `k_EResultLimitExceeded`.
5. *Upload To Steam*, with change notes.
6. On the Workshop page, use **Add/Remove Required Items** to add the UE4SS
   Workshop item as a dependency. The uploader's own Dependencies field is
   known not to apply, so do it on the page.
7. Description: [`steam-workshop-description.bbcode`](steam-workshop-description.bbcode).
   Steam BBCode, which is not the same dialect as Nexus — `[h1]`, `[olist]`.
8. **Change Visibility** to public when you are ready. New items are hidden
   until you do, which is how you test it first.

Mod support in Palworld is opt-in, so the description leads with how to turn
the mod on in *Options > Mod Management*. Leave that in. Without it you will
get a steady stream of comments saying the mod does not work.

One quirk worth knowing while testing: edits inside the Workshop folder are
not picked up in game. Edit under `Palworld/Mods/NativeMods/UE4SS/` and copy
the result back into the Workshop folder when you are done.

Reference: <https://pwmodding.wiki/docs/developers/mod-publishing/workshop/packaging>
