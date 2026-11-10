// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// The witnesses LayoutProbe.h names, each at the size the C++ build gives its
// type. Compiled with the flags Core's own translation units are.

#include "LayoutProbe.h"

namespace UbiquittyLayoutProbe {

#define UBIQUITTY_LAYOUT_WITNESS(Type) \
    template<> void LayoutWitness<Type, sizeof(Type)>::confirm() { }

UBIQUITTY_LAYOUT_WITNESS(Ubiquitty::Terminal)
UBIQUITTY_LAYOUT_WITNESS(Ubiquitty::CellGrid)
UBIQUITTY_LAYOUT_WITNESS(Ubiquitty::PaintSession)
UBIQUITTY_LAYOUT_WITNESS(Ubiquitty::Cell)
UBIQUITTY_LAYOUT_WITNESS(Ubiquitty::Runtime::TerminalSession)
UBIQUITTY_LAYOUT_WITNESS(Ubiquitty::Runtime::RuntimeSnapshot)
UBIQUITTY_LAYOUT_WITNESS(Ubiquitty::Runtime::CoherentColors)
UBIQUITTY_LAYOUT_WITNESS(Ubiquitty::Runtime::FramePresentationState)
UBIQUITTY_LAYOUT_WITNESS(Ubiquitty::Runtime::FrameClockFacts)
UBIQUITTY_LAYOUT_WITNESS(Ubiquitty::Runtime::SyncFrameCaptureGeometry)
UBIQUITTY_LAYOUT_WITNESS(Ubiquitty::Runtime::KeyPress)
UBIQUITTY_LAYOUT_WITNESS(Ubiquitty::Selection::Session)
UBIQUITTY_LAYOUT_WITNESS(Ubiquitty::Runtime::TerminalRuntime)
UBIQUITTY_LAYOUT_WITNESS(Ubiquitty::Crypto::SHA256Hasher)

#undef UBIQUITTY_LAYOUT_WITNESS

} // namespace UbiquittyLayoutProbe
