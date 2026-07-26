// =============================================================================
// DASR v2.5a (Hybrid Grid-Brick Divergence + Anisotropic Surgical Low-Pass)
// Author: Baudelaire (Aston89) / Github: https://github.com/aston89/
// =============================================================================

#include "ReShade.fxh"

#define BUFFER_RCP_SIZE float2(1.0 / BUFFER_WIDTH, 1.0 / BUFFER_HEIGHT)

// =============================================================================
// BUFFERS
// =============================================================================
texture2D RiskMapBuffer { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
sampler2D RiskMapSampler { Texture = RiskMapBuffer; AddressU = Clamp; AddressV = Clamp; };

texture2D HistoryBuffer { Width = BUFFER_WIDTH; Height = BUFFER_HEIGHT; Format = RGBA16F; };
sampler2D HistorySampler { Texture = HistoryBuffer; AddressU = Clamp; AddressV = Clamp; };

// =============================================================================
// PARAMS
// =============================================================================

// ---- Core instability analysis ----
uniform float GridSensitivity < ui_type = "slider"; ui_min = 1.0; ui_max = 50.0; ui_step = 0.5; ui_label = "Grid-Brick Sensitivity"; ui_tooltip = "How strongly sampling-phase divergence should contribute to the aliasing risk."; > = 5.0;
uniform float TemporalSensitivity < ui_type = "slider"; ui_min = 1.0; ui_max = 30.0; ui_step = 0.5; ui_label = "Temporal Sensitivity"; ui_tooltip = "How strongly frame-to-frame differences should contribute to temporal shimmer risk."; > = 8.0;
uniform float MinimumAliasConfidence < ui_type = "slider"; ui_min = 0.0; ui_max = 0.5; ui_step = 0.01; ui_label = "Minimum Alias Confidence"; ui_tooltip = "Small floor added to the grid/brick detector to avoid dead zones in the risk map."; > = 0.02;
uniform float StaticSoftAmount < ui_type = "slider"; ui_min = 0.0; ui_max = 0.5; ui_step = 0.01; ui_label = "Static Anti-Shimmer Softness"; ui_tooltip = "Amount of gentle fallback smoothing when adaptive filtering is not triggered."; > = 0.12;

// ---- Adaptive filtering ----
uniform float AnisoStrength < ui_type = "slider"; ui_min = 0.0; ui_max = 3.0; ui_step = 0.1; ui_label = "Directional Filter Strength"; ui_tooltip = "Overall intensity of the adaptive directional filter. Higher values reduce shimmer more, but may soften fine edges."; > = 1.5;
uniform float GridFloorStrength < ui_type = "slider"; ui_min = 0.0; ui_max = 0.2; ui_step = 0.01; ui_label = "Grid Detector Floor"; ui_tooltip = "Minimum confidence for the geometric instability detector."; > = 0.02;
uniform float TensorMinimumStrength < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05; ui_label = "Tensor Minimum Influence"; ui_tooltip = "Minimum amount of filtering applied when the structure tensor confidence is low."; > = 0.60;
uniform float RiskThreshold < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01; ui_label = "Risk Trigger Threshold"; ui_tooltip = "Minimum risk required to activate the directional filter. Below this value, only the fallback softness is used."; > = 0.00;
uniform float AliasResponseSharpness < ui_type = "slider"; ui_min = 0.5; ui_max = 5.0; ui_step = 0.1; ui_label = "Alias Response Curve"; ui_tooltip = "Controls how quickly the filter ramps up as aliasing confidence increases."; > = 2.0;
uniform float TapActivation < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05; ui_label = "Tap Activation Threshold"; ui_tooltip = "Risk level required to activate extra directional taps."; > = 0.5;

// ---- Depth weighting ----
uniform float DepthActivationCenter < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.01; ui_label = "Depth Midpoint"; ui_tooltip = "Center point of the depth weighting curve."; > = 0.3;
uniform float DepthSoftness < ui_type = "slider"; ui_min = 0.01; ui_max = 0.5; ui_step = 0.01; ui_label = "Depth Softness"; ui_tooltip = "Width of the depth weighting transition."; > = 0.15;
uniform float DepthMaxWeight < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05; ui_label = "Depth Max Weight"; ui_tooltip = "Maximum contribution of the depth detector."; > = 1.0;

// ---- Periodicity ----
uniform bool UsePeriodicity < ui_label = "Use Periodicity Detector"; ui_tooltip = "Enable the periodicity detector for repeated high-frequency patterns."; > = true;
uniform float PeriodicitySensitivity < ui_type = "slider"; ui_min = 0.5; ui_max = 20.0; ui_step = 0.5; ui_label = "Periodicity Sensitivity"; ui_tooltip = "How sensitive the periodicity detector should be to repeating structures."; > = 4.0;

// ---- Risk weights ----
uniform float W_GridBrick < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05; ui_label = "Weight: Grid-Brick"; ui_tooltip = "Contribution of sampling-phase divergence to the final risk map."; > = 0.45;
uniform float W_Temporal  < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05; ui_label = "Weight: Temporal"; ui_tooltip = "Contribution of temporal instability to the final risk map."; > = 0.25;
uniform float W_Periodic  < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05; ui_label = "Weight: Periodicity"; ui_tooltip = "Contribution of repeating high-frequency structures to the final risk map."; > = 0.20;
uniform float W_Depth     < ui_type = "slider"; ui_min = 0.0; ui_max = 1.0; ui_step = 0.05; ui_label = "Weight: Depth"; ui_tooltip = "Contribution of the depth-based prioritization to the final risk map."; > = 0.10;

// ---- Temporal motion heuristic ----
uniform bool UseMotionHeuristic < ui_label = "Temporal Motion Heuristic"; ui_tooltip = "Use a 1-pixel history offset along the local gradient to compensate for small camera motion."; > = true;
uniform int DebugMode < ui_type = "slider"; ui_min = 0; ui_max = 9; ui_step = 1; ui_label = "Debug Mode"; ui_tooltip = "0=Final | 1=Depth | 2=DepthWeight | 3=GridBrickDiv | 4=Periodicity | 5=TemporalRisk | 6=FinalRiskMap | 7=BlurDirection | 8=AdaptiveTaps | 9=MotionOffset"; > = 0;
uniform int FrameCount < source = "framecount"; >;

float3 GetColor(float2 uv) { return tex2D(ReShade::BackBuffer, uv).rgb; }
float GetLuma(float3 col) { return dot(col, float3(0.299, 0.587, 0.114)); }

// =============================================================================
// GRID/BRICK DIVERGENCE
// =============================================================================
float ComputeGridBrickDivergence(float2 uv, float3 centerRGB)
{
    float2 ts = BUFFER_RCP_SIZE;
    float3 r1 = GetColor(uv + float2(1.0, 0.0) * ts);
    float3 l1 = GetColor(uv - float2(1.0, 0.0) * ts);
    float3 u1 = GetColor(uv + float2(0.0, 1.0) * ts);
    float3 d1 = GetColor(uv - float2(0.0, 1.0) * ts);
    float3 r2 = GetColor(uv + float2(2.0, 0.0) * ts);
    float3 l2 = GetColor(uv - float2(2.0, 0.0) * ts);
    float3 u2 = GetColor(uv + float2(0.0, 2.0) * ts);
    float3 d2 = GetColor(uv - float2(0.0, 2.0) * ts);
    float3 tr = GetColor(uv + float2(1.0, 1.0) * ts);
    float3 tl = GetColor(uv + float2(-1.0, 1.0) * ts);
    float3 br = GetColor(uv + float2(1.0, -1.0) * ts);
    float3 bl = GetColor(uv + float2(-1.0, -1.0) * ts);

    float3 gA = (centerRGB + r2 + l2 + u2 + d2) * 0.2;
    float3 gB = (r1 + l1 + u1 + d1) * 0.25;
    float3 gC = (tr + tl + br + bl) * 0.25;

    float3 phaseAB = gA - gB;
    float3 phaseAC = gA - gC;
    float3 phaseBC = gB - gC;

    float variance = (dot(phaseAB, phaseAB) + dot(phaseAC, phaseAC) + dot(phaseBC, phaseBC)) * (1.0 / 6.0);
    return saturate(sqrt(variance) * GridSensitivity + GridFloorStrength);
}

// =============================================================================
// PERIODICITY DETECTOR
// =============================================================================
float ComputePeriodicity(float2 uv)
{
    float c  = GetLuma(GetColor(uv));
    float l1 = GetLuma(GetColor(uv - float2(1.0, 0.0) * BUFFER_RCP_SIZE));
    float r1 = GetLuma(GetColor(uv + float2(1.0, 0.0) * BUFFER_RCP_SIZE));
    float u1 = GetLuma(GetColor(uv - float2(0.0, 1.0) * BUFFER_RCP_SIZE));
    float d1 = GetLuma(GetColor(uv + float2(0.0, 1.0) * BUFFER_RCP_SIZE));
    float l2 = GetLuma(GetColor(uv - float2(2.0, 0.0) * BUFFER_RCP_SIZE));
    float r2 = GetLuma(GetColor(uv + float2(2.0, 0.0) * BUFFER_RCP_SIZE));
    float u2 = GetLuma(GetColor(uv - float2(0.0, 2.0) * BUFFER_RCP_SIZE));
    float d2 = GetLuma(GetColor(uv + float2(0.0, 2.0) * BUFFER_RCP_SIZE));
    float l4 = GetLuma(GetColor(uv - float2(4.0, 0.0) * BUFFER_RCP_SIZE));
    float r4 = GetLuma(GetColor(uv + float2(4.0, 0.0) * BUFFER_RCP_SIZE));
    float u4 = GetLuma(GetColor(uv - float2(0.0, 4.0) * BUFFER_RCP_SIZE));
    float d4 = GetLuma(GetColor(uv + float2(0.0, 4.0) * BUFFER_RCP_SIZE));

    float lapH = abs(l1 + r1 - 2.0 * c);
    float lapV = abs(u1 + d1 - 2.0 * c);
    float varH  = (abs(c - l2) + abs(c - r2)) * 0.5;
    float varV  = (abs(c - u2) + abs(c - d2)) * 0.5;
    float varH4 = (abs(c - l4) + abs(c - r4)) * 0.5;
    float varV4 = (abs(c - u4) + abs(c - d4)) * 0.5;
    float persistH = (1.0 - saturate(varH * 8.0)) * (1.0 - saturate(varH4 * 8.0));
    float persistV = (1.0 - saturate(varV * 8.0)) * (1.0 - saturate(varV4 * 8.0));

    float rawPeriodicity = max(lapH * persistH, lapV * persistV);
    float shaped = pow(saturate(rawPeriodicity * PeriodicitySensitivity), 3.0);
    return smoothstep(0.10, 0.35, shaped);
}

// =============================================================================
// STRUCTURE TENSOR
// =============================================================================
void ComputeStructureTensorDirection(float2 uv, out float2 blurDir, out float tensorConfidence)
{
    float2 ts = BUFFER_RCP_SIZE;
    float Jxx = 0.0, Jyy = 0.0, Jxy = 0.0;
    for(int x=-1; x<=1; x++) {
        for(int y=-1; y<=1; y++) {
            float2 off = float2(x, y) * ts;
            float g1 = GetLuma(GetColor(uv + off - float2(1, 0) * ts));
            float g2 = GetLuma(GetColor(uv + off + float2(1, 0) * ts));
            float g3 = GetLuma(GetColor(uv + off - float2(0, 1) * ts));
            float g4 = GetLuma(GetColor(uv + off + float2(0, 1) * ts));
            float gx = (g2 - g1) * 0.5;
            float gy = (g4 - g3) * 0.5;
            Jxx += gx * gx; Jyy += gy * gy; Jxy += gx * gy;
        }
    }
    Jxx /= 9.0; Jyy /= 9.0; Jxy /= 9.0;
    float trace = Jxx + Jyy;
    float det = Jxx * Jyy - Jxy * Jxy;
    tensorConfidence = saturate((trace * trace - 4.0 * det) / (trace * trace + 0.0001));
    float theta = 0.5 * atan2(2.0 * Jxy, Jxx - Jyy);
    float2 edgeDir = float2(cos(theta), sin(theta));
    blurDir = normalize(float2(-edgeDir.y, edgeDir.x));
}

// =============================================================================
// PASS 1: THE ORACLE
// =============================================================================
float4 PS_RiskMap(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    float3 centerCol = GetColor(uv);
    float gridBrickDiv = ComputeGridBrickDivergence(uv, centerCol);
    float periodicity = UsePeriodicity ? ComputePeriodicity(uv) : 0.0;
    float depthWeight = smoothstep(DepthActivationCenter - DepthSoftness, DepthActivationCenter + DepthSoftness, ReShade::GetLinearizedDepth(uv)) * DepthMaxWeight;
    float riskTemporal = 0.0;
    float2 motionOffset = float2(0.0, 0.0);

    if (FrameCount > 0) {
        float l1 = GetLuma(GetColor(uv - float2(1.0, 0.0) * BUFFER_RCP_SIZE));
        float r1 = GetLuma(GetColor(uv + float2(1.0, 0.0) * BUFFER_RCP_SIZE));
        float u1 = GetLuma(GetColor(uv - float2(0.0, 1.0) * BUFFER_RCP_SIZE));
        float d1 = GetLuma(GetColor(uv + float2(0.0, 1.0) * BUFFER_RCP_SIZE));
        float2 grad = float2(r1 - l1, d1 - u1);
        float gradLen = length(grad);
        float2 shiftUV = (gradLen > 0.01) ? (grad / gradLen) * BUFFER_RCP_SIZE : 0.0;
        float bestDiff = 999.0;
        float2 baseUV = uv + shiftUV;
        for (int x = -1; x <= 1; x++) {
            for (int y = -1; y <= 1; y++) {
                float diff = length(centerCol - tex2D(HistorySampler, baseUV + float2(x, y) * BUFFER_RCP_SIZE).rgb);
                if (diff < bestDiff) bestDiff = diff;
            }
        }
        riskTemporal = saturate(bestDiff * TemporalSensitivity) * gridBrickDiv;
        motionOffset = shiftUV;
    }

    float aliasStrength = saturate(gridBrickDiv * 0.60 + riskTemporal * 0.40);
    float currentAliasStrength = tex2D(HistorySampler, uv).a;
    aliasStrength = (currentAliasStrength > aliasStrength) ? lerp(currentAliasStrength, aliasStrength, 0.15) : lerp(currentAliasStrength, aliasStrength, 0.35);
    float finalRisk = saturate((gridBrickDiv * W_GridBrick + riskTemporal * W_Temporal + periodicity * W_Periodic + depthWeight * W_Depth) / max(W_GridBrick + W_Temporal + W_Periodic + W_Depth, 0.001));

    if (DebugMode == 1) return float4(ReShade::GetLinearizedDepth(uv).xxx, 1.0);
    if (DebugMode == 2) return float4(depthWeight.xxx, 1.0);
    if (DebugMode == 3) return float4(gridBrickDiv.xxx, 1.0);
    if (DebugMode == 4) return float4(periodicity.xxx, 1.0);
    if (DebugMode == 5) return float4(riskTemporal.xxx, 1.0);
    if (DebugMode == 6) return float4(finalRisk, aliasStrength, riskTemporal, 1.0);
    if (DebugMode == 9) { float m = length(motionOffset) / length(BUFFER_RCP_SIZE); return float4(m.xxx, 1.0); }
    return float4(finalRisk, aliasStrength, periodicity, aliasStrength);
}

// =============================================================================
// PASS 2: THE SURGEON
// =============================================================================
float4 PS_AnisotropicLowPass(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    if ((DebugMode >= 1 && DebugMode <= 6) || DebugMode == 9) return tex2D(RiskMapSampler, uv);
    float4 riskData = tex2D(RiskMapSampler, uv);
    if (riskData.r < RiskThreshold) {
        float3 soft = (GetColor(uv + BUFFER_RCP_SIZE * float2(1,0)) + GetColor(uv - BUFFER_RCP_SIZE * float2(1,0)) + GetColor(uv + BUFFER_RCP_SIZE * float2(0,1)) + GetColor(uv - BUFFER_RCP_SIZE * float2(0,1))) * 0.25;
        return float4(lerp(GetColor(uv), soft, StaticSoftAmount), 1.0);
    }
    float2 dir; float tensorConfidence;
    ComputeStructureTensorDirection(uv, dir, tensorConfidence);
    if (DebugMode == 7) return float4(abs(dir), 0.0, 1.0);
    
    int maxTaps = (riskData.r > TapActivation) ? 3 : ((riskData.r > TapActivation * 0.5) ? 2 : 1);
    float strength = pow(riskData.g, AliasResponseSharpness) * AnisoStrength * lerp(TensorMinimumStrength, 1.0, tensorConfidence);
    if (DebugMode == 8) { float tapNorm = float(maxTaps) / 3.0; return float4(tapNorm.xxx, 1.0); }

    float3 sum = GetColor(uv);
    float wSum = 1.0;
    for (int i = 1; i <= maxTaps; i++) {
        float w = exp(-float(i * i) * 1.5) * strength;
        sum += (GetColor(uv + dir * float(i) * BUFFER_RCP_SIZE) + GetColor(uv - dir * float(i) * BUFFER_RCP_SIZE)) * w;
        wSum += w * 2.0;
    }
    return float4(lerp(GetColor(uv), sum / wSum, saturate(strength)), 1.0);
}

// =============================================================================
// PASS 3: HISTORY COPY
// =============================================================================
float4 PS_HistoryCopy(float4 pos : SV_Position, float2 uv : TEXCOORD) : SV_Target
{
    return float4(GetColor(uv), tex2D(RiskMapSampler, uv).g);
}

// =============================================================================
// TECHNIQUE
// =============================================================================
technique DASR_v2_5a < ui_tooltip = "DASR v2.5a - Differential Anisotropic Shimmer Reductor"; > {
    pass RiskMapPass { VertexShader = PostProcessVS; PixelShader = PS_RiskMap; RenderTarget = RiskMapBuffer; }
    pass AnisotropicBlurPass { VertexShader = PostProcessVS; PixelShader = PS_AnisotropicLowPass; }
    pass HistoryCopyPass { VertexShader = PostProcessVS; PixelShader = PS_HistoryCopy; RenderTarget = HistoryBuffer; }
}
