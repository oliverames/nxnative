# Diagnose native aspect before changing a camera

This branch adds `DM_ASPECT_TRACE=1`, off by default. It records the first 16 actual `oe::GetDefaultDisplayResolution` queries and resolution-change-event requests. Answers remain 1920x1080 docked and 1280x720 handheld. Event binding stays unchanged. The trace works on iOS because it runs inside the registered hooks rather than generating executable counting stubs.

The source already logs the later output boundaries, so this experiment adds no NVN profiler or present mode:

| Boundary | Existing source and evidence |
|---|---|
| Guest default display answer | `dm/host/hle_oe.c`, new `aspect query` lines |
| Guest sized layer and layer crop | `dm/gfx/hle_vi.c`, `vi::CreateLayer` and changed `vi::SetLayerCrop` lines |
| Swapchain and window crop | `dm/gfx/nvn/hle_nvn.c`, `WindowInitialize` and changed `WindowCrop` lines |
| Valid source rectangle and drawable canvas | `dm/gfx/nvn/nvn_mtl.m`, changed `present crop` and `present viewport` lines |
| Internal render attachments and shader bindings | existing `DM_NVN_PASSDUMP` / `DM_NVN_PASSDUMP_ALL` |
| Exact projection candidates | existing `DM_NVN_CBDUMP` / `DM_NVN_CBDUMP_KEY`, after identifying a real world vertex shader |

## Capture procedure

1. Record the exact game version, `main` and `sdk` NSO build IDs, host revision, shader-chain stamp and source hashes. Use an isolated save and a stable gameplay route. Keep game dumps and generated captures in that game's external work folder. A profile title or a matching shader name is not a substitute for the exact build.
2. Enable `DM_ASPECT_TRACE=1` before launch. Capture the stock run first, including the existing crop, swapchain and viewport lines. No query line means these particular registered hooks were not reached while tracing; it does not prove that the game has no display or camera logic. A line numbered `16/16` means the query budget is exhausted.
3. Pick a known frame in the stable world scene and set `DM_NVN_PASSDUMP` to that frame, or a short inclusive range. Set `DM_NVN_PASSDUMP_ALL=1` only for that bounded capture. Record the actual world vertex shader key from its draw and resolve it in that build's shader map. Menus and final composite triangles do not identify the world camera. On a Mac host, an existing `DM_CTL` `passdump` request can select a few frames once the scene is reached.
4. Create an output directory, set `DM_NVN_CBDUMP` to it, and set `DM_NVN_CBDUMP_KEY` to the confirmed full vertex key. Keep the same bounded `DM_NVN_PASSDUMP` range. The backend writes `F<frame>_p<pass>_st<stage>_cb<slot>_<address>.bin` blocks; for a vertex key it also records vertex streams and indices. Do not substitute an example or invented shader key.
5. Compare a fixed scene and a controlled camera change. Track which internal attachments feed the final image, which crop is valid, and which uniform block contains the projection actually used by that world draw. Trace that block's producer in the exact memory image before changing it. A changing matrix is a candidate until its consumer and producer are confirmed.
6. Only then define a build-gated experiment that covers the camera projection, culling, internal target dimensions, postprocessing and UI anchoring together. Compare world geometry and visible edges against the stock capture. A wider output texture, a scalar float hit or an absence of literal-load references does not establish that the camera widened.

`tools/scan_aspect.py` in the wrapper repository is a preliminary scalar/LDR-literal scan. It misses ADRP-based loads and computed ratios. Earlier draw-table and float-constant experiments are recorded in [anygame issue #2](https://github.com/oliverames/anygame/issues/2); their negative results should not be replaced with an assumption that the camera follows the output size.

## Verification and limits

`make -C dm/host/tests GAME=<known profile> aspect-trace` calls the actual registered resolution and layer hooks without game files or a GPU. It checks default-off logging, stock docked/handheld answers, nullable output arguments, event binding, the 16-line cap, errno preservation, and the independent guest layer/crop state. `GAME=<known profile> python3 dm/ios/tools/build_aspect_trace_probe.py --output <new scratch directory>` builds the same test in an unsigned native iOS app. The app writes `Documents/results.json`, `verification.log` and `errors.log`, with exact source hashes. Its event binding is a stub and it runs no guest game.

No camera patch, native-aspect rendering, cropping, stretching or resolution override is implemented. The procedure still needs a confirmed game build, world shader key and real capture before it can identify a safe projection change.
