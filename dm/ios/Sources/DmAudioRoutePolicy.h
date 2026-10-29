// Route changes can retry a failed activation while the game remains foreground.
// Category changes caused by our own setup must not recurse into activation.
#pragma once
static inline int dm_audio_route_retry(unsigned reason, int background, int interrupted, int session_off) {
    if (background || interrupted || !session_off) return 0;
    // AVAudioSessionRouteChangeReason: new/old device, override, wake,
    // no suitable route, or route configuration. Unknown/category are excluded.
    return reason == 1 || reason == 2 || reason == 4 || reason == 6 || reason == 7 || reason == 8;
}
