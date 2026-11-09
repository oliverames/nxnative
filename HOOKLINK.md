# The HookLink branch of nxnative

This branch is the build engine of [HookLink](https://github.com/dsi-hub/HookLink), a Mac app that builds *The Legend of Zelda: Ocarina of Time* (Nintendo Switch 2 Edition) for iPhone from the player's own dump. It is [nxnative](https://github.com/seedds/nxnative) (MIT) plus the changes below, made and tested for this game on an iPhone 18 Pro Max (A20 Pro, iOS 27.2). HookLink downloads this branch and keeps it up to date.

No game files, keys or anything built from a dump are here. The pipeline rows in `dm/games/0400486024DEC000/pso_manifest.tsv` are shader identifiers and drawing settings, the same kind of list nxnative ships.

## Changes over nxnative

- **Pipelines:** a hybrid draw remembers pipelines the archive had no base for, instead of searching every archive file on each draw of each frame. Demanded builds get at least 3 queues, and their table is indexed by key. Each pipeline a draw stands in for goes into `pso_user.tsv` when first asked for, so the next start's prepare step builds it (`DM_PSO_DEMAND_RECORD=0`: only once built). `DM_PSO_BG_QUEUES` and `DM_PSO_BG_QOS` tune the background builds.
- **Prewarm list:** Ocarina's list takes the rows recorded on the iPhone in Kokiri Forest, Hyrule Field, Castle Town and Hyrule Castle, plus one mesh pipeline nxnative's seed rows lacked.
- **Memory:** shared textures no live object uses are retired under memory pressure, fixing the freeze after the talk with Saria (PR #1455). Render targets use nxnative's own recycling (7f502220); the earlier shared placement heap (PR #1453) is gone, as nxnative found it can corrupt the picture.
- **Game speed:** Ocarina's frame ratio is never below the measured frame time (from PR #1543, after gunvalk's finding in Lichii PR #216), so the game keeps real speed below 60 fps with `DM_FPS_HOLD off`.
- **Frame pacing on iOS:** the thread that presents the game's frames runs user-interactive whatever its priority. Under `DM_QOS_MAP` it was user-initiated, and iOS kept it on the efficiency cores (1.6 GHz instead of 3.7), so Hyrule Field fell to 41-55 fps with the GPU half idle (`DM_FRAME_QOS=0` turns it off).
- **iOS:** `Documents/res_overlay` is read as a game file overlay (HookLink's resolution file). Ocarina gets a pipeline archive for `g19p`.

## Credits

nxnative by seedds and its contributors; the PR authors above; gunvalk for the frame-step finding. nxnative's MIT license (`LICENSE`) applies to this branch.
