#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// 阵风从左向右经过摘要，局部模糊并轻微牵动笔画；保留原文字颜色。
[[ stitchable ]] half4 kiteWind(float2 position, SwiftUI::Layer layer,
                               float4 bounds, float travel) {
    float x = position.x - bounds.x;
    float baseHalfWidth = clamp(bounds.z * 0.2, 24.0, 64.0);
    // 范围随扫掠持续展开，推进使用 SwiftUI 传入的系统 easeInOut 进度。
    float maxHalfWidth = baseHalfWidth * 1.35;
    float halfWidth = mix(baseHalfWidth * 0.45, maxHalfWidth, travel);
    // 终点留出最大范围，让整个模糊区域离开文字后再开始下一轮。
    float front = mix(-baseHalfWidth, bounds.z + maxHalfWidth, travel);
    float wind = 1.0 - smoothstep(0.0, halfWidth, abs(x - front));
    if (wind < 0.001) return layer.sample(position);

    // 5×5 高斯近似核，采样最远为 3pt；透明像素也参与，笔画边缘才能变柔。
    constexpr float weights[5] = {1.0, 4.0, 6.0, 4.0, 1.0};
    float step = wind * 1.5;
    // 向左取样，让像素向右偏移；中心最多 2pt，边缘归零，叠加模糊后 X 采样不超过 5pt。
    float push = wind * 2.0;
    float2 sourcePosition = position - float2(push, 0.0);
    half4 blurred = half4(0.0h);
    for (int row = -2; row <= 2; ++row) {
        for (int column = -2; column <= 2; ++column) {
            float2 offset = float2(column, row) * step;
            half weight = half(weights[column + 2] * weights[row + 2] / 256.0);
            blurred += layer.sample(sourcePosition + offset) * weight;
        }
    }
    return blurred;
}
