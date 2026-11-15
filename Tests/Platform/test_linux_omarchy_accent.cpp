// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#include "Harness.h"
#include "Platform/Linux/OmarchyAccent.h"

TEST(theDesktopAccentIsIndependentOfTheANSIBlueColor)
{
    CHECK(Ubiquitty::Linux::parseOmarchyAccent("accent = \"#7aa2f7\"\nblue = \"#7aa2f7\"\n") == 0x7aa2f7u);
    CHECK(Ubiquitty::Linux::parseOmarchyAccent("accent = \"#dcd7ba\"\nblue = \"#7e9cd8\"\n") == 0xdcd7bau);
}

TEST(generatedAccentAcceptsWhitespaceQuotesAndComments)
{
    CHECK(Ubiquitty::Linux::parseOmarchyAccent("# accent = '#000000'\r\n \taccent\t= '#AbC123' # current\r\n") == 0xabc123u);
}

TEST(missingMalformedAndNestedAccentsHaveNoOverride)
{
    for (const auto* text : { "", "blue = '#123456'", "accent = '#12345'", "accent = '#1234567'", "accent = '#xyzxyz'",
             "accent = '#123456' garbage", "accent = '#123456\"", "[nested]\naccent = '#123456'" })
        CHECK(!Ubiquitty::Linux::parseOmarchyAccent(text));
}

UBIQUITTY_TEST_MAIN()
