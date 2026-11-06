// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalSurface+WindowShell.swift — what a surface asks of the window shell
// around it.
//
// A surface sends window-shaped commands, reads its window's title-bar state
// and consults a command palette, and none of those is the surface's to own.
// The Kit declares each one here and names no shell declaration: a window
// controller adopts the commands, a window records its title bar, and the
// shell installs the palette once at launch, ahead of any window. A host that
// does none of it gets a surface that summons no palette and treats every
// window as titled unless configured otherwise.

import AppKit

/// The window commands a terminal surface sends to whatever controls its window.
///
/// The surface sends each command down the responder chain by its selector,
/// as the menu item for it does, so the first responder that answers the
/// selector takes it; adopting the protocol is what keeps those selectors
/// compile-checked against the controller that answers them. The palette
/// toggle is the exception: it is called on the window's controller directly,
/// because while the palette holds first responder the chain ends in the
/// palette's own field.
@MainActor
@objc(UBTerminalWindowCommands)
public protocol TerminalWindowCommands: AnyObject {
    /// Pastes the general pasteboard into the focused terminal.
    ///
    /// - Parameter sender: The control that sent the command.
    @objc(paste:)
    func pasteFromPasteboard(_ sender: Any?)

    /// Makes the window's font one step larger.
    ///
    /// - Parameter sender: The control that sent the command.
    @objc
    func growFontSize(_ sender: Any?)

    /// Makes the window's font one step smaller.
    ///
    /// - Parameter sender: The control that sent the command.
    @objc
    func shrinkFontSize(_ sender: Any?)

    /// Returns the window's font to the configured size.
    ///
    /// - Parameter sender: The control that sent the command.
    @objc
    func resetFontSize(_ sender: Any?)

    /// Clears the history the focused terminal's screen is not showing.
    ///
    /// - Parameter sender: The control that sent the command.
    @objc
    func clearScrollback(_ sender: Any?)

    /// Soft-resets the focused terminal.
    ///
    /// - Parameter sender: The control that sent the command.
    @objc
    func resetTerminal(_ sender: Any?)

    /// Summons the command palette over the window, or dismisses it.
    ///
    /// - Parameter sender: The control that sent the command.
    @objc
    func toggleBeam(_ sender: Any?)
}

/// A window that holds terminal surfaces and records whether it carries a
/// title bar.
///
/// A surface reads the record off the window it is in whenever it decides
/// whether a drag moves the window, which is on every drain that redraws, so
/// the answer is a stored property one class cast away. A surface in any
/// other window is answered from the configuration, which is what a window
/// opening now would take.
@objc(UBTerminalWindow)
open class TerminalWindow: NSWindow {
    /// Whether this window hides its title bar, so that its body stands in
    /// for one when the reader drags it.
    ///
    /// A record rather than a switch: whatever hides or restores the title bar
    /// sets it in the same step.
    public final var isTitleBarHidden = false
}

/// A shell's command palette, as the Kit reaches it.
///
/// Closures rather than a protocol: the shell that fills these is in another
/// module, and the Kit needs only to call them.
public struct BeamPresenter {
    /// Summons the palette over a window, or dismisses the one already up.
    ///
    /// - Parameters:
    ///   - window: The window the overlay covers.
    ///   - foreground: The live theme's foreground.
    ///   - background: The live theme's background.
    ///   - accent: The live theme's accent.
    ///   - cursor: The live theme's cursor colour.
    public var toggle: (_ window: NSWindow, _ foreground: NSColor, _ background: NSColor, _ accent: NSColor, _ cursor: NSColor) -> Void

    /// Whether the palette is up over a window.
    ///
    /// The key-equivalent pass asks this: while the palette holds the
    /// responder, the surface still claims the chord that dismisses it.
    public var isActive: (_ window: NSWindow) -> Bool

    /// Delivers a pane's search publication to the shell's open palette.
    public var searchDidChange: ((_ surface: TerminalSurface) -> Void)?

    /// Builds a presenter.
    ///
    /// - Parameters:
    ///   - toggle: What summons and dismisses the palette.
    ///   - isActive: What says whether it is up over a window.
    ///   - searchDidChange: What refreshes results from a pane's search publication.
    public init(
        toggle: @escaping (NSWindow, NSColor, NSColor, NSColor, NSColor) -> Void,
        isActive: @escaping (NSWindow) -> Bool,
        searchDidChange: ((TerminalSurface) -> Void)? = nil
    ) {
        self.toggle = toggle
        self.isActive = isActive
        self.searchDidChange = searchDidChange
    }
}

extension TerminalSurface {
    /// The shell's command palette, installed once at launch, ahead of any
    /// window.
    ///
    /// A host with none leaves it nil and summons nothing.
    public static var beamPresenter: BeamPresenter?
}
