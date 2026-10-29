// Experimental SDR-to-EDR presentation policy. This expands an SDR picture's
// highlights; it does not recover a game's original scene-referred HDR signal.
#pragma once
#include <math.h>
#include <stdlib.h>
#include <string.h>

static inline int nvn_edr_requested(void) {
    const char *value = getenv("DM_PRESENT_EDR");
    return value && !strcmp(value, "1");
}
static inline float nvn_edr_headroom(int requested, int active, float current, float potential) {
    if (!requested || !active || !isfinite(current) || !isfinite(potential)) return 1;
    return fmaxf(1, fminf(2, fminf(current, potential)));
}

// The input is the same stored SDR bytes the stock present pass samples.
// Decode once to extended-linear sRGB, keep shadows/midtones, and expand only
// luminance above 0.5. A common RGB gain preserves the highlight's chromaticity.
#define NVN_EDR_MSL \
    "float3 edr_decode(float3 x) { x=clamp(x,0.0f,1.0f); return select(pow((x+0.055f)/1.055f,float3(2.4f)),x/12.92f,x<=0.04045f); }\n" \
    "float3 edr_map(float3 rgb,float headroom,bool alreadyLinear) { float3 l=alreadyLinear?clamp(rgb,0.0f,1.0f):edr_decode(rgb); float y=dot(l,float3(0.2126f,0.7152f,0.0722f)); float w=smoothstep(0.5f,1.0f,y); return l*(1.0f+(headroom-1.0f)*w); }\n"
