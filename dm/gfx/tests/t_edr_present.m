// Real production present shaders/Metal queues with synthetic SDR textures.
// Readback proves conversion and default parity, not a display's HDR luminance.
#include "../nvn/nvn_mtl.m"
module_t *module_of(const void *p) { (void)p; return NULL; }
module_t *g_mod; int g_nmod;
void svc_thread_dump(void) {}
void *front_metal_layer(void) { return NULL; }
uint64_t now_ns(void) { return bp_now(); }
extern _Atomic float edr_probe_headroom;
static int checks, failed;
#define CHECK(name, ok) do { checks++; int pass = !!(ok); failed += !pass; printf("%s: %s\n", name, pass ? "PASS" : "FAIL"); } while (0)

static id<MTLTexture> source(MTLPixelFormat format, int size, const uint8_t rgba[4]) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:size height:size mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d];
    uint8_t *bytes = malloc(size * size * 4); for (int i = 0; i < size * size; i++) memcpy(bytes + i * 4, rgba, 4);
    [t replaceRegion:MTLRegionMake2D(0,0,size,size) mipmapLevel:0 withBytes:bytes bytesPerRow:size*4]; free(bytes);
    res_add(t); res_commit(); return t;
}
static id<MTLTexture> target(MTLPixelFormat format, int width, int height) {
    MTLTextureDescriptor *d = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:format width:width height:height mipmapped:NO];
    d.storageMode = MTLStorageModeShared; d.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    id<MTLTexture> t = [g_dev newTextureWithDescriptor:d]; res_add(t); res_commit(); return t;
}
static void classic(id<MTLTexture> src, id<MTLTexture> out) {
    id<MTLCommandBuffer> cb = [g_q commandBuffer]; CHECK("classic present encodes", present_encode(cb,src,out,NULL));
    [cb commit]; [cb waitUntilCompleted]; CHECK("classic GPU work completes", cb.status == MTLCommandBufferStatusCompleted);
}
static int close_pixel_tolerance(id<MTLTexture> texture, float expected, int x, int y, float tolerance) {
    __fp16 pixel[4]; [texture getBytes:pixel bytesPerRow:8 fromRegion:MTLRegionMake2D(x,y,1,1) mipmapLevel:0];
    return fabsf((float)pixel[0] - expected) < tolerance && fabsf((float)pixel[1] - expected) < tolerance &&
           fabsf((float)pixel[2] - expected) < tolerance && pixel[3] == 1;
}
static int close_pixel(id<MTLTexture> texture, float expected, int x, int y) {
    return close_pixel_tolerance(texture,expected,x,y,0.003f);
}
int main(void) { @autoreleasepool {
    mtl_init(); g_fx_mode = 0;
    const uint8_t gray[4] = {128,128,128,255}, white[4] = {255,255,255,255}, black[4] = {0,0,0,255};
    for (int srgb = 0; srgb < 2; srgb++) {
        id<MTLTexture> s = source(srgb ? MTLPixelFormatRGBA8Unorm_sRGB : MTLPixelFormatRGBA8Unorm,8,gray);
        id<MTLTexture> bytes = target(MTLPixelFormatRGBA8Unorm,8,8), linear = target(MTLPixelFormatRGBA16Float,8,8);
        g_edr_mode = 0; classic(s,bytes); uint8_t out[256]; [bytes getBytes:out bytesPerRow:32 fromRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0];
        int bad = 0; for (int i = 0; i < 64; i++) bad += memcmp(out+i*4,gray,4) != 0;
        CHECK("SDR default preserves every source byte", bad == 0);
        classic(s,linear); CHECK("disabled EDR preserves raw float-target values", close_pixel(linear,128.0f/255.0f,4,4));
        g_edr_mode = 1; classic(s,linear); CHECK("SDR gamma is decoded exactly once for linear EDR", close_pixel(linear,0.2158605f,4,4));
        classic(s,bytes); [bytes getBytes:out bytesPerRow:32 fromRegion:MTLRegionMake2D(0,0,8,8) mipmapLevel:0];
        bad = 0; for (int i = 0; i < 64; i++) bad += memcmp(out+i*4,gray,4) != 0;
        CHECK("SDR screenshot target stays byte-identical while EDR is enabled", bad == 0);
        res_remove(s); res_remove(bytes); res_remove(linear);
    }
    id<MTLTexture> w = source(MTLPixelFormatRGBA8Unorm,8,white), b = source(MTLPixelFormatRGBA8Unorm,8,black);
    id<MTLTexture> f = target(MTLPixelFormatRGBA16Float,8,8);
    g_edr_mode = 1; atomic_store(&edr_probe_headroom,2); classic(w,f); CHECK("white expands to the bounded headroom", close_pixel(f,2,4,4));
    atomic_store(&edr_probe_headroom,1); classic(w,f); CHECK("headroom loss returns white to SDR", close_pixel(f,1,4,4));
    atomic_store(&edr_probe_headroom,2); classic(b,f); CHECK("black stays black", close_pixel(f,0,4,4));
    for (int value = 10; value <= 11; value++) {
        uint8_t rgba[4] = {(uint8_t)value,(uint8_t)value,(uint8_t)value,255};
        id<MTLTexture> s = source(MTLPixelFormatRGBA8Unorm,8,rgba); classic(s,f);
        CHECK("the sRGB transfer-function knee stays finite and correct", close_pixel_tolerance(f,value == 10 ? 0.00303527f : 0.00334654f,4,4,0.00002f)); res_remove(s);
    }
    id<MTLTexture> bars = target(MTLPixelFormatRGBA16Float,16,8); classic(w,bars);
    CHECK("aspect-fit bars stay black", close_pixel(bars,0,0,4) && close_pixel(bars,0,15,4));
    CHECK("the entire centered picture reaches EDR", close_pixel(bars,2,4,4) && close_pixel(bars,2,11,4));
    if ([MTLFXSpatialScalerDescriptor supportsMetal4FX:g_dev]) {
        g_fx_mode = 1; id<MTLTexture> s = source(MTLPixelFormatRGBA8Unorm_sRGB,64,gray);
        id<MTLTexture> e = target(MTLPixelFormatRGBA16Float,128,128), png = target(MTLPixelFormatBGRA8Unorm,128,128);
        CHECK("MetalFX EDR present actually uses the scaler", present_offscreen_wait(s,NULL,e) == PRESENT_METALFX);
        CHECK("MetalFX perceptual output is decoded once in the final pass", close_pixel(e,0.2158605f,64,64));
        CHECK("MetalFX SDR capture actually uses the scaler", present_offscreen_wait(s,NULL,png) == PRESENT_METALFX);
        uint8_t pixel[4]; [png getBytes:pixel bytesPerRow:4 fromRegion:MTLRegionMake2D(64,64,1,1) mipmapLevel:0];
        CHECK("MetalFX screenshot remains SDR", abs(pixel[0]-128)<=3 && abs(pixel[1]-128)<=3 && abs(pixel[2]-128)<=3 && pixel[3]==255);
        res_remove(s); res_remove(e); res_remove(png);
    } else printf("MetalFX is unavailable; its EDR combination remains unchecked\n");
    printf("edr present: %d checks, %d failed\n", checks, failed);
    return failed != 0;
} }
