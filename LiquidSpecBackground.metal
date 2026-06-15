#include <metal_stdlib>
using namespace metal;

struct LayerState {
    float2 pos;
    float2 dim;
    float opacity;
    float blur;
};

// MARK: - Utils

float hashLiquid(float2 p) {
    return fract(sin(dot(p, float2(127.1, 311.7))) * 43758.5453123);
}

float smootherLiquid(float x) {
    x = clamp(x, 0.0, 1.0);
    return x * x * x * (x * (x * 6.0 - 15.0) + 10.0);
}

float segmentEase(float value, float start, float end) {
    return smootherLiquid((value - start) / max(end - start, 0.0001));
}

float interp4(float a, float b, float c, float d, float p) {
    p = clamp(p, 0.0, 1.0);

    if (p <= 0.35) {
        return mix(a, b, smootherLiquid(p / 0.35));
    }

    if (p <= 0.75) {
        return mix(b, c, smootherLiquid((p - 0.35) / 0.40));
    }

    return mix(c, d, smootherLiquid((p - 0.75) / 0.25));
}

float interpKeys(float k0, float k1, float k2, float k3, float progress) {
    if (progress <= 0.30) {
        return mix(k0, k1, smootherLiquid((progress - 0.10) / 0.24));
    }

    if (progress <= 0.60) {
        return mix(k1, k2, smootherLiquid((progress - 0.24) / 0.42));
    }

    return mix(k2, k3, smootherLiquid((progress - 0.52) / 0.36));
}

float2 interp4v(float2 a, float2 b, float2 c, float2 d, float p) {
    return float2(
        interp4(a.x, b.x, c.x, d.x, p),
        interp4(a.y, b.y, c.y, d.y, p)
    );
}

LayerState makeState(
    float2 p0, float2 p1, float2 p2, float2 p3,
    float2 d0, float2 d1, float2 d2, float2 d3,
    float o0, float o1, float o2, float o3,
    float b0, float b1, float b2, float b3,
    float progress
) {
    LayerState s;

    s.pos = interp4v(p0, p1, p2, p3, progress);
    s.dim = interp4v(d0, d1, d2, d3, progress);
    s.opacity = interp4(o0, o1, o2, o3, progress);
    s.blur = interp4(b0, b1, b2, b3, progress);

    return s;
}

float localY(float2 p, LayerState s) {
    return clamp((p.y - s.pos.y) / max(s.dim.y, 1.0), 0.0, 1.0);
}

// MARK: - SDF shapes

float trapezoidSDF(
    float2 p,
    LayerState s,
    float leftTop,
    float rightTop,
    float leftBottom,
    float rightBottom
) {
    float2 safeDim = float2(max(s.dim.x, 1.0), max(s.dim.y, 1.0));
    float2 q = (p - s.pos) / safeDim;

    float l = mix(leftTop, leftBottom, q.y);
    float r = mix(rightTop, rightBottom, q.y);

    float left = (q.x - l) * s.dim.x;
    float right = (r - q.x) * s.dim.x;
    float top = q.y * s.dim.y;
    float bottom = (1.0 - q.y) * s.dim.y;

    return min(min(left, right), min(top, bottom));
}

float rectSDF(float2 p, LayerState s) {
    float2 safeDim = float2(max(s.dim.x, 1.0), max(s.dim.y, 1.0));
    float2 q = (p - s.pos) / safeDim;

    float left = q.x * s.dim.x;
    float right = (1.0 - q.x) * s.dim.x;
    float top = q.y * s.dim.y;
    float bottom = (1.0 - q.y) * s.dim.y;

    return min(min(left, right), min(top, bottom));
}

float svgGradientAlpha(
    float2 p,
    LayerState s,
    float blueY,
    float transparentY
) {
    float y = localY(p, s);

    if (blueY > transparentY) {
        return smoothstep(transparentY, blueY, y);
    } else {
        return 1.0 - smoothstep(blueY, transparentY, y);
    }
}

float softLayerAlpha(float sdf, float blur) {
    // Более мягкие края liquid-слоёв.
    float softness = max(24.0, blur * 0.70);
    return smoothstep(-softness, softness, sdf);
}

// MARK: - Layer fields

float blueTrapField(
    float2 p,
    LayerState s,
    float leftTop,
    float rightTop,
    float leftBottom,
    float rightBottom,
    float blueY,
    float transparentY,
    float strength
) {
    float sdf = trapezoidSDF(
        p,
        s,
        leftTop,
        rightTop,
        leftBottom,
        rightBottom
    );

    float shape = softLayerAlpha(sdf, s.blur);
    float grad = svgGradientAlpha(p, s, blueY, transparentY);

    return shape * grad * s.opacity * strength;
}

float whiteTrapField(
    float2 p,
    LayerState s,
    float leftTop,
    float rightTop,
    float leftBottom,
    float rightBottom,
    float strength
) {
    float sdf = trapezoidSDF(
        p,
        s,
        leftTop,
        rightTop,
        leftBottom,
        rightBottom
    );

    return softLayerAlpha(sdf, s.blur) * s.opacity * strength;
}

float whiteRectField(float2 p, LayerState s, float strength) {
    return softLayerAlpha(rectSDF(p, s), s.blur) * s.opacity * strength;
}

// MARK: - Blend approximations

float3 plusDarkerApprox(float3 backdrop, float3 source, float alpha) {
    alpha = clamp(alpha, 0.0, 1.0);
    float3 blended = max(float3(0.0), backdrop + source - float3(1.0));
    return mix(backdrop, blended, alpha);
}

float3 plusLighterApprox(float3 backdrop, float3 source, float alpha) {
    alpha = clamp(alpha, 0.0, 1.0);
    float3 blended = min(float3(1.0), backdrop + source);
    return mix(backdrop, blended, alpha);
}

// MARK: - Main shader

