#version 450

// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Per-instance attributes are the portable Rendering::DecorationInstance
// (Source/Core/Rendering/CellInstance.h) at its field byte offsets: the piece
// drawn, its colour, params = kind, pattern period, thickness and the cut
// ends, and the band = the whole rule the piece belongs to. Core cuts a rule
// around glyph ink and sends the pieces left standing; each carries the same
// band, so a dotted or dashed piece keeps the uncut rule's phase. A cut end
// (1 the left, 2 the right) lies wherever the cut does, inside a pixel as
// often as not, and that pixel is drawn in the part the piece covers.
layout(location = 0) in vec2 inMin; // topLeftInPixels          @0
layout(location = 1) in vec2 inMax; // bottomRightInPixels      @8
layout(location = 2) in vec4 inColor; //                        @16
layout(location = 3) in vec4 inParams; //                       @32
layout(location = 4) in vec4 inBand; // band top-left, bottom-right @48

layout(push_constant) uniform Push {
    vec2 viewportSize;
    vec2 cellSize;
    float bitmapTier; // 1 = the face is Core's embedded bitmap: coverage is held to the software renderer's 51 levels
}
pc;

layout(location = 0) flat out vec4 outRect; // the band's top-left and size, in pixels
layout(location = 1) out vec4 outColor;
layout(location = 2) flat out vec4 outParams;
layout(location = 3) flat out float outBitmapTier;
layout(location = 4) flat out vec2 outCutAcross; // the piece's cut ends across; far outside where none

const vec2 kCorners[6] = vec2[](
    vec2(0, 0), vec2(1, 0), vec2(0, 1),
    vec2(0, 1), vec2(1, 0), vec2(1, 1));

void main()
{
    vec2 corner = kCorners[gl_VertexIndex];
    // A cut end's pixel is drawn in part, so the quad reaches the whole pixel
    // the end lies in, and no further than the band's own pixels.
    uint cutEnds = uint(inParams.w + 0.5);
    bool isLeftCut = (cutEnds & 1u) != 0u;
    bool isRightCut = (cutEnds & 2u) != 0u;
    float quadLeft = isLeftCut ? max(floor(inMin.x), ceil(inBand.x - 0.5)) : inMin.x;
    float quadRight = isRightCut ? min(ceil(inMax.x), ceil(inBand.z - 0.5)) : inMax.x;
    vec2 px = vec2(mix(quadLeft, quadRight, corner.x), mix(floor(inMin.y), ceil(inMax.y), corner.y));
    vec2 ndc = px / pc.viewportSize * 2.0 - 1.0;
    gl_Position = vec4(ndc, 0.0, 1.0);
    outRect = vec4(inBand.xy, inBand.zw - inBand.xy);
    outColor = inColor;
    outParams = inParams;
    outBitmapTier = pc.bitmapTier;
    outCutAcross = vec2(isLeftCut ? inMin.x : -1.0e9, isRightCut ? inMax.x : 1.0e9);
}
