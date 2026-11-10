#import <QuartzCore/CAMetalLayer.h>
#import <Metal/Metal.h>
#import <CoreGraphics/CoreGraphics.h>
#include "nvn_hdr.h"
#include <math.h>
// The device's own peak HDR brightness (nits), set by the front end from the hardware model
// (front_ios.m); 0 until then, in which case the layer keeps the mastering metadata it would
// have had. The environmental DM_HDR_EDR_MAX (a ratio of paper white) overrides it.
static double g_hdr_peak;
void dm_hdr_peak(double peak_nits) { if (peak_nits >= 0) g_hdr_peak = peak_nits; }
static double hdr_peak_clamp(double nits) {
    const char *em = getenv("DM_HDR_EDR_MAX");
    double clamp = em && *em ? strtod(em, NULL) : 0;
    if (isfinite(clamp) && clamp > 1.0) { double cap = DM_HDR_PAPER_WHITE * clamp; return nits < cap ? nits : cap; }
    if (g_hdr_peak > 0 && nits > g_hdr_peak) return g_hdr_peak;
    return nits;
}
// The peak the game is told its display reaches (QueryDisplayHdrStatus): the device's own peak when the front end published one, else the virtual 1,000 nits. A game tone-maps to
// this number, so the 1,600-nit phones were shown a 1,000-nit display; DM_HDR_EDR_MAX (a ratio of paper white) still caps it
int dm_hdr_mastering_peak(void) {
    double p = g_hdr_peak > 0 ? g_hdr_peak : DM_HDR_MASTERING_PEAK;
    return (int)hdr_peak_clamp(p);
}
void dm_hdr_configure_layer(void *ptr, double headroom) {
    CAMetalLayer *layer = (__bridge CAMetalLayer *)ptr;
    int requested = dm_hdr_requested();
    dm_hdr_display(requested && layer && isfinite(headroom) && headroom > 1.0 && CAEDRMetadata.available);
    if (!requested || !layer) return;
    // Keep a single float drawable format across SDR/HDR transitions and display-link drawables.
    // HDR10 metadata maps this virtual 1000-nit mastering display to the physical display.
    layer.pixelFormat = MTLPixelFormatRGBA16Float;
    CGColorSpaceRef cs = CGColorSpaceCreateWithName(kCGColorSpaceExtendedLinearITUR_2020);
    layer.colorspace = cs; CGColorSpaceRelease(cs);
    layer.wantsExtendedDynamicRangeContent = YES;
    if (!layer.EDRMetadata) layer.EDRMetadata = [CAEDRMetadata HDR10MetadataWithMinLuminance:0 maxLuminance:dm_hdr_mastering_peak() opticalOutputScale:DM_HDR_LINEAR_UNIT];
}
void dm_hdr_layer_metadata(void *ptr, int hdr_content) {
    CAMetalLayer *layer = (__bridge CAMetalLayer *)ptr;
    if (!layer || layer.pixelFormat != MTLPixelFormatRGBA16Float || !dm_hdr_requested()) return;
    uint16_t lo = 0, hi = 100;
    if (hdr_content) dm_hdr_luminance_range(1, &lo, &hi);
    static __weak CAMetalLayer *last_layer;
    static uint32_t last_range;
    uint32_t range = lo | (uint32_t)hi << 16;
    if (last_layer == layer && last_range == range) return;
    layer.EDRMetadata = [CAEDRMetadata HDR10MetadataWithMinLuminance:lo maxLuminance:hdr_peak_clamp(hi) opticalOutputScale:DM_HDR_LINEAR_UNIT];
    last_layer = layer; last_range = range;
}
