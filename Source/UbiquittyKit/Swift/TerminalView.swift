// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalView.swift — the terminal view an app drops in: no font, no grid
// size and no Metal setup to give it.
//
// A container holding one ``TerminalSurface``, never a second terminal. The
// surface keeps every fact of the session — its grid, its title, its colours,
// its font — and this view keeps only what a host asked of it: the theme and
// font it named, each nil for "what Core's configuration says". Everything the
// view reads, it reads from the surface or from Core; everything it is told, it
// passes to the surface.
//
// A container rather than a subclass, because a view has to be creatable where
// a session may not be: `init(frame:)` and a storyboard's `init(coder:)` cannot
// fail, and Core may refuse a session under memory pressure. The view stands
// either way and says which it holds.

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import Foundation
internal import UbiquittyCore
internal import UbiquittyRenderKit

/// A terminal view that sets itself up: it builds its own session and Metal
/// renderer in the configured font and theme, and fits its grid to its bounds.
///
/// `TerminalView()` is ready to place. Put it where the terminal goes, size it
/// as any view, and launch something in it:
///
/// ```swift
/// let terminal = TerminalView()
/// container.addSubview(terminal)
/// terminal.launchShell()
/// ```
///
/// The font, its size and the theme are Core's configuration unless a host
/// names others. The theme follows the view's light or dark appearance while
/// the configuration follows the system's, as Ubiquitty's own windows do. The
/// grid has as many rows and columns as the view's bounds hold, and moves with
/// them.
///
/// On iOS, which starts no local program, a host feeds the bytes its own
/// connection receives with ``feed(_:)`` and hears what the person types as
/// ``TerminalSurfaceObserver/terminalSurface(_:didTransmit:count:)``.
///
/// The view forwards the calls most hosts make to ``surface``, the
/// ``TerminalSurface`` that holds the session; everything else is on the
/// surface. The surface takes the keyboard: clicking the view gives it the
/// keyboard, and a host that does so in code makes ``surface`` the first
/// responder.
public final class TerminalView: PlatformView {
    /// The terminal this view shows, or nil when Core refused a session.
    ///
    /// Core refuses a session only when it cannot allocate one, and then the
    /// view draws nothing and every call it forwards does nothing.
    public let surface: TerminalSurface?

    /// Why the surface has no renderer, or nil while it has one.
    ///
    /// The reason the one attempt to build it gave. A view whose surface Core
    /// refused has neither a renderer nor a reason here.
    public private(set) var rendererRefusal: RendererRefusal?

    /// The theme the view draws in, by name, or nil for the configured one.
    ///
    /// Nil draws Core's configured theme: while the configuration follows the
    /// system appearance, the dark or light theme it pairs for the view's
    /// appearance, re-resolved as the appearance changes; otherwise the theme
    /// it names, or Core's default. Assigning applies the theme at once, as
    /// ``TerminalSurface/applyTheme(named:)`` does, and an unknown name leaves
    /// the colours as they were. A theme applied through ``surface`` instead
    /// stands until the appearance next changes while this is nil.
    public var themeName: String? {
        didSet { applyThemeChoice() }
    }

    /// The family the terminal draws in, or nil for the configured one.
    ///
    /// Assigning applies the family at the size ``fontSize`` names and refits
    /// the grid, as ``TerminalSurface/applyFont(familyName:pointSize:)`` does,
    /// clearing any zoom. A family that cannot be found is drawn in a
    /// substitute; ``TerminalSurface/resolvedFontFamily`` names it.
    public var fontFamily: String? {
        get { requestedFont.family }
        set { requestFont(family: newValue, size: requestedFont.size) }
    }

    /// The em size in points the terminal draws at, or nil for the configured
    /// one.
    ///
    /// Assigning applies the size in the family ``fontFamily`` names and refits
    /// the grid, clearing any zoom. Core clamps it to the range it draws.
    public var fontSize: Double? {
        get { requestedFont.size }
        set { requestFont(family: requestedFont.family, size: newValue) }
    }

    /// The family and size a host asked for; nil members are the configured ones.
    private var requestedFont: (family: String?, size: Double?) = (nil, nil)

    /// The grid a surface lays out before the view has bounds to fit.
    private static let initialRows = 24
    private static let initialColumns = 80

    /// Creates a terminal view with the given frame.
    ///
    /// - Parameter frameRect: The view's frame; the grid fits its bounds.
    override public init(frame frameRect: CGRect) {
        surface = TerminalSurface(rows: TerminalView.initialRows, columns: TerminalView.initialColumns)
        super.init(frame: frameRect)
        installSurface()
    }

