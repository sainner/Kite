#include <metal_stdlib>
using namespace metal;

// 像素化范围持续展开，并在循环前完全离开文字。
static float kiteSweep(float2 position, float4 bounds, float travel) {
    float x = position.x - bounds.x;
    float baseHalfWidth = clamp(bounds.z * 0.2, 24.0, 64.0);
    // 范围随扫掠持续展开，推进按调用方给的系统 easeInOut 进度。
    float maxHalfWidth = baseHalfWidth * 1.35;
    float halfWidth = mix(baseHalfWidth * 0.45, maxHalfWidth, travel);
    // 终点留出最大范围，让整个像素化区域离开文字后再开始下一轮。
    float front = mix(-baseHalfWidth, bounds.z + maxHalfWidth, travel);
    return 1.0 - smoothstep(0.0, halfWidth, abs(x - front));
}

// 一格方块的颜色。average 是这一格里 3×3 个点取样的平均。
static half4 kiteCellColor(float2 grid, half4 average) {
    // 效果色，与 DotColor.palette 同一组（见 docs/视觉风格.md）；同一格始终取同一色，避免逐帧闪色。
    constexpr half3 palette[5] = {
        half3(127.0h, 168.0h, 214.0h) / 255.0h, // #7FA8D6 Morning Breeze
        half3(168.0h, 198.0h, 231.0h) / 255.0h, // #A8C6E7 Dewy Blue
        half3(255.0h, 224.0h, 138.0h) / 255.0h, // #FFE08A Sunwashed
        half3(245.0h, 201.0h,  92.0h) / 255.0h, // #F5C95C Sunwashed 深一档
        half3( 91.0h, 136.0h, 194.0h) / 255.0h, // #5B88C2 主题色
    };
    float noise = fract(sin(dot(grid, float2(127.1, 311.7))) * 43758.5453);
    uint colorIndex = uint(noise * 5.0);
    // 提高方块的覆盖率，细笔画也能看清；颜色保持预乘透明度，不给空白处铺色。
    half alpha = min(average.a * 1.65h, 1.0h);
    return half4(palette[colorIndex] * alpha, alpha);
}

// 工具在跑时的像素扫掠（iOS 对话的工具行，见 PhoneActivityView）：扫掠经过时笔画短暂变成彩色方块，离开后恢复；
// 网格和配色固定，边缘平滑混合。字先画进贴图，CAMetalLayer 按屏幕刷新率逐帧画；贴图比字的范围四边各多 inset 点，按点取样。
// Mac 的工具行在 CPU 上画同样的效果，见 MacToolActivity。

struct KiteSweepVertex {
    float4 position [[position]];
};

// 一个盖住整个画面的三角形。
vertex KiteSweepVertex kiteSweepVertex(uint id [[vertex_id]]) {
    float2 corner = float2((id << 1) & 2, id & 2);
    return KiteSweepVertex { float4(corner * float2(2.0, -2.0) + float2(-1.0, 1.0), 0.0, 1.0) };
}

struct KiteSweepUniforms {
    float4 bounds;
    float travel;
    float scale;
    float inset;
    float padding;
    float2 textureSize;
};

static half4 kiteTextureSample(texture2d<half> source, float2 position, constant KiteSweepUniforms &u) {
    constexpr sampler linearSampler(filter::linear, address::clamp_to_zero);
    return source.sample(linearSampler, (position + u.inset) * u.scale / u.textureSize);
}

fragment half4 kiteSweepFragment(KiteSweepVertex in [[stage_in]], constant KiteSweepUniforms &u [[buffer(0)]],
                                 texture2d<half> source [[texture(0)]]) {
    float2 position = in.position.xy / u.scale;
    half4 base = kiteTextureSample(source, position, u);
    float intensity = kiteSweep(position, u.bounds, u.travel);
    if (intensity < 0.001) return base;
    float cell = clamp(u.bounds.w * 0.2, 2.5, 4.0);
    float2 grid = floor((position - u.bounds.xy) / cell);
    float2 center = (grid + 0.5) * cell + u.bounds.xy;
    half4 pixel = half4(0.0h);
    for (int row = -1; row <= 1; ++row) {
        for (int column = -1; column <= 1; ++column) {
            pixel += kiteTextureSample(source, center + float2(column, row) * cell / 3.0, u) / 9.0h;
        }
    }
    return mix(base, kiteCellColor(grid, pixel), half(intensity));
}
