// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

#include <algorithm>
#include <cassert>
#include <cstdint>

namespace Ubiquitty::Linux {

/// Converts an eight-bit premultiplied channel to a straight channel.
///
/// Opaque pixels already hold straight channels, so their conversion needs no
/// division. Partially transparent edges retain rounded integer division.
///
/// - Parameters:
///   - channel: The premultiplied channel, from zero through 255.
///   - alpha: The pixel's alpha, from zero through 255.
/// - Returns: The rounded straight channel, clamped to 255, or zero for zero alpha.
[[nodiscard]] constexpr std::uint8_t unpremultiplyColorChannel(std::uint32_t channel, std::uint32_t alpha)
{
    assert(channel <= 255 && alpha <= 255);
    if (alpha == 255)
        return static_cast<std::uint8_t>(channel);
    return alpha ? static_cast<std::uint8_t>(std::min<std::uint32_t>(255, (channel * 255 + alpha / 2) / alpha)) : 0;
}

} // namespace Ubiquitty::Linux