    /// Creates a terminal view from a storyboard or nib.
    ///
    /// The view's own frame and attributes decode as any view's; the session,
    /// the renderer and the theme are built as ``init(frame:)`` builds them.
    ///
    /// - Parameter coder: The archive the view is decoded from.
    public required init?(coder: NSCoder) {
        surface = TerminalSurface(rows: TerminalView.initialRows, columns: TerminalView.initialColumns)
        super.init(coder: coder)
        installSurface()
    }

    /// Builds the surface's renderer and terminal from Core's configuration and
    /// puts the surface over the view's bounds.
    ///
    /// The renderer is built before the surface takes a frame, so the first
    /// fit measures the configured font's cells rather than none.
    private func installSurface() {
        guard let surface else { return }
        let configuration = Ubiquitty.Preferences.Effective.liveRenderConfiguration()
        let transparency = Self.systemTransparency
        switch TerminalSurface.buildRenderer(configuration: configuration, systemTransparency: transparency) {
        case .success(let renderer):
            surface.renderer = renderer
            surface.adopt(configuration: configuration, systemTransparency: transparency)
        case .failure(let refusal):
            rendererRefusal = refusal
        }
        surface.drive.applyTerminalPreferences(Ubiquitty.Preferences.values().pointee)
        applyThemeChoice()
        surface.frame = bounds
        #if canImport(AppKit)
        surface.autoresizingMask = [.width, .height]
        #else
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        _ = registerForTraitChanges([UITraitUserInterfaceStyle.self], action: #selector(appearanceDidChange))
        #endif
        addSubview(surface)
    }

    /// Receives what the session reports, as ``TerminalSurface/observer``.
    ///
    /// Held weakly, by the surface: a host owns its observer.
    public var observer: (any TerminalSurfaceObserver)? {
        get { surface?.observer }
        set { surface?.observer = newValue }
    }

    /// The terminal's title, as ``TerminalSurface/title``; empty until a
    /// program sets one.
    public var title: String { surface?.title ?? "" }

    /// The working directory the session last reported, as
    /// ``TerminalSurface/currentDirectory``; empty until one is known.
    public var currentDirectory: String { surface?.currentDirectory ?? "" }

    /// Launches the user's login shell, as
    /// ``TerminalSurface/launchShell(initialDirectory:)``.
    ///
    /// - Parameter initialDirectory: The working directory to start in, or nil
    ///   for the user's home.
    /// - Returns: Whether the shell launched and its output is being read;
    ///   false on iOS, which starts no local program.
    @discardableResult
    public func launchShell(initialDirectory: String? = nil) -> Bool {
        surface?.launchShell(initialDirectory: initialDirectory) ?? false
    }

    /// Launches one command line, as ``TerminalSurface/launchCommand(_:)``.
    ///
    /// - Parameter commandLine: The command line `/bin/sh -c` runs.
    /// - Returns: Whether the command launched and its output is being read;
    ///   false on iOS, which starts no local program.
    @discardableResult
    public func launchCommand(_ commandLine: String) -> Bool {
        surface?.launchCommand(commandLine) ?? false
    }

    /// Attaches to a session a host keeps, as
    /// ``TerminalSurface/attachRemote(shellCommand:quicHost:quicBootstrapCommand:reattachSessionID:workspaceName:endsWhenDetached:reattachPolicy:workspaceID:daemonSocketName:daemonInstanceID:)``.
    ///
    /// - Parameters:
    ///   - shellCommand: The transport command (`ssh … --attach`).
    ///   - quicHost: The host a QUIC carrier dials; empty offers no QUIC.
    ///   - quicBootstrapCommand: Prints the daemon's QUIC port, token and
    ///     certificate pin; empty likewise offers no QUIC.
    ///   - reattachSessionID: The daemon session to re-home to, or zero for a
    ///     fresh one.
    ///   - workspaceName: The workspace to attach under; empty attaches unnamed.
    ///   - endsWhenDetached: Whether a session created under the name ends when
    ///     its last human detaches cleanly.
    ///   - reattachPolicy: What the attach asks when `reattachSessionID` has
    ///     ended.
    ///   - workspaceID: The stable workspace identifier the directory returned.
    ///   - daemonSocketName: The daemon socket the directory handshake returned.
    ///   - daemonInstanceID: The daemon process identity to require, or zero.
    /// - Returns: Whether the attach started.
    @discardableResult
    public func attachRemote(
        shellCommand: String,
        quicHost: String = "",
        quicBootstrapCommand: String = "",
        reattachSessionID: UInt32 = 0,
        workspaceName: String = "",
        endsWhenDetached: Bool = false,
        reattachPolicy: RemoteReattachPolicy = .attachOrCreate,
        workspaceID: UInt32 = 0,
        daemonSocketName: String = "",
        daemonInstanceID: UInt64 = 0
    ) -> Bool {
        surface?.attachRemote(
            shellCommand: shellCommand,
            quicHost: quicHost,
            quicBootstrapCommand: quicBootstrapCommand,
            reattachSessionID: reattachSessionID,
            workspaceName: workspaceName,
            endsWhenDetached: endsWhenDetached,
            reattachPolicy: reattachPolicy,
            workspaceID: workspaceID,
            daemonSocketName: daemonSocketName,
            daemonInstanceID: daemonInstanceID
        ) ?? false
    }

    /// Writes bytes to the screen as if the session produced them, as
    /// ``TerminalSurface/feed(_:)``.
    ///
    /// - Parameter data: The bytes, exactly as a program would write them.
    public func feed(_ data: Data) {
        surface?.feed(data)
    }

    /// Sends text to the running program as typed input, as
    /// ``TerminalSurface/send(_:)``.
    ///
    /// - Parameter text: The text, encoded as the terminal's input bytes.
    public func send(_ text: String) {
        surface?.send(text)
    }

    /// Takes a font request and applies it once, unless it names what stands.
    ///
    /// The one path for a family and a size given together, so a host that
    /// names both refits the grid once.
    ///
    /// - Parameters:
    ///   - family: The family, or nil for the configured one.
    ///   - size: The em size in points, or nil for the configured one.
    func requestFont(family: String?, size: Double?) {
        requestedFont = (family, size)
        guard let surface, surface.renderer != nil else { return }
        let configuration = Ubiquitty.Preferences.Effective.liveRenderConfiguration()
        surface.applyFont(
            familyName: family ?? TerminalSurface.family(of: configuration),
            pointSize: size ?? configuration.fontSizePoints
        )
    }

    /// Applies ``themeName``, or the configured theme while it is nil.
    private func applyThemeChoice() {
        guard let surface else { return }
        if let themeName {
            _ = surface.applyTheme(named: themeName)
            return
        }
        _ = surface.applyTheme(at: configuredThemeIndex(followingAppearance: isFollowingAppearance))
    }

    /// Re-resolves the configured theme for an appearance that changed, while
    /// the view draws the configured theme and the configuration follows the
    /// system appearance.
    ///
    /// Only a theme that moves is applied: applying one resets the colours
    /// programs set, which an appearance change that resolves to the same
    /// theme must not do.
    private func followAppearance() {
        guard let surface, themeName == nil, isFollowingAppearance else { return }
        let index = configuredThemeIndex(followingAppearance: true)
        guard Int(surface.drive.currentThemeIndex()) != index else { return }
        _ = surface.applyTheme(at: index)
    }

    /// Whether Core's configuration follows the system's light or dark appearance.
    private var isFollowingAppearance: Bool {
        Ubiquitty.Preferences.followSystemAppearanceEffective(Ubiquitty.Preferences.values().pointee.followSystemAppearance)
    }

    /// The theme Core's configuration draws this view in.
    ///
    /// - Parameter followingAppearance: Whether the configuration follows the
    ///   system appearance, which pairs a dark and a light theme.
    /// - Returns: The theme's index in ``TerminalSurface/themeNames``; negative
    ///   when Core holds no theme.
    private func configuredThemeIndex(followingAppearance: Bool) -> Int {
        guard followingAppearance else {
            return Int(Ubiquitty.Runtime.launchThemeIndex(Ubiquitty.Preferences.values().pointee))
        }
        return Int(Ubiquitty.Themes.resolvedAutomaticThemeIndex(isDarkAppearance ? .Dark : .Light))
    }

    #if canImport(AppKit)
    /// Whether the view draws in a dark appearance.
    private var isDarkAppearance: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// What the Reduce Transparency switch says, as every surface reads it.
    private static var systemTransparency: Ubiquitty.Preferences.Effective.SystemTransparency {
        TerminalSurface.systemTransparency
    }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        followAppearance()
    }
    #else
    /// Whether the view draws in a dark appearance.
    private var isDarkAppearance: Bool {
        traitCollection.userInterfaceStyle == .dark
    }

    /// What the Reduce Transparency switch says.
    private static var systemTransparency: Ubiquitty.Preferences.Effective.SystemTransparency {
        UIAccessibility.isReduceTransparencyEnabled ? .Reduced : .Allowed
    }

    /// Follows the light or dark appearance the trait collection moved to.
    @objc private func appearanceDidChange() {
        followAppearance()
    }

    /// Gives the surface the keyboard, as `UISearchBar` gives its text field.
    ///
    /// - Returns: Whether the surface became the first responder.
    @discardableResult
    override public func becomeFirstResponder() -> Bool {
        surface?.becomeFirstResponder() ?? false
    }
    #endif
}
