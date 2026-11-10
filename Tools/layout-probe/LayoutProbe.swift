// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// The Swift side of the layout probe: the importer's sizes of the key Core
// types, named as link-time witnesses. See LayoutProbe.h.

import UbiquittyLayoutProbe

/// Confirms, by linking, that this module's importer lays Core's key types out
/// as the C++ build does.
public func confirmImportedCoreLayout() {
    ubiquittyConfirmImportedLayout()
}
