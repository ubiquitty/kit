#version 450

// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// A verbatim port of UBShaders.metal's decorationFragment: emits the rule color
// masked by `kind` (solid = full; dotted = round balls; dashed = 65% duty;
// curly = a sine wave). A rule glyph ink cuts arrives as the pieces Core left
// standing (Core/Rendering/SkipInk.h), each laid out across the whole rule's
// band, so no glyph is sampled here. Alpha drives the blend (the decoration
// pipeline blends over the cell pass). No srgbToLinear — the CPU
// SoftwareRenderer blends in sRGB too, keeping the CPU/GPU outputs a matched
// oracle pair.
layout(location = 0) flat in vec4 inRect;
layout(location = 1) in vec4 inColor;
layout(location = 2) flat in vec4 inParams;
layout(location = 3) flat in float inBitmapTier;
layout(location = 4) flat in vec2 inCutAcross;

layout(input_attachment_index = 0, set = 1, binding = 0) uniform subpassInput uBackground;

layout(location = 0) out vec4 outColor;

const float decorationSolid = 0.0;
const float decorationDotted = 1.0;
const float decorationDashed = 2.0;
const float decorationCurly = 3.0;

void main()
{
    // The pixel's centre from the band's top-left, taken from the fragment's
    // own position rather than interpolated across the quad: the same
    // arithmetic SoftwareRenderer::compositeDecoration does, so a pattern edge
    // that lands near a pixel centre rounds the same way on both.
    precise vec2 inLocalPx = gl_FragCoord.xy - inRect.xy;
    vec2 inSizePx = inRect.zw;
    float inKind = inParams.x;
    float inCellSize = inParams.y;
    float inThickness = inParams.z;
    // The part of this pixel the piece covers across, at a cut end; all of it
    // elsewhere.
    float across = clamp(min(gl_FragCoord.x + 0.5, inCutAcross.y) - max(gl_FragCoord.x - 0.5, inCutAcross.x), 0.0, 1.0);
    float alpha = inColor.a * across;
    if (inKind == decorationDotted) {
        // Round dots the band's height across, one at the start of each
        // pitch from the band's left edge, where the run starts, (CellInstanceBuilder's patternPitch):
        // the nearer of the dot this pixel's centre lies in the pitch of and
        // the next.
        float period = inCellSize;
        float radius = inSizePx.y * 0.5;
        float along = inLocalPx.x;
        float first = floor(along / period) * period + radius;
        float deltaY = inLocalPx.y - radius;
        // A circle fitted to the pixel grid: its square's corners rounded to
        // the radius less half a pixel (dottedRuleCornerInset), so a small dot
        // is solid and a heavy one round.
        float corner = max(radius - 0.5, 0.0);
        vec2 toThis = abs(vec2(along - first, deltaY)) - (radius - corner);
        vec2 toNext = abs(vec2(along - first - period, deltaY)) - (radius - corner);
        float apart = min(length(max(toThis, 0.0)) + min(max(toThis.x, toThis.y), 0.0),
                          length(max(toNext, 0.0)) + min(max(toNext.x, toNext.y), 0.0)) - corner;
        alpha *= clamp(0.5 - apart, 0.0, 1.0);
    } else if (inKind == decorationDashed) {
        // Dashes from the band's left edge, where the run starts, at the pitch Core chose,
        // three-fifths of it on (dashedRuleOnShare): the part of this pixel
        // the dash it lies in covers, and the one before it.
        float period = inCellSize;
        float along = inLocalPx.x;
        float start = floor(along / period) * period;
        float marks = clamp(min(along + 0.5, start + 0.6 * period) - max(along - 0.5, start), 0.0, 1.0)
            + clamp(min(along + 0.5, start - 0.4 * period) - max(along - 0.5, start - period), 0.0, 1.0);
        alpha *= min(marks, 1.0);
    }
    if (inKind == decorationDashed || inKind == decorationSolid) {
        // A straight rule is drawn at its weight exactly (ruleWeight): the
        // part of this pixel's row its band covers.
        // A dash's band is the stroke itself, so the band's height is the
        // weight the thickness setting asks for. Sampling at pixel centers
        // alone answers only in whole rows, quantizing that weight to the pixel
        // grid; taking the fraction of its own row that the band covers makes
        // the summed weight the band's height exactly, at any sub-pixel size.
        // The other kinds draw a shape within a band built with slack and take
        // their edge softness from that shape's own falloff.
        float rowTop = max(inLocalPx.y - 0.5, 0.0);
        float rowBottom = min(inLocalPx.y + 0.5, inSizePx.y);
        alpha *= max(rowBottom - rowTop, 0.0);
    } else if (inKind == decorationCurly) {
        // Circular arcs half a period across, alternately crest and trough,
        // meeting on the centre line with matching tangents (CellInstanceBuilder's
        // curlyRuleProportions): the distance to the nearest of the arc
        // this pixel lies under and its two neighbours, or to an arc's end where
        // its circle's nearest point is past it.
        float period = max(inCellSize, 2.0);
        float halfWeight = inThickness * 0.5;
        float swing = max(inSizePx.y * 0.5 - halfWeight - 0.5, 0.25);
        float middle = inSizePx.y * 0.5;
        float span = period * 0.5;
        float radius = (span * span * 0.25 + swing * swing) / (2.0 * swing);
        float index = floor(inLocalPx.x / span);
        float apart = 1.0e9;
        for (int step = -1; step <= 1; ++step) {
            float arc = index + float(step);
            // Even arcs crest toward the text, odd ones dip away from it.
            float side = arc - 2.0 * floor(arc * 0.5) < 0.5 ? -1.0 : 1.0;
            float arcLeft = arc * span;
            vec2 circle = vec2(arcLeft + span * 0.5, middle - side * (radius - swing));
            vec2 offset = vec2(inLocalPx.x, inLocalPx.y) - circle;
            float reach = length(offset);
            vec2 nearest = reach > 0.0 ? circle + offset / reach * radius : circle + vec2(0.0, side * radius);
            bool isOnArc = nearest.x >= arcLeft && nearest.x <= arcLeft + span && (side < 0.0 ? nearest.y <= middle : nearest.y >= middle);
            float distance = isOnArc ? abs(reach - radius)
                                     : min(length(vec2(inLocalPx.x - arcLeft, inLocalPx.y - middle)), length(vec2(inLocalPx.x - arcLeft - span, inLocalPx.y - middle)));
            apart = min(apart, distance);
        }
        alpha *= clamp(halfWeight + 0.5 - apart, 0.0, 1.0);
    }

    // Held to the 51 coverage levels the software renderer mixes at in the
    // bitmap tier: each an exact byte, so the blender narrowing it to eight
    // bits keeps the value, and a sin a millionth apart cannot round a byte
    // the other way. The CPU raster quantises only for Core's bitmap face,
    // so a native face keeps its coverage whole here as it does there.
    if (inBitmapTier > 0.5)
        alpha = floor(alpha * 51.0 + 0.5) / 51.0;
    // Resolve one coverage byte before the over-mix, as the CPU does. The
    // hardware blend may round each product separately on an eight-bit
    // target; reading the target keeps the sum's rounding authoritative.
    int coverage = clamp(int(alpha * 255.0 + 0.5), 0, 255);
    if (coverage == 0)
        discard;
    ivec4 background = ivec4(round(subpassLoad(uBackground) * 255.0));
    ivec3 foreground = ivec3(round(inColor.rgb * 255.0));
    ivec3 mixed = (background.rgb * (255 - coverage) + foreground * coverage + ivec3(127)) / 255;
    outColor = vec4(vec3(mixed) / 255.0, float(background.a) / 255.0);
}
