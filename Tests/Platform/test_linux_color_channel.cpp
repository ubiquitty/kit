// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"

#include "Platform/Linux/ColorChannel.h"

#include <algorithm>
#include <cstdint>

TEST(everyColorChannelAndAlphaMatchesRoundedIntegerDivision)
{
    for (std::uint32_t alpha = 0; alpha <= 255; ++alpha) {
        for (std::uint32_t channel = 0; channel <= 255; ++channel) {
            const auto expected = alpha ? std::min<std::uint32_t>(255, (channel * 255 + alpha / 2) / alpha) : 0;
            CHECK_EQ(Ubiquitty::Linux::unpremultiplyColorChannel(channel, alpha), expected);
        }
    }
}

UBIQUITTY_TEST_MAIN()
