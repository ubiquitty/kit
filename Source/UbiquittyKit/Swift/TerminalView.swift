// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// TerminalView.swift — the terminal view an app drops in: no font, no grid
// size and no Metal setup to give it.
//
// A container holding one ``TerminalSurface``, never a second terminal. The
// surface keeps every fact of the session — its grid, its title, its colours,
// its font — and this view keeps only what a host asked of it: the theme and
// font it named, each nil for Core's own. Everything the view reads, it reads
// from the surface or from Core; everything it is told, it passes to the
// surface.
//
// A container rather than a subclass, because a view has to be creatable where
// a session may not be: `init(frame:)` and a storyboard's `init(coder:)` cannot
// fail, and Core may refuse a session under memory pressure. The view stands
// either way and says which it holds.
//
// On iOS the view also brings the keyboard. A surface leaves its typing to the
// host there, because on a phone which view holds the keyboard is the host's
// arrangement; here the arrangement is this view, so it holds one.

#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import Foundation
internal import UbiquittyCore
internal import UbiquittyRenderKit

/// A terminal view that sets itself up: it builds its own session and Metal
/// renderer in Core's font and theme, and fits its grid to its bounds.
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
/// The font, its size and the theme are Core's defaults unless a host names
/// others; in an app that configures Core, as the Ubiquitty app does, they are
/// that configuration's. The theme follows the view's light or dark appearance
/// while Core follows the system's, which it does by default. The grid has as
/// many rows and columns as the view's bounds hold, and moves with them.
///
/// The view forwards the calls most hosts make to ``surface``, the
/// ``TerminalSurface`` that holds the session; everything else, attaching to a
/// host's session among it, is on the surface. The surface takes the pointer.
/// On macOS it takes the keyboard too: a click gives it the keyboard, and so
/// does making this view the window's first responder. On iOS, which starts no
/// local program, a host feeds the bytes its own connection receives with
/// ``feed(_:)`` and hears what the person types as
/// ``TerminalSurfaceObserver/terminalSurface(_:didTransmit:count:)``; a tap
/// that asks for a keyboard raises the view's own, as does
/// ``becomeFirstResponder()``. That keyboard types text, Return and Delete
/// and nothing else: no arrows, Escape, Tab or Control chords, from the
/// software keyboard or a hardware one.
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

    /// The theme the view draws in, by name, or nil for Core's.
    ///
    /// Nil draws Core's theme: while Core follows the system appearance, the
    /// dark or light theme of its pair for the view's appearance, resolved
    /// again as the appearance changes; otherwise the theme Core names.
    /// Assigning a different value applies it at once, as
    /// ``TerminalSurface/applyTheme(named:)`` does, and an unknown name leaves
    /// the colours as they were. Assigning the value it holds does nothing, so
    /// the colours a program set stand. A theme applied through ``surface``
    /// instead stands until the appearance next changes while this is nil.
    public var themeName: String? {
        didSet {
            guard themeName != oldValue else { return }
            applyThemeChoice()
        }
    }

    /// The family the terminal draws in, or nil for Core's.
    ///
    /// Assigning a different value applies it as
    /// ``setFont(family:size:)`` does, at the size ``fontSize`` names.
    public var fontFamily: String? {
        get { requestedFont.family }
        set { setFont(family: newValue, size: requestedFont.size) }
    }

    /// The em size in points the terminal draws at, or nil for Core's.
    ///
    /// Assigning a different value applies it as ``setFont(family:size:)``
    /// does, in the family ``fontFamily`` names.
    public var fontSize: Double? {
        get { requestedFont.size }
        set { setFont(family: requestedFont.family, size: newValue) }
    }

    /// The family and size a host asked for; nil members are Core's.
    private var requestedFont: (family: String?, size: Double?) = (nil, nil)

    /// The grid a surface lays out before the view has bounds to fit.
    private static let initialRows = 24
    private static let initialColumns = 80

    #if !canImport(AppKit)
    /// The responder the view's keyboard types through.
    private var keyboardInput: TerminalKeyboardInput?
    #endif

    /// Creates a terminal view with the given frame.
    ///
    /// - Parameter frameRect: The view's frame; the grid fits its bounds.
    override public init(frame frameRect: CGRect) {
        surface = TerminalSurface(rows: TerminalView.initialRows, columns: TerminalView.initialColumns)
        super.init(frame: frameRect)
        installSurface()
    }

    /// Creates a terminal view from a storyboard, a nib or an archive.
    ///
    /// The view's own frame and attributes decode as any view's; the session,
    /// the renderer and the theme are built as ``init(frame:)`` builds them.
    /// An archive of a live view holds no session: the view's surface and
    /// keyboard leave themselves out of it.
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
        surface.isOmittedFromArchives = true
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
        // Behind the grid, where nothing sees it: a responder has to be in the
        // window to hold the keyboard, and needs no size to do it.
        let keyboardInput = TerminalKeyboardInput(frame: CGRect(x: 0, y: 0, width: 1, height: 1))
        keyboardInput.surface = surface
        addSubview(keyboardInput)
        surface.keyboardResponder = keyboardInput
        self.keyboardInput = keyboardInput
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
    ///   false for a view that already runs a program, and on iOS, which
    ///   starts no local program.
    @discardableResult
    public func launchShell(initialDirectory: String? = nil) -> Bool {
        surface?.launchShell(initialDirectory: initialDirectory) ?? false
    }

    /// Launches one command line, as ``TerminalSurface/launchCommand(_:)``:
    /// `/bin/sh -c` runs it in the user's home directory with the app's
    /// environment and `PATH`.
    ///
    /// - Parameter commandLine: The command line `/bin/sh -c` runs.
    /// - Returns: Whether the command launched and its output is being read;
    ///   false for a line holding a NUL, for a view that already runs a
    ///   program, and on iOS, which starts no local program.
    @discardableResult
    public func launchCommand(_ commandLine: String) -> Bool {
        surface?.launchCommand(commandLine) ?? false
    }

    /// Launches one program with no shell between, as
    /// ``TerminalSurface/launch(executableURL:arguments:environment:currentDirectoryURL:)``.
    ///
    /// - Parameters:
    ///   - executableURL: The program, as a file URL.
    ///   - arguments: Its arguments, each passed as given.
    ///   - environment: Variables the program reads in place of the ones it
    ///     inherits from the app.
    ///   - currentDirectoryURL: The working directory, or nil for the user's
    ///     home directory.
    /// - Returns: Whether the program launched and its output is being read.
    ///   False, with nothing started, for what
    ///   ``TerminalSurface/launch(executableURL:arguments:environment:currentDirectoryURL:)``
    ///   refuses: an executable that is missing, a directory or not
    ///   executable; a working directory that is missing, not a directory,
    ///   not enterable or longer than 1023 bytes; more than 255 arguments or
    ///   128 variables; a variable name other than ASCII letters, digits and
    ///   `_` not starting with a digit, or one the terminal sets itself; a
    ///   NUL; a view that already runs a program; and iOS.
    @discardableResult
    public func launch(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        currentDirectoryURL: URL? = nil
    ) -> Bool {
        surface?.launch(
            executableURL: executableURL,
            arguments: arguments,
            environment: environment,
            currentDirectoryURL: currentDirectoryURL
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

    /// Sets the family and the size together, refitting the grid once.
    ///
    /// The font is applied as ``TerminalSurface/applyFont(familyName:pointSize:)``
    /// applies it, with Core's family or size for the one that is nil: the
    /// grid refits and any zoom clears. A family that cannot be found is drawn
    /// in a substitute, which ``TerminalSurface/resolvedFontFamily`` names, and
    /// Core clamps the size to the range it draws. Naming the family and size
    /// the view already holds does nothing.
    ///
    /// - Parameters:
    ///   - family: The family, or nil for Core's.
    ///   - size: The em size in points, or nil for Core's.
    public func setFont(family: String?, size: Double?) {
        guard family != requestedFont.family || size != requestedFont.size else { return }
        requestedFont = (family, size)
        guard let surface, surface.renderer != nil else { return }
        let configuration = Ubiquitty.Preferences.Effective.liveRenderConfiguration()
        surface.applyFont(
            familyName: family ?? TerminalSurface.family(of: configuration),
            pointSize: size ?? configuration.fontSizePoints
        )
    }

    /// Applies ``themeName``, or Core's theme while it is nil.
    private func applyThemeChoice() {
        guard let surface else { return }
        if let themeName {
            _ = surface.applyTheme(named: themeName)
            return
        }
        _ = surface.applyTheme(at: configuredThemeIndex(followingAppearance: isFollowingAppearance))
    }

    /// Resolves Core's theme again for an appearance that may have changed,
    /// while the view is in a window, draws Core's theme, and Core follows
    /// the system appearance.
    ///
    /// Only a theme that moves is applied: applying one resets the colours
    /// programs set, which an appearance change that resolves to the same
    /// theme must not do. A view out of any window reads an appearance no
    /// window gives it, the app's or none, so it follows nothing until it
    /// joins one again.
    private func followAppearance() {
        guard let surface, window != nil, themeName == nil, isFollowingAppearance else { return }
        let index = configuredThemeIndex(followingAppearance: true)
        guard Int(surface.drive.currentThemeIndex()) != index else { return }
        _ = surface.applyTheme(at: index)
    }

    /// Whether Core follows the system's light or dark appearance.
    private var isFollowingAppearance: Bool {
        Ubiquitty.Preferences.followSystemAppearanceEffective(Ubiquitty.Preferences.values().pointee.followSystemAppearance)
    }

    /// The theme Core draws this view in.
    ///
    /// - Parameter followingAppearance: Whether Core follows the system
    ///   appearance, which pairs a dark and a light theme.
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

    /// Resolves the theme for the window the view joined: AppKit can tell a
    /// view its appearance changed before the view has a window, when this
    /// view follows none.
    override public func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        followAppearance()
    }

    /// Whether the view can be made first responder: while it has a surface,
    /// which takes the keyboard in its place.
    override public var acceptsFirstResponder: Bool { surface != nil }

    /// Hands first responder to the surface, as a text field hands it to its
    /// field editor.
    ///
    /// - Returns: Whether the surface became the first responder.
    override public func becomeFirstResponder() -> Bool {
        guard let surface, let window else { return false }
        return window.makeFirstResponder(surface)
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

    override public func didMoveToWindow() {
        super.didMoveToWindow()
        followAppearance()
    }

    /// Raises the view's keyboard, as `UISearchBar` raises its text field's.
    ///
    /// - Returns: Whether the view's keyboard became the first responder.
    @discardableResult
    override public func becomeFirstResponder() -> Bool {
        keyboardInput?.becomeFirstResponder() ?? false
    }

    /// Gives up the keyboard, from the view's keyboard or from the surface,
    /// whichever holds it.
    ///
    /// - Returns: Whether neither holds it any longer.
    @discardableResult
    override public func resignFirstResponder() -> Bool {
        if let keyboardInput, keyboardInput.isFirstResponder {
            return keyboardInput.resignFirstResponder()
        }
        if let surface, surface.isFirstResponder {
            return surface.resignFirstResponder()
        }
        return true
    }

    /// Whether the view's keyboard or its surface is the first responder.
    override public var isFirstResponder: Bool {
        (keyboardInput?.isFirstResponder ?? false) || (surface?.isFirstResponder ?? false)
    }
    #endif
}

#if !canImport(AppKit)
/// The responder a ``TerminalView``'s keyboard types into its surface through.
///
/// UIKit shows a keyboard for a first responder that takes text, and a surface
/// takes none: its typing is the host's. A view that holds a surface is that
/// host, so it holds this. It takes committed text, Return and Delete, and
/// carries no input method's marked text and no arrows, Escape, Tab or
/// Control chords, from the software keyboard or a hardware one.
final class TerminalKeyboardInput: UIView, UIKeyInput {
    /// The surface the keyboard types into.
    weak var surface: TerminalSurface?

    // A terminal keyboard does not autocapitalise, autocorrect or predict:
    // each rewrites what was typed, and the program receives the rewrite
    // rather than the keystroke.
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var autocorrectionType: UITextAutocorrectionType = .no
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var keyboardType: UIKeyboardType = .default

    override var canBecomeFirstResponder: Bool { surface != nil }

    /// Leaves the keyboard out of an archive: the view that holds it builds
    /// its own when it is decoded.
    ///
    /// - Parameter archiver: The archiver encoding the view.
    /// - Returns: Nothing.
    nonisolated override func replacementObject(for archiver: NSKeyedArchiver) -> Any? {
        nil
    }

    /// Always false: there is no text here to delete, only keys to send, and
    /// UIKit delivers Delete either way.
    var hasText: Bool { false }

    /// Types committed text into the surface as the reader's own.
    ///
    /// - Parameter text: The text; Return arrives as a newline and leaves as
    ///   the carriage return a line discipline ends a line on.
    func insertText(_ text: String) {
        surface?.commitComposedText(text.replacingOccurrences(of: "\n", with: "\r"))
    }

    /// Sends Delete, which the program decides the meaning of.
    func deleteBackward() {
        var press = Ubiquitty.Runtime.KeyPress()
        press.virtualKey = .Backspace
        surface?.sendKey(press)
    }

    /// Takes the keyboard and tells the surface a keyboard is up, so a tap
    /// becomes a click.
    ///
    /// - Returns: Whether this became the first responder.
    override func becomeFirstResponder() -> Bool {
        guard super.becomeFirstResponder() else { return false }
        surface?.isKeyboardPresented = true
        return true
    }

    /// Gives up the keyboard and tells the surface it is down, so a tap asks
    /// for it again.
    ///
    /// - Returns: Whether this resigned.
    override func resignFirstResponder() -> Bool {
        guard super.resignFirstResponder() else { return false }
        surface?.isKeyboardPresented = false
        return true
    }
}
#endif