[[ stitchable ]]
half4 liquidSpecBackground(
    float2 position,
    half4 color,
    float2 size,
    float progress,
    float tapPulse,
    float2 tapPoint,
    float time
) {
    progress = clamp(progress, 0.0, 1.0);

    float2 design = float2(375.0, 812.0);
    float2 safeSize = float2(max(size.x, 1.0), max(size.y, 1.0));

    float2 p = float2(
        position.x / safeSize.x * design.x,
        position.y / safeSize.y * design.y
    );

    float2 uv = position / safeSize;

    float3 white = float3(1.0);

    float3 cyan = float3(0.20, 0.96, 1.0);
    float3 aqua = float3(0.03, 0.72, 1.0);
    float3 blue = float3(0.015, 0.42, 1.0);
    float3 deepBlue = float3(0.00, 0.13, 0.92);
    float3 electric = float3(0.22, 0.82, 1.0);

    // #1D7DFF
    float3 targetBlue = float3(0.1137, 0.4902, 1.0);

    // --------------------------------------------------
    // Idle shockwave
    // --------------------------------------------------

    float idleWaveFade = 1.0 - smoothstep(0.0, 0.045, progress);

    float idlePeriod = 3.0;
    float idleCycleRaw = fract(time / idlePeriod);
    float idleCycle = smootherLiquid(idleCycleRaw);

    float idleWaveVisibility =
        smoothstep(0.02, 0.11, idleCycleRaw) *
        (1.0 - smoothstep(0.88, 1.0, idleCycleRaw)) *
        idleWaveFade;

    float idleWaveY = mix(-110.0, 925.0, idleCycle);

    float idleWidth = mix(72.0, 420.0, idleCycle);
    float idleThickness = mix(19.0, 42.0, idleCycle);

    float idleDx = p.x - 187.5;

    float idleArcY =
        idleWaveY +
        (idleDx * idleDx) / max(idleWidth * 1.72, 1.0);

    float idleWaveDist = p.y - idleArcY;

    float idleMainWave =
        exp(-pow(idleWaveDist / idleThickness, 2.0)) *
        exp(-pow(idleDx / idleWidth, 2.0));

    float idleSecondWave =
        exp(-pow((idleWaveDist + 72.0) / (idleThickness * 1.35), 2.0)) *
        exp(-pow(idleDx / (idleWidth * 1.18), 2.0)) *
        0.42;

    float idleThirdWave =
        exp(-pow((idleWaveDist + 132.0) / (idleThickness * 1.75), 2.0)) *
        exp(-pow(idleDx / (idleWidth * 1.32), 2.0)) *
        0.20;

    float idleConeGlow =
        exp(-pow((p.y - idleWaveY) / 180.0, 2.0)) *
        exp(-pow(idleDx / max(idleWidth * 1.18, 1.0), 2.0)) *
        0.18;

    float idleWaveEnergy =
        clamp(
            idleMainWave +
            idleSecondWave +
            idleThirdWave +
            idleConeGlow,
            0.0,
            1.0
        ) *
        idleWaveVisibility;

    // --------------------------------------------------
    // Continuous upward motion
    // --------------------------------------------------

    float baseRise = progress * (0.42 + 0.58 * progress);
    float smoothRise = smootherLiquid(progress);

    // Чуть медленнее в середине, чтобы после 50% градиент не исчезал быстро.
    float rise = mix(baseRise, smoothRise, 0.34);

    float finalLiftBoost = segmentEase(progress, 0.74, 1.00);
    float lateLiftBoost = segmentEase(progress, 0.88, 1.00);

    float circleGrowth = smootherLiquid(progress);

    float2 center = float2(187.5, 406.0);
    float circleAppear = smoothstep(0.025, 0.12, progress);
    float circleRadius = mix(74.0, 178.0, circleGrowth);

    float bottomCleanProgress = segmentEase(progress, 0.42, 1.00);
    float topCapProgress = segmentEase(progress, 0.82, 1.00);
    float topReservoirProgress = segmentEase(progress, 0.58, 1.00);

    float completionBloom = segmentEase(progress, 0.96, 1.00);
    float completed = smoothstep(0.995, 1.0, progress);

    // Медленнее до 70–80%, но в финале всё равно улетает выше.
    float globalLift =
        mix(0.0, 1380.0, rise) +
        260.0 * finalLiftBoost +
        540.0 * lateLiftBoost;

    float initialDrop = 350.0 * (1.0 - rise);

    float finalBlur = segmentEase(progress, 0.70, 1.00);
    float completionMistProgress = segmentEase(progress, 0.84, 1.00);

    float completionFlash =
        segmentEase(progress, 0.965, 0.992) *
        (1.0 - segmentEase(progress, 0.992, 1.00));

    // Позже начинаем растворять градиент.
    float lateTransparency = segmentEase(progress, 0.90, 1.00);

    float mainFinalFade = mix(1.0, 0.62, lateTransparency);
    float rimFinalFade = mix(1.0, 0.44, lateTransparency);
    float finalFade = mainFinalFade;

    // Делаем градиент более вытянутым в первой половине
    // и чуть компактнее к финалу, но мягче, чем раньше.
    float shrinkAfterHalf = segmentEase(progress, 0.64, 1.00);

    float stretchFactor = mix(
        0.30,
        0.64,
        shrinkAfterHalf
    );

    float2 pStretched = float2(
        p.x,
        406.0 + (p.y - 406.0) * stretchFactor
    );

    // --------------------------------------------------
    // Bottom clearing mask
    // --------------------------------------------------

    float clearEdgeY = mix(1060.0, 225.0, bottomCleanProgress);
    float clearFeather = mix(205.0, 360.0, bottomCleanProgress);

    float clearWave =
        24.0 * sin(p.x * 0.018 + time * 0.50 + rise * 2.0) +
        15.0 * sin(p.x * 0.041 - time * 0.36 + rise * 4.0) +
        8.0  * sin((p.x + p.y) * 0.020 + time * 0.22);

    float bottomClear = smoothstep(
        clearEdgeY - clearFeather,
        clearEdgeY + clearFeather,
        p.y + clearWave
    );

    float bottomOnly = smoothstep(0.38, 1.0, uv.y);
    bottomClear *= bottomOnly;

    // --------------------------------------------------
    // Organic liquid reveal edge
    // --------------------------------------------------

    float revealEdgeY = mix(910.0, -1450.0, rise);

    // Граница сверху и снизу мягче.
    float revealFeather = mix(
        140.0,
        360.0 + 340.0 * finalBlur,
        rise
    );

    float revealWaveA =
        34.0 * sin(p.x * 0.013 + time * 0.42 + rise * 2.1);

    float revealWaveB =
        18.0 * sin(p.x * 0.031 - time * 0.56 + rise * 3.4);

    float revealWaveC =
        9.0 * sin(p.x * 0.071 + time * 0.33 - rise * 1.6);

    float domainWarp =
        13.0 * sin((p.x + p.y) * 0.018 + time * 0.28) +
        7.0  * sin((p.x - p.y) * 0.026 - time * 0.31);

    float blob1 =
        42.0 *
        exp(-pow((p.x - 86.0) / 72.0, 2.0)) *
        sin(time * 0.37 + rise * 2.4);

    float blob2 =
        36.0 *
        exp(-pow((p.x - 206.0) / 88.0, 2.0)) *
        sin(time * 0.29 + 1.7 + rise * 2.9);

    float blob3 =
        30.0 *
        exp(-pow((p.x - 318.0) / 76.0, 2.0)) *
        sin(time * 0.34 + 3.1 + rise * 2.2);

    float revealWave =
        revealWaveA +
        revealWaveB +
        revealWaveC +
        domainWarp +
        blob1 +
        blob2 +
        blob3;

    float edgeChaos = mix(
        0.72,
        1.0,
        smoothstep(0.12, 0.65, progress)
    );

    float liquidEdgeY = revealEdgeY - revealWave * edgeChaos;

    float bottomReveal = smoothstep(
        liquidEdgeY - revealFeather,
        liquidEdgeY + revealFeather,
        p.y
    );

    float revealEdgeDist = abs(p.y - liquidEdgeY);

    float revealEdgeGlow =
        exp(-revealEdgeDist / 38.0) *
        bottomReveal *
        (1.0 - bottomClear) *
        0.22 *
        finalFade;

    float tensionCore =
        exp(-revealEdgeDist / 15.0) *
        bottomReveal *
        (1.0 - bottomClear) *
        0.18 *
        finalFade;

    float tensionShadow =
        exp(-abs((p.y - liquidEdgeY) - 26.0) / 28.0) *
        bottomReveal *
        (1.0 - bottomClear) *
        0.10 *
        finalFade;

    float liquidRimLine =
        exp(-revealEdgeDist / 8.0) *
        bottomReveal *
        (1.0 - bottomClear) *
        finalFade;

    // --------------------------------------------------
    // Idle / completion breathing
    // --------------------------------------------------

    float idleEnergy = 1.0 - smoothstep(0.02, 0.22, progress);

    float idleVertical =
        idleEnergy *
        (
            18.0 * sin(time * 0.46) +
            9.0  * sin(time * 0.83)
        );

    float idleHorizontal =
        idleEnergy *
        (
            12.0 * sin(time * 0.38 + uv.y * 5.0) +
            6.0  * sin(time * 0.72 + uv.y * 11.0)
        );

    float horizontalDrift =
        idleHorizontal +
        9.0 * sin(progress * 3.2 + uv.y * 4.0 + time * 0.10) +
        5.0 * sin(progress * 7.0 + uv.y * 9.0 + time * 0.25) +
        completed * 4.0 * sin(time * 0.58 + uv.y * 8.0);

    float baseShiftY = globalLift - initialDrop + idleVertical;

    float2 pGlobal = pStretched + float2(horizontalDrift, baseShiftY);

    // --------------------------------------------------
    // Refraction + tap push + flow pull
    // --------------------------------------------------

    float lensDist = distance(p, center);

    float refractionZone =
        exp(-pow((lensDist - circleRadius) / 42.0, 2.0)) *
        circleAppear;

    float2 refractDir = normalize(p - center + float2(0.001, 0.001));
    float2 refractionWarp = refractDir * refractionZone * 10.0;

    float2 tapPxDesign = float2(
        tapPoint.x * design.x,
        tapPoint.y * design.y
    );

    float tapDistDesign = distance(p, tapPxDesign);

    float tapPush =
        exp(-pow(tapDistDesign * 0.0065, 2.0)) *
        tapPulse;

    float2 tapDir = normalize(p - tapPxDesign + float2(0.001, 0.001));
    float2 tapWarp = tapDir * tapPush * 16.0;

    float centerPull =
        exp(-pow((p.x - 187.5) / 140.0, 2.0));

    float verticalFlowPull =
        centerPull *
        segmentEase(progress, 0.18, 0.92) *
        34.0;

    float2 flowWarp = refractionWarp + tapWarp;

    pGlobal += flowWarp * 0.82;
    pGlobal.y += verticalFlowPull;

    float backSpeed = mix(0.70, 0.78, completed);
    float mainSpeed = mix(1.00, 0.92, completed);
    float rimSpeed = mix(1.30, 1.10, completed);

    float2 pShape1Back = pStretched + float2(horizontalDrift * 0.30, baseShiftY * backSpeed * 0.82);
    float2 pShape2Back = pStretched + float2(horizontalDrift * 0.40, baseShiftY * backSpeed * 0.96);
    float2 pWave1Back  = pStretched + float2(horizontalDrift * 0.48, baseShiftY * backSpeed * 0.92);
    float2 pWave2Back  = pStretched + float2(horizontalDrift * 0.50, baseShiftY * backSpeed * 1.04);

    float2 pShape1 = pStretched + float2(horizontalDrift * 0.55, baseShiftY * mainSpeed * 0.95);
    float2 pShape2 = pStretched + float2(horizontalDrift * 0.80, baseShiftY * mainSpeed * 1.12);
    float2 pBgUp   = pStretched + float2(horizontalDrift * 0.30, baseShiftY * mainSpeed * 0.34);
    float2 pWave1  = pStretched + float2(horizontalDrift * 1.05, baseShiftY * mainSpeed * 1.00);
    float2 pWave2  = pStretched + float2(horizontalDrift * 0.95, baseShiftY * mainSpeed * 1.16);

    float2 pRim1 = pStretched + float2(horizontalDrift * 1.28, baseShiftY * rimSpeed * 1.22);
    float2 pRim2 = pStretched + float2(horizontalDrift * 1.10, baseShiftY * rimSpeed * 1.30);

    float2 pWhite = pStretched + float2(horizontalDrift * 0.22, baseShiftY * 0.48);

    pShape1Back += flowWarp * 0.18;
    pShape2Back += flowWarp * 0.24;
    pWave1Back += flowWarp * 0.28;
    pWave2Back += flowWarp * 0.30;

    pShape1 += flowWarp * 0.50;
    pShape2 += flowWarp * 0.58;
    pWave1 += flowWarp * 0.72;
    pWave2 += flowWarp * 0.68;

    pRim1 += flowWarp * 0.95;
    pRim2 += flowWarp * 0.88;

    float2 deepWarp = float2(
        sin(p.y * 0.012 + time * 0.45) * 10.0,
        cos(p.x * 0.010 + time * 0.32) * 8.0
    );

    pShape1Back += deepWarp * 0.22;
    pShape2Back += deepWarp * 0.28;
    pWave1Back += deepWarp * 0.34;
    pWave2Back += deepWarp * 0.36;

    pShape1 += deepWarp * 0.52;
    pShape2 += deepWarp * 0.60;
    pWave1 += deepWarp * 0.78;
    pWave2 += deepWarp * 0.72;

    pRim1 += deepWarp * 1.05;
    pRim2 += deepWarp * 0.96;

    // --------------------------------------------------
    // States from specs
    // --------------------------------------------------

    LayerState bg_grad_01 = makeState(
        float2(-16.0, 553.0),
        float2(-23.0, 382.0),
        float2(5.0, 439.0),
        float2(35.0, 154.0),

        float2(408.0, 308.0),
        float2(430.0, 326.0),
        float2(366.0, 281.0),
        float2(306.0, 230.0),

        0.70, 0.70, 0.30, 0.70,
        128.0, 200.0, 128.0, 156.0,
        progress
    );

    LayerState bg_grad_03 = makeState(
        float2(-78.0, 215.0),
        float2(49.0, 425.0),
        float2(53.0, 408.0),
        float2(98.0, 288.0),

        float2(532.0, 487.0),
        float2(278.0, 406.0),
        float2(272.0, 207.0),
        float2(180.0, 87.0),

        0.70, 0.70, 0.70, 0.70,
        128.0, 240.0, 120.0, 140.0,
        progress
    );

    LayerState bg_grad_04 = makeState(
        float2(-1.0, 464.0),
        float2(53.0, 455.0),
        float2(-26.0, 321.0),
        float2(39.0, 241.0),

        float2(374.0, 355.0),
        float2(274.0, 328.0),
        float2(432.0, 399.0),
        float2(302.0, 176.0),

        0.30, 0.30, 0.30, 0.30,
        128.0, 128.0, 128.0, 128.0,
        progress
    );

    LayerState anim_wave_1 = makeState(
        float2(-38.0, 647.0),
        float2(-238.0, 476.0),
        float2(-121.0, 411.0),
        float2(-117.0, 151.0),

        float2(454.0, 300.0),
        float2(851.0, 562.0),
        float2(619.0, 409.0),
        float2(611.0, 405.0),

        1.00, 0.70, 1.00, 1.00,
        64.0, 64.0, 120.0, 160.0,
        progress
    );

    LayerState anim_wave_2 = makeState(
        float2(-99.0, 364.0),
        float2(-99.0, 442.0),
        float2(-218.0, 197.0),
        float2(-106.0, -107.0),

        float2(556.0, 298.0),
        float2(573.0, 307.0),
        float2(875.0, 466.0),
        float2(589.0, 316.0),

        1.00, 1.00, 1.00, 1.00,
        128.0, 160.0, 120.0, 88.0,
        progress
    );

    LayerState bg_up_02 = makeState(
        float2(-50.0, 37.0),
        float2(-32.0, 37.0),
        float2(-50.0, 37.0),
        float2(-50.0, 37.0),

        float2(475.0, 787.0),
        float2(440.0, 787.0),
        float2(475.0, 787.0),
        float2(475.0, 787.0),

        0.10, 1.00, 1.00, 1.00,
        64.0, 120.0, 64.0, 64.0,
        progress
    );

    LayerState shape_2 = makeState(
        float2(0.0, 705.0),
        float2(-44.0, 856.0),
        float2(-67.0, 663.0),
        float2(-50.0, 702.0),

        float2(375.0, 251.0),
        float2(463.0, 309.0),
        float2(509.0, 340.0),
        float2(475.0, 317.0),

        0.60, 0.70, 0.20, 1.00,
        88.0, 88.0, 88.0, 88.0,
        progress
    );

    LayerState shape_1 = makeState(
        float2(-50.0, 308.0),
        float2(-24.0, 351.0),
        float2(11.0, 78.0),
        float2(-50.0, 308.0),

        float2(475.0, 787.0),
        float2(423.0, 701.0),
        float2(353.0, 585.0),
        float2(475.0, 787.0),

        1.00, 1.00, 0.40, 1.00,
        64.0, 64.0, 146.0, 65.0,
        progress
    );

    // --------------------------------------------------
    // Back liquid layer
    // --------------------------------------------------

    float backShape1 = blueTrapField(
        pShape1Back,
        shape_1,
        87.3259 / 475.0,
        379.735 / 475.0,
        0.0,
        1.0,
        709.291 / 787.0,
        17.4917 / 787.0,
        0.72
    );

    float backShape2 = blueTrapField(
        pShape2Back,
        shape_2,
        68.9415 / 375.0,
        299.791 / 375.0,
        0.0,
        1.0,
        226.216 / 251.0,
        5.57866 / 251.0,
        0.62
    );

    float backWave1 = blueTrapField(
        pWave1Back,
        anim_wave_1,
        0.0,
        1.0,
        91.0529 / 454.0,
        370.535 / 454.0,
        29.6222 / 300.0,
        293.332 / 300.0,
        0.72
    );

    float backWave2 = blueTrapField(
        pWave2Back,
        anim_wave_2,
        111.51 / 556.0,
        453.783 / 556.0,
        0.0,
        1.0,
        268.575 / 298.0,
        6.62328 / 298.0,
        0.78
    );

    float backMass = backShape1 + backShape2 + backWave1 + backWave2;
    float backAlpha = 1.0 - exp(-backMass * 0.86);
    backAlpha = clamp(backAlpha * bottomReveal * finalFade, 0.0, 1.0);

    // --------------------------------------------------
    // Main liquid layer
    // --------------------------------------------------

    float shape1Field = blueTrapField(
        pShape1,
        shape_1,
        87.3259 / 475.0,
        379.735 / 475.0,
        0.0,
        1.0,
        709.291 / 787.0,
        17.4917 / 787.0,
        1.08
    );

    float shape2Field = blueTrapField(
        pShape2,
        shape_2,
        68.9415 / 375.0,
        299.791 / 375.0,
        0.0,
        1.0,
        226.216 / 251.0,
        5.57866 / 251.0,
        0.96
    );

    float bgUpField = blueTrapField(
        pBgUp,
        bg_up_02,
        0.0,
        1.0,
        87.3259 / 475.0,
        379.735 / 475.0,
        77.709 / 787.0,
        769.508 / 787.0,
        1.03
    );

    float wave2Field = blueTrapField(
        pWave2,
        anim_wave_2,
        111.51 / 556.0,
        453.783 / 556.0,
        0.0,
        1.0,
        268.575 / 298.0,
        6.62328 / 298.0,
        1.25
    );

    float wave1Field = blueTrapField(
        pWave1,
        anim_wave_1,
        0.0,
        1.0,
        91.0529 / 454.0,
        370.535 / 454.0,
        29.6222 / 300.0,
        293.332 / 300.0,
        1.18
    );

    float svgBlueMass =
        shape1Field +
        shape2Field +
        bgUpField +
        wave1Field +
        wave2Field;

    float mainAlpha = 1.0 - exp(-svgBlueMass * 1.28);
    mainAlpha = clamp(mainAlpha * bottomReveal * finalFade, 0.0, 1.0);

    // --------------------------------------------------
    // Front rim liquid layer
    // --------------------------------------------------

    float rimWave1 = blueTrapField(
        pRim1,
        anim_wave_1,
        0.0,
        1.0,
        91.0529 / 454.0,
        370.535 / 454.0,
        29.6222 / 300.0,
        293.332 / 300.0,
        1.05
    );

    float rimWave2 = blueTrapField(
        pRim2,
        anim_wave_2,
        111.51 / 556.0,
        453.783 / 556.0,
        0.0,
        1.0,
        268.575 / 298.0,
        6.62328 / 298.0,
        0.98
    );

    float rimAlpha = clamp((rimWave1 + rimWave2) * bottomReveal * rimFinalFade, 0.0, 1.0);
    rimAlpha = smoothstep(0.22, 0.88, rimAlpha);

    float massBreath =
        1.0 +
        0.025 * sin(time * 0.72) +
        0.014 * sin(time * 1.13);

    mainAlpha = clamp(mainAlpha * massBreath, 0.0, 1.0);
    backAlpha = clamp(backAlpha * (1.0 + 0.018 * sin(time * 0.55 + 1.2)), 0.0, 1.0);
    rimAlpha = clamp(rimAlpha * (1.0 + 0.016 * sin(time * 0.80 + 2.1)), 0.0, 1.0);

    float lateAlphaFade = lateTransparency;

    mainAlpha *= mix(1.0, 0.54, lateAlphaFade);
    backAlpha *= mix(1.0, 0.48, lateAlphaFade);
    rimAlpha *= mix(1.0, 0.36, lateAlphaFade);

    // --------------------------------------------------
    // White SVG masks
    // --------------------------------------------------

    float white1 = whiteTrapField(
        pWhite,
        bg_grad_01,
        0.0,
        1.0,
        122.692 / 408.0,
        256.095 / 408.0,
        0.72
    );

    float white3 = whiteRectField(
        pWhite,
        bg_grad_03,
        0.48
    );

    float white4 = whiteRectField(
        pWhite,
        bg_grad_04,
        0.28
    );

    float whiteSvgMass = clamp(
        white1 + white3 + white4,
        0.0,
        1.0
    );

    // --------------------------------------------------
    // Liquid color model
    // --------------------------------------------------

    float flow =
        0.023 * sin(pGlobal.x * 0.030 + time * 0.75 + rise * 2.2) +
        0.016 * sin(pGlobal.x * 0.070 - time * 0.55 + rise * 3.7) +
        0.011 * sin((pGlobal.x + pGlobal.y) * 0.035 + time * 0.45);

    float liquidY = clamp(
        uv.y * 0.74 + 0.14 + flow - rise * 0.14,
        0.0,
        1.0
    );

    // --------------------------------------------------
    // Delayed blue color ramp
    // --------------------------------------------------

    float blueEmergence = segmentEase(progress, 0.40, 0.56);
    float deepBlueEmergence = segmentEase(progress, 0.54, 0.78);
    float earlySoftness = 1.0 - blueEmergence;

    float targetBluePhase =
        segmentEase(progress, 0.50, 0.62) *
        (1.0 - segmentEase(progress, 0.80, 0.94));

    float3 softAqua = mix(
        cyan,
        aqua,
        0.62
    );

    float3 softBlue = mix(
        aqua,
        targetBlue,
        0.46
    );

    float3 backColor = mix(
        softAqua,
        softBlue,
        smoothstep(0.16, 0.88, liquidY) * blueEmergence
    );

    backColor = mix(
        backColor,
        targetBlue,
        targetBluePhase * 0.72
    );

    backColor = mix(
        backColor,
        mix(targetBlue, deepBlue, 0.26),
        smoothstep(0.78, 1.0, liquidY) * deepBlueEmergence * 0.38
    );

    float3 mainColor = mix(
        cyan,
        aqua,
        smoothstep(0.02, 0.48, liquidY)
    );

    mainColor = mix(
        mainColor,
        softBlue,
        smoothstep(0.34, 0.78, liquidY) * blueEmergence
    );

    mainColor = mix(
        mainColor,
        targetBlue,
        smoothstep(0.44, 0.88, liquidY) * blueEmergence * 0.78
    );

    mainColor = mix(
        mainColor,
        targetBlue,
        targetBluePhase * 0.86
    );

    mainColor = mix(
        mainColor,
        mix(targetBlue, deepBlue, 0.22),
        smoothstep(0.78, 1.0, liquidY) * deepBlueEmergence * 0.42
    );

    mainColor = mix(
        mainColor,
        mix(cyan, aqua, 0.54),
        earlySoftness * 0.38
    );

    backColor = mix(
        backColor,
        mix(cyan, aqua, 0.46),
        earlySoftness * 0.32
    );

    float3 rimColor = mix(
        electric,
        cyan,
        smoothstep(0.0, 1.0, liquidY)
    );

    rimColor = mix(
        rimColor,
        mix(cyan, aqua, 0.52),
        earlySoftness * 0.28
    );

    rimColor = mix(
        rimColor,
        mix(targetBlue, cyan, 0.22),
        targetBluePhase * 0.56
    );

    float causticA =
        sin(pGlobal.x * 0.021 + pGlobal.y * 0.008 + time * 0.52) *
        sin(pGlobal.x * 0.010 - pGlobal.y * 0.014 - time * 0.34);

    float causticB =
        sin((pGlobal.x + pGlobal.y) * 0.016 + time * 0.28) *
        sin(pGlobal.x * 0.012 + time * 0.44);

    float causticC =
        sin(pGlobal.x * 0.007 + pGlobal.y * 0.018 - time * 0.22) *
        sin((pGlobal.x - pGlobal.y) * 0.010 + time * 0.31);

    float broadCausticA =
        smoothstep(0.48, 1.0, causticA * 0.5 + 0.5);

    float broadCausticB =
        smoothstep(0.52, 1.0, causticB * 0.5 + 0.5);

    float broadCausticC =
        smoothstep(0.56, 1.0, causticC * 0.5 + 0.5);

    float caustics =
        broadCausticA * 0.42 +
        broadCausticB * 0.34 +
        broadCausticC * 0.24;

    caustics *= mainAlpha * (1.0 - bottomClear) * 0.075;

    float shimmer =
        sin(pGlobal.x * 0.035 + pGlobal.y * 0.020 + time * 0.90) *
        sin(pGlobal.x * 0.018 - time * 0.65);

    shimmer = shimmer * 0.5 + 0.5;
    shimmer = smoothstep(0.80, 1.0, shimmer) * 0.045;

    mainColor += shimmer * float3(0.28, 0.78, 1.0);

    float3 result = white;

    result = plusDarkerApprox(
        result,
        backColor,
        backAlpha * 0.72
    );

    result = plusDarkerApprox(
        result,
        mainColor,
        mainAlpha
    );

    result += rimColor * rimAlpha * 0.08;
    result += caustics * float3(0.42, 0.96, 1.0) * finalFade;

    float highlight =
        smoothstep(
            0.58,
            1.0,
            sin(pGlobal.x * 0.010 + pGlobal.y * 0.016 + time * 0.62) * 0.5 + 0.5
        );

    float highlightSoft =
        smoothstep(
            0.42,
            1.0,
            sin(pGlobal.x * 0.006 - pGlobal.y * 0.011 + time * 0.38) * 0.5 + 0.5
        );

    highlight = highlight * 0.62 + highlightSoft * 0.38;
    highlight *= mainAlpha * 0.038;

    result += highlight * float3(0.50, 0.94, 1.0);

    // --------------------------------------------------
    // Idle wave render
    // --------------------------------------------------

    float idleLuminanceBefore = dot(result, float3(0.299, 0.587, 0.114));

    float idleBlueOnWhite =
        idleWaveEnergy *
        smoothstep(0.56, 1.0, idleLuminanceBefore);

    float idleWhiteOnBlue =
        idleWaveEnergy *
        (1.0 - smoothstep(0.35, 0.88, idleLuminanceBefore));

    result = mix(
        result,
        min(result, float3(0.10, 0.56, 1.0)),
        idleBlueOnWhite * 0.22
    );

    result += idleBlueOnWhite * float3(0.02, 0.24, 0.92) * 0.08;
    result += idleWhiteOnBlue * float3(0.72, 1.00, 1.0) * 0.14;
    result += idleWaveEnergy * float3(0.18, 0.72, 1.0) * 0.10;

    // --------------------------------------------------
    // Organic reveal edge glow + surface tension
    // --------------------------------------------------

    result += revealEdgeGlow * float3(0.25, 0.82, 1.0);
    result += revealEdgeGlow * float3(0.75, 1.00, 1.0) * 0.32;

    result += tensionCore * float3(0.56, 1.00, 1.0) * 0.34;

    result += liquidRimLine * float3(0.75, 1.0, 1.0) * 0.18;
    result += liquidRimLine * float3(0.10, 0.55, 1.0) * 0.08;

    result = plusDarkerApprox(
        result,
        deepBlue,
        tensionShadow * 0.18
    );

    // --------------------------------------------------
    // Surface glow
    // --------------------------------------------------

    float liquidAlpha = clamp(mainAlpha + backAlpha * 0.52, 0.0, 1.0);
    float surfaceEnergy = liquidAlpha * (1.0 - liquidAlpha);

    float surfaceGlow = smoothstep(0.08, 0.25, surfaceEnergy);

    result += surfaceGlow * float3(0.10, 0.56, 1.0) * 0.10 * finalFade;
    result += surfaceGlow * float3(0.56, 1.00, 1.0) * 0.045 * finalFade;

    // --------------------------------------------------
    // Bottom clearing
    // --------------------------------------------------

    float bottomClearPower = mix(
        0.62,
        1.0,
        bottomCleanProgress
    );

    result = plusLighterApprox(
        result,
        white,
        bottomClear * bottomClearPower
    );

    liquidAlpha *= (1.0 - bottomClear * 0.82);

    // --------------------------------------------------
    // Central white glass lens
    // --------------------------------------------------

    float circleSoftness = mix(
        38.0,
        92.0,
        circleGrowth
    );

    float angle = atan2(
        p.y - center.y,
        p.x - center.x
    );

    float circleNoiseFade = 1.0 - segmentEase(progress, 0.88, 1.00);

    float circleNoise =
        (
            4.2 * sin(angle * 3.0 + time * 0.50) +
            2.6 * sin(angle * 7.0 - time * 0.38)
        ) * circleNoiseFade;

    float circleDist =
        distance(p, center) -
        circleRadius +
        circleNoise;

    float circleFill = 1.0 - smoothstep(
        -circleSoftness * 0.52,
        circleSoftness,
        circleDist
    );

    float circleVisibility = mix(
        0.68,
        0.98,
        smoothstep(0.0, 0.75, progress)
    );

    float visibleCircleFill = circleFill * circleAppear;

    float whiteMask = clamp(
        visibleCircleFill * circleVisibility + whiteSvgMass * 0.28,
        0.0,
        1.0
    );

    result = plusLighterApprox(
        result,
        white,
        whiteMask
    );

    float circleEdge = exp(-abs(circleDist) / 30.0);
    float tightCircleRim = exp(-abs(circleDist) / 10.0);

    float innerRim = circleEdge * visibleCircleFill * 0.20;

    result += innerRim * float3(0.35, 0.88, 1.0);

    float lensLowerShadow =
        visibleCircleFill *
        smoothstep(center.y - circleRadius * 0.10, center.y + circleRadius * 0.72, p.y) *
        0.055;

    result = mix(
        result,
        result * float3(0.965, 0.985, 1.0),
        lensLowerShadow
    );

    float contactGlow =
        circleEdge *
        liquidAlpha *
        circleAppear *
        (1.0 - circleFill * 0.38);

    float contactTightRim =
        tightCircleRim *
        liquidAlpha *
        circleAppear *
        (1.0 - circleFill * 0.22);

    float magneticPull = segmentEase(progress, 0.35, 0.85);

    float chromaticEdge =
        tightCircleRim *
        liquidAlpha *
        circleAppear *
        (0.35 + 0.65 * magneticPull);

    // Лёгкая хроматическая аберрация при столкновении с центральной маской.
    float2 dirFromCenter = normalize(p - center + float2(0.0001, 0.0001));
    float2 chromaAxis = normalize(float2(0.86, -0.34));

    float chromaDot = dot(dirFromCenter, chromaAxis);
    float redSide = smoothstep(-0.15, 1.0, chromaDot);
    float cyanSide = smoothstep(-0.15, 1.0, -chromaDot);

    result.r += chromaticEdge * redSide * 0.010 * finalFade;
    result.g += chromaticEdge * cyanSide * 0.010 * finalFade;
    result.b += chromaticEdge * cyanSide * 0.022 * finalFade;

    result += contactGlow * float3(0.12, 0.68, 1.0) * (0.76 + magneticPull * 0.18) * finalFade;
    result += contactGlow * float3(0.68, 1.00, 1.0) * (0.30 + magneticPull * 0.12) * finalFade;
    result += contactTightRim * float3(0.72, 1.00, 1.0) * (0.22 + magneticPull * 0.10) * finalFade;

    float innerHalo = exp(
        -max(distance(p, center) - circleRadius * 0.54, 0.0) / 78.0
    );

    result = mix(
        result,
        white,
        innerHalo * 0.11 * circleVisibility * circleAppear
    );

    // --------------------------------------------------
    // Tap blob / residual trail
    // --------------------------------------------------

    float2 tapPx = tapPoint * size;
    float tapDist = distance(position, tapPx);

    float tapTrail =
        exp(-pow(tapDist * 0.010, 2.0)) *
        tapPulse *
        mainAlpha *
        0.10;

    float tapBlobNoise =
        sin(position.x * 0.035 + time * 1.8) *
        sin(position.y * 0.026 - time * 1.3);

    tapTrail *= smoothstep(-0.15, 0.75, tapBlobNoise);

    result += tapTrail * float3(0.26, 0.88, 1.0) * finalFade;

    // --------------------------------------------------
    // Top reservoir + cinematic finish
    // --------------------------------------------------

    float3 stableFinishColor = mix(
        targetBlue,
        cyan,
        0.18
    );

    float3 initialBottomLikeColor = stableFinishColor;

    float topBreath =
        1.0 +
        completed *
        (
            0.08 * sin(time * 1.55) +
            0.035 * sin(time * 2.25)
        );

    float finalCoreSoft = 1.0 - 0.50 * finalBlur;
    float finalMistBoost = 1.0 + 1.25 * finalBlur;

    float topReservoir =
        exp(-uv.y * 3.20) *
        topReservoirProgress *
        0.38 *
        topBreath *
        finalFade *
        finalCoreSoft;

    float topReservoirCore =
        exp(-uv.y * 7.00) *
        topReservoirProgress *
        0.30 *
        topBreath *
        finalFade *
        finalCoreSoft;

    float topReservoirGlow =
        exp(-pow((uv.y - 0.125) / 0.26, 2.0)) *
        topReservoirProgress *
        0.13 *
        topBreath *
        finalFade *
        finalMistBoost;

    result = plusDarkerApprox(
        result,
        initialBottomLikeColor,
        topReservoir
    );

    result = plusDarkerApprox(
        result,
        mix(targetBlue, deepBlue, 0.18),
        topReservoirCore
    );

    result += topReservoirGlow * float3(0.22, 0.80, 1.0);

    float finish = topCapProgress;

    float topCapAlpha =
        exp(-uv.y * 4.8) *
        finish *
        0.34 *
        topBreath *
        finalFade *
        finalCoreSoft;

    float topCapMist =
        exp(-uv.y * 1.22) *
        finish *
        0.13 *
        topBreath *
        finalFade *
        finalMistBoost;

    result = plusDarkerApprox(
        result,
        initialBottomLikeColor,
        topCapAlpha
    );

    result = plusDarkerApprox(
        result,
        mix(targetBlue, deepBlue, 0.14),
        topCapMist
    );

    result += topCapAlpha * float3(0.10, 0.46, 1.0) * 0.10;
    result += topCapMist * float3(0.42, 0.95, 1.0) * 0.045;

    float3 completionMistColor = mix(
        targetBlue,
        cyan,
        0.22
    );

    float completionMist =
        exp(-uv.y * 1.05) *
        completionMistProgress *
        0.12 *
        finalFade *
        finalMistBoost;

    float trailingGlow =
        exp(-pow((uv.y - 0.18) / 0.22, 2.0)) *
        finalBlur *
        0.10 *
        finalFade;

    result += completionMist * completionMistColor;
    result += trailingGlow * float3(0.30, 0.92, 1.0);

    result += completionFlash * float3(0.45, 0.95, 1.0) * 0.08;

    float completionPulse =
        completionBloom *
        (1.0 - 0.35 * sin(time * 2.4));

    float completionTopGlow =
        exp(-uv.y * 4.2) *
        completionPulse *
        0.12 *
        finalFade;

    result += completionTopGlow * float3(0.30, 0.82, 1.0);
    result = mix(result, white, completionBloom * bottomClear * 0.08);

    // --------------------------------------------------
    // Adaptive tap shockwave
    // --------------------------------------------------

    float rippleRadius = (1.0 - tapPulse) * 112.0;

    float rippleRing =
        exp(-pow((tapDist - rippleRadius) * 0.030, 2.0)) *
        tapPulse;

    float rippleCore =
        exp(-pow(tapDist * 0.016, 2.0)) *
        tapPulse *
        0.14;

    float luminance = dot(result, float3(0.299, 0.587, 0.114));

    float blueRingStrength = rippleRing * smoothstep(0.60, 1.0, luminance);
    float whiteRingStrength = rippleRing * (1.0 - smoothstep(0.40, 0.90, luminance));

    result = mix(
        result,
        min(result, float3(0.12, 0.56, 1.0)),
        blueRingStrength * 0.16
    );

    result += blueRingStrength * float3(0.02, 0.22, 0.82) * 0.04;

    result += whiteRingStrength * float3(0.75, 1.00, 1.0) * 0.12;
    result += rippleCore * float3(0.30, 0.86, 1.0) * 0.07;

    // --------------------------------------------------
    // Keyframe-matched hero wash
    // --------------------------------------------------

    float keyProgress = clamp(progress, 0.0, 0.82);
    float keyPresence = smoothstep(0.02, 0.18, keyProgress);

    float keyedEdgeY = interpKeys(
        0.86,
        0.62,
        0.38,
        -0.10,
        keyProgress
    );

    float keyedFeather = interpKeys(
        0.16,
        0.23,
        0.34,
        0.28,
        keyProgress
    );

    float keyDx = uv.x - 0.5;

    float keyedSag =
        keyDx * keyDx *
        interpKeys(0.26, 0.32, 0.24, -0.30, keyProgress);

    float keyedEdgeNoise =
        0.012 * sin(uv.x * 9.0 + time * 0.24 + keyProgress * 4.0) +
        0.007 * sin(uv.x * 21.0 - time * 0.16 + keyProgress * 7.0);

    float keyedLowerMass = smoothstep(
        keyedEdgeY - keyedFeather,
        keyedEdgeY + keyedFeather,
        uv.y + keyedSag + keyedEdgeNoise
    );

    float lowerFade = 1.0 - segmentEase(keyProgress, 0.62, 0.90);
    keyedLowerMass *= keyPresence * lowerFade;

    float keyedBottomWeight = smoothstep(0.28, 0.96, uv.y);
    float keyedLowerCore = keyedLowerMass * keyedBottomWeight * 0.88;

    float keyedCyanBand =
        exp(-pow((uv.y - keyedEdgeY) / max(keyedFeather * 1.18, 0.01), 2.0)) *
        exp(-pow(keyDx / 0.62, 2.0)) *
        keyPresence *
        lowerFade;

    float3 keyedBlueColor = mix(
        targetBlue,
        blue,
        0.10 + 0.18 * smoothstep(0.20, 0.46, keyProgress)
    );

    keyedBlueColor = mix(
        keyedBlueColor,
        mix(targetBlue, deepBlue, 0.12),
        smoothstep(0.50, 0.74, keyProgress) * smoothstep(0.58, 1.0, uv.y)
    );

    float3 keyedLowerColor = mix(
        mix(cyan, aqua, 0.50),
        keyedBlueColor,
        smoothstep(0.48, 1.0, uv.y)
    );

    result = plusDarkerApprox(
        result,
        keyedLowerColor,
        keyedLowerCore * 0.42
    );

    result += keyedCyanBand * float3(0.62, 1.0, 1.0) * 0.17;

    float lensY = interpKeys(
        0.74,
        0.56,
        0.59,
        0.31,
        keyProgress
    );

    float lensRX = interpKeys(
        0.55,
        0.62,
        0.60,
        0.57,
        keyProgress
    );

    float lensRY = interpKeys(
        0.21,
        0.18,
        0.20,
        0.19,
        keyProgress
    );

    float lensTopFade =
        smoothstep(0.08, 0.24, keyProgress) *
        (1.0 - segmentEase(keyProgress, 0.88, 1.0));

    float lensD =
        pow((uv.x - 0.5) / max(lensRX, 0.01), 2.0) +
        pow((uv.y - lensY) / max(lensRY, 0.01), 2.0);

    float keyedWhiteLens =
        (1.0 - smoothstep(0.56, 1.48, lensD)) *
        lensTopFade;

    float keyedLensHalo =
        exp(-pow((sqrt(max(lensD, 0.0)) - 0.88) / 0.46, 2.0)) *
        lensTopFade;

    result = plusLighterApprox(
        result,
        white,
        keyedWhiteLens * 0.58
    );

    result += keyedLensHalo * float3(0.66, 1.0, 1.0) * 0.12;

    float topPhase =
        segmentEase(keyProgress, 0.58, 0.84) *
        (1.0 - segmentEase(keyProgress, 0.94, 1.0));

    float topCurve =
        0.24 +
        keyDx * keyDx * 0.62 +
        0.011 * sin(uv.x * 8.0 + time * 0.20);

    float topCap =
        (1.0 - smoothstep(topCurve - 0.16, topCurve + 0.24, uv.y)) *
        topPhase;

    float topCore =
        exp(-uv.y * 3.1) *
        topPhase;

    float topMistBand =
        exp(-pow((uv.y - topCurve) / 0.26, 2.0)) *
        exp(-pow(keyDx / 0.78, 2.0)) *
        topPhase;

    float3 topKeyColor = mix(
        targetBlue,
        blue,
        0.16
    );

    result = plusDarkerApprox(
        result,
        topKeyColor,
        clamp(topCap * 0.46 + topCore * 0.12, 0.0, 1.0)
    );

    result += topMistBand * float3(0.56, 1.0, 1.0) * 0.13;

    float topWhiteBowl =
        (1.0 - smoothstep(0.62, 1.30, lensD)) *
        topPhase *
        0.70;

    result = plusLighterApprox(
        result,
        white,
        topWhiteBowl
    );

    float grainMask = clamp(
        liquidAlpha +
        backAlpha * 0.55 +
        mainAlpha * 0.35 +
        topReservoirProgress * 0.30 +
        idleWaveEnergy * 0.30,
        0.0,
        1.0
    );

    float grain = (hashLiquid(position + float2(time * 0.37)) - 0.5);

    result += grain * mix(0.0012, 0.0052, grainMask) * finalFade;

    return half4(
        half3(clamp(result, 0.0, 1.0)),
        1.0
    );
}
