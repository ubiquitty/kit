// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// ubiquitty-kit-linux-check: the link check of the kit's Linux libraries.
//
// An archive that builds is not a library that links. The executable loads
// UbiquittyKitSoftware, UbiquittyKitVulkan, UbiquittyKitGTK and the GTK PAL
// backend whole, beside Core, so every object is pulled in rather than the
// reachable subset and the linker names any symbol a library expects its
// consumer to supply. A PAL function is defined once per executable, so the
// check also proves the GTK backend and Core's bundled POSIX backend divide
// the PAL between them without overlap.
//
// The body drives a terminal rather than merely returning, so a Core archive
// whose parser, screen and row store were all absent would not link either.

#include "Core/Terminal.h"
#include "Core/TerminalOperations.h"

int main()
{
    Ubiquitty::Terminal terminal;
    Ubiquitty::resize(terminal, 24, 80);
    Ubiquitty::processBytes(&terminal, "hello\r\n");
    return terminal.columns == 80 ? 0 : 1;
}
