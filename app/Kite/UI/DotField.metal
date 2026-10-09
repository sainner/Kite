#include <metal_stdlib>
#include <SwiftUI/SwiftUI.h>
using namespace metal;

// 点阵画布的逐像素着色，几何与混色和 Dots.swift、DotStage.swift 保持一致：
// 步距 12 点，格 10 点居中，shape 为 0 时是点径 2 点的圆。
constant float dotPitch = 12.0;
constant float dotHalf = 5.0;
constant float dotRestScale = 0.2;
constant int profileCount = 120;
// 格表每格 8 个数：列、行、终态序号（-1 是空位）、shape、不预乘的 sRGB 与透明度。
constant int cellStride = 8;
// 波每道 6 个数：起点区域 x、y、宽、高，波前已走的距离，终态序号。
constant int waveStride = 6;
// 图案每块 28 个数，布局见 ResolvedPattern.appendShaderData。
constant int patternStride = 28;
// 同 PatternMotion.morphSpread 与 DotMetrics.morphDuration。
constant float morphSpread = 0.6;
constant float morphDuration = 0.5;

static float smoothUnit(float x) {
    float t = clamp(x, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

static float easeOutCubic(float x) {
    float t = 1.0 - clamp(x, 0.0, 1.0);
    return 1.0 - t * t * t;
}

// 与 DotField.slot 相同的散列；格表和效果色都按它取位。
static uint cellHash(int column, int row) {
    uint h = (uint(column) * 73856093u) ^ (uint(row) * 19349663u);
    return h ^ (h >> 16);
}

static float srgbLinear(float value) {
    return value <= 0.04045 ? value / 12.92 : powr((value + 0.055) / 1.055, 2.4);
}

static float srgbGamma(float value) {
    float encoded = value <= 0.0031308 ? value * 12.92 : 1.055 * powr(max(value, 0.0), 1.0 / 2.4) - 0.055;
    return clamp(encoded, 0.0, 1.0);
}

// 预乘透明度的 oklab，同 DotColor.oklab。
static float4 oklab(float4 color) {
    float r = srgbLinear(color.r), g = srgbLinear(color.g), b = srgbLinear(color.b);
    float l = powr(max(0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b, 0.0), 1.0 / 3.0);
    float m = powr(max(0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b, 0.0), 1.0 / 3.0);
    float s = powr(max(0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b, 0.0), 1.0 / 3.0);
    float3 lab = float3(0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s,
                        1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s,
                        0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s);
    return float4(lab * color.a, color.a);
}

static float4 fromOklab(float4 lab) {
    float alpha = clamp(lab.w, 0.0, 1.0);
    if (alpha <= 0.0) return float4(0.0);
    float3 c = lab.xyz / lab.w;
    float l = pow(c.x + 0.3963377774 * c.y + 0.2158037573 * c.z, 3.0);
    float m = pow(c.x - 0.1055613458 * c.y - 0.0638541728 * c.z, 3.0);
    float s = pow(c.x - 0.0894841775 * c.y - 1.291485548 * c.z, 3.0);
    return float4(srgbGamma(4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s),
                  srgbGamma(-1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s),
                  srgbGamma(-0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s),
                  alpha);
}

// 同 DotColor.mixed(with:by:)。
static float4 mixColor(float4 a, float4 b, float t) {
    float4 la = oklab(a);
    return fromOklab(la + (oklab(b) - la) * clamp(t, 0.0, 1.0));
}

// 一格上各块图案叠好的样子，同 ResolvedPattern.dot：后面的图案盖住前面的。每格的取值由 CPU 整批算好，按行排在 values 里。
// 颜色在确定这像素要画之后才混，这里只记下混向哪个颜色、混几成（amount 为 0 表示没有图案，是静息的点）。
struct PatternDot {
    float shape;
    int form;
    float4 target;
    float amount;
};

static PatternDot patternDot(int column, int row, device const float *patterns, int patternFloats, device const float *values) {
    PatternDot result = { 0.0, 0, float4(0.0), 0.0 };
    for (int p = 0; p + patternStride <= patternFloats; p += patternStride) {
        device const float *h = patterns + p;
        int c0 = int(h[0]), c1 = int(h[1]), r0 = int(h[2]), r1 = int(h[3]);
        if (column < c0 || column > c1 || row < r0 || row > r1) continue;
        float value = values[int(h[4]) + (row - r0) * (c1 - c0 + 1) + (column - c0)];
        float shape = abs(value);
        if (shape <= 1.0 / 512.0) continue;
        // 形变时沿对角线逐格换过去，还没换过一半的格子用旧图案的颜色与终态
        bool earlier = false;
        if (h[9] > 0.5) {
            float delay = h[7] > 0.0 ? float(column - int(h[5]) + row - int(h[6])) / h[7] * morphSpread : 0.0;
            earlier = easeOutCubic((h[8] - delay) / morphDuration) < 0.5;
        }
        int pick = (earlier ? 20 : 12) + (value >= 0.0 ? 0 : 4);
        result.shape = shape;
        result.form = int(h[earlier ? 11 : 10]);
        result.target = float4(h[pick], h[pick + 1], h[pick + 2], h[pick + 3]);
        result.amount = min(1.0, shape * 1.6);
    }
    return result;
}

// 窗口点阵的一帧，颜色都是不预乘的 sRGB。frame 是 (画布原点 x, y, 画布到窗口的缩放, 一像素合多少窗口点)；
// cells 是图形与轨迹覆盖到的格子（CPU 已按 DotField.dot 连同底下的图案算好），按散列开放寻址；
// 其余格子先查 patterns 与 values 里的图案（ResolvedPattern.dot），再按 DotWave.shape 取大叠上经过的波，没有就是静息的点。
// hidden 是被遮掉的范围（窗口坐标，每块 minX、minY、maxX、maxY），那里不用算。
[[ stitchable ]] half4 dotField(float2 position, float4 frame, float4 rest, float drawsRest,
                                device const float *cells, int cellFloats,
                                device const float *waves, int waveFloats,
                                float4 wave, float waveOpacity,
                                device const float *palette, int paletteFloats,
                                device const float *profiles, int profileFloats,
                                device const float *patterns, int patternFloats,
                                device const float *values, int valueFloats,
                                device const float *hidden, int hiddenFloats) {
    float2 point = frame.xy + position * frame.z;
    for (int i = 0; i + 4 <= hiddenFloats; i += 4) {
        if (point.x >= hidden[i] && point.y >= hidden[i + 1] && point.x < hidden[i + 2] && point.y < hidden[i + 3]) return half4(0.0h);
    }
    int column = int(floor(point.x / dotPitch)), row = int(floor(point.y / dotPitch));
    float2 offset = point - (float2(column, row) + 0.5) * dotPitch;
    // 终态轮廓都在 [-1, 1] 的方框里，任一方向离格心超过半个格宽（加一像素的抗锯齿）一定是缝。
    if (any(abs(offset) > dotHalf + frame.w)) return half4(0.0h);
    float distance = length(offset);

    int form = 0;
    float shape = 0.0;
    float4 color = rest;
    bool found = false;
    uint capacity = uint(cellFloats / cellStride);
    uint hash = cellHash(column, row);
    for (uint probe = 0; probe < capacity; ++probe) {
        uint index = ((hash + probe) & (capacity - 1)) * cellStride;
        if (cells[index + 2] < 0.0) break;
        if (int(cells[index]) == column && int(cells[index + 1]) == row) {
            form = int(cells[index + 2]);
            shape = cells[index + 3];
            color = float4(cells[index + 4], cells[index + 5], cells[index + 6], cells[index + 7]);
            found = true;
            break;
        }
    }

    PatternDot pattern = { 0.0, 0, float4(0.0), 0.0 };
    float waveAmount = 0.0;
    if (!found) {
        pattern = patternDot(column, row, patterns, patternFloats, values);
        shape = pattern.shape;
        form = pattern.form;
        // wave：(半宽, 走到多远消失, 从几成处变弱, 波前正中的 shape)
        float waveShape = 0.0;
        int waveForm = 0;
        float2 squareMin = float2(column, row) * dotPitch, squareMax = squareMin + dotPitch;
        for (int i = 0; i + waveStride <= waveFloats; i += waveStride) {
            float2 originMin = float2(waves[i], waves[i + 1]);
            float2 originMax = originMin + float2(waves[i + 2], waves[i + 3]);
            float front = waves[i + 4];
            if (front < 0.0 || front >= wave.y + wave.x || wave.x <= 0.0) continue;
            float2 gap = max(max(originMin - squareMax, squareMin - originMax), 0.0);
            float x = abs(length(gap) - front) / wave.x;
            if (x >= 1.0) continue;
            float fadeFrom = wave.y * wave.z;
            float fade = 1.0 - smoothUnit((front - fadeFrom) / max(wave.y - fadeFrom, 1.0));
            float value = (1.0 - smoothUnit(x)) * fade * wave.w;
            if (value > waveShape) {
                waveShape = value;
                waveForm = int(waves[i + 5]);
            }
        }
        // 波按取大叠在图案上（DotBlend.lighten）：只长出比图案大的那段，颜色只在超出的那段混向波的颜色。
        if (waveShape > shape) {
            waveAmount = (waveShape - shape) / max(1.0 - shape, 1e-6);
            shape = waveShape;
            form = waveForm;
        }
        if (shape <= 1.0 / 512.0 && drawsRest <= 0.0) return half4(0.0h);
    }

    // 轮廓：先在点圆与终态之间混合，再从点径长到满格，同 DotForm.profile。
    float s = clamp(shape, 0.0, 1.0);
    float unit = 1.0;
    if (s > 0.0 && distance > 0.0) {
        float t = (atan2(offset.y, offset.x) / (2.0 * M_PI_F) + 0.25) * float(profileCount);
        t -= floor(t / float(profileCount)) * float(profileCount);
        int i0 = min(int(t), profileCount - 1), i1 = (i0 + 1) % profileCount;
        int base = clamp(form, 0, profileFloats / profileCount - 1) * profileCount;
        unit = mix(profiles[base + i0], profiles[base + i1], t - float(i0));
    }
    float radius = (dotRestScale + (1.0 - dotRestScale) * s) * (1.0 + (unit - 1.0) * s) * dotHalf;
    float coverage = clamp((radius - distance) / frame.w + 0.5, 0.0, 1.0);
    if (coverage <= 0.0) return half4(0.0h);

    if (!found && pattern.amount > 0.0) color = mixColor(rest, pattern.target, pattern.amount);
    if (!found && waveAmount > 0.0) {
        uint colors = uint(max(paletteFloats / 4, 1));
        uint pick = ((uint(column) * 73856093u) ^ (uint(row) * 19349663u)) % colors * 4;
        float4 target = float4(palette[pick], palette[pick + 1], palette[pick + 2], palette[pick + 3] * waveOpacity);
        color = mixColor(color, target, waveAmount);
    }
    return half4(half3(color.rgb * color.a), half(color.a)) * half(coverage);
}
