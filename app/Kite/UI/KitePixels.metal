#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// 像素化范围持续展开，并在循环前完全离开文字。
static float kiteSweep(float2 position, float4 bounds, float travel) {
    float x = position.x - bounds.x;
    float baseHalfWidth = clamp(bounds.z * 0.2, 24.0, 64.0);
    // 范围随扫掠持续展开，推进使用 SwiftUI 传入的系统 easeInOut 进度。
    float maxHalfWidth = baseHalfWidth * 1.35;
    float halfWidth = mix(baseHalfWidth * 0.45, maxHalfWidth, travel);
    // 终点留出最大范围，让整个像素化区域离开文字后再开始下一轮。
    float front = mix(-baseHalfWidth, bounds.z + maxHalfWidth, travel);
    return 1.0 - smoothstep(0.0, halfWidth, abs(x - front));
}

// 扫掠经过时笔画短暂变成彩色方块，离开后恢复；网格和配色固定，边缘平滑混合。
[[ stitchable ]] half4 kitePixels(float2 position, SwiftUI::Layer layer,
                                 float4 bounds, float travel) {
    half4 source = layer.sample(position);
    float intensity = kiteSweep(position, bounds, travel);
    if (intensity < 0.001) return source;
    float cell = clamp(bounds.w * 0.2, 2.5, 4.0);
    float2 grid = floor((position - bounds.xy) / cell);
    float2 center = (grid + 0.5) * cell + bounds.xy;
    half4 pixel = half4(0.0h);
    for (int row = -1; row <= 1; ++row) {
        for (int column = -1; column <= 1; ++column) {
            pixel += layer.sample(center + float2(column, row) * cell / 3.0) / 9.0h;
        }
    }
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
    half alpha = min(pixel.a * 1.65h, 1.0h);
    pixel = half4(palette[colorIndex] * alpha, alpha);
    return mix(source, pixel, half(intensity));
}
