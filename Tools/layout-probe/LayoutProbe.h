// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

#pragma once

// The layout of the Core types a Swift module holds by value or reaches through
// header-inline code, and of every imported type a definition of the C++ build
// lays out differently (UBIQUITTY_UI_TESTS adds a member to TerminalRuntime,
// UBIQUITTY_QUIC changes SHA256Hasher's state), confirmed alike for the Swift
// importer and the C++ build.
//
// ArchiveLayout.cpp, compiled with the flags Core's C++ is, defines one witness
// for each type at the size that build gives it. `ubiquittyConfirmImportedLayout`
// names the witness at the size the compiler reading this header gives it, and
// has internal linkage, so the Swift importer's copy keeps its own reference
// rather than the linker folding it into the archive's. Where the two compilers
// lay a type out differently, the importer's reference names a witness nobody
// defined and the link fails on it, with the type and the importer's size in
// the symbol.

// Only headers Core's module map lists, so the importer reads them as that
// module rather than as a second copy in this one; they bring every type below.
#include "Core/Runtime/TerminalSession.h"
#include "Core/Selection/TerminalSelection.h"
#include "Core/Terminal.h"

#include <cstddef>

namespace UbiquittyLayoutProbe {

/// A link-time statement that `Type` is `Size` bytes, defined only at the size
/// the C++ build gives it.
template<typename Type, std::size_t Size> struct LayoutWitness {
    /// Links only where the C++ build lays `Type` out at `Size` bytes.
    static void confirm();
};

/// Names every witness at the size this compiler gives its type.
template<typename... Types> inline void confirmEach() { (LayoutWitness<Types, sizeof(Types)>::confirm(), ...); }

} // namespace UbiquittyLayoutProbe

/// Confirms the importer lays the key Core types out as the C++ build does: it
/// links only when every size agrees.
static inline void ubiquittyConfirmImportedLayout()
{
    UbiquittyLayoutProbe::confirmEach<Ubiquitty::Terminal, Ubiquitty::CellGrid, Ubiquitty::PaintSession, Ubiquitty::Cell,
        Ubiquitty::Runtime::TerminalSession, Ubiquitty::Runtime::RuntimeSnapshot, Ubiquitty::Runtime::CoherentColors,
        Ubiquitty::Runtime::FramePresentationState, Ubiquitty::Runtime::FrameClockFacts,
        Ubiquitty::Runtime::SyncFrameCaptureGeometry, Ubiquitty::Runtime::KeyPress, Ubiquitty::Selection::Session,
        Ubiquitty::Runtime::TerminalRuntime, Ubiquitty::Crypto::SHA256Hasher>();
}
