// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Terminal.swift — the terminal as a SwiftUI view.
//
// `Terminal` is ``TerminalView`` in a representable, as SwiftUI's `Map` is
// MapKit's map view: the platform view keeps the name with "View" in it and
// the SwiftUI view takes the plain noun. What it shows is an initializer; the
// font, the theme and the callbacks are modifiers that ride the environment,
// so one modifier serves every terminal beneath it, as `font` and `mapStyle`
// do.
//
// Two kinds of session. The convenience initializers start one the terminal
// owns, which lives as long as SwiftUI keeps the view's identity, as a view's
// `@State` does. `Terminal(_:)` shows a ``TerminalView`` the host owns, whose
// session outlives every identity, as `WebView(_:)` shows a `WebPage` and
// `VideoPlayer(player:)` an `AVPlayer`. A stream a host feeds has one reader
// and dies with it, so a host that feeds bytes owns the view and feeds it.
//
// The representable holds no terminal state. Each identity's platform view is
// a container the terminal view fills, so a host's view moves from one
// container to the next whichever SwiftUI makes or tears down first. The
// coordinator remembers only what it last applied from the environment and
// the title it last told, and every callback runs after the update that
// raised it, so an action may write state.

import Foundation
import SwiftUI

/// A terminal in SwiftUI: a ``TerminalView`` running the login shell, one
/// command line or one program, or a view the host owns.
///
/// ```swift
/// Terminal()
///     .terminalFont("Menlo", size: 13)
///     .onTerminalTitleChange { title = $0 }
///     .onTerminalExit { dismiss() }
/// ```
///
/// A terminal from `Terminal()`, `Terminal(command:)` or
/// `Terminal(executableURL:arguments:environment:currentDirectoryURL:)` owns
/// its session: what it runs is started once, when SwiftUI makes its view,
/// and ends when SwiftUI drops the view's identity, so `id(_:)` with a new
/// value runs it anew. These start a local program and so are macOS only.
/// `Terminal(_:)` shows a ``TerminalView`` the host keeps, whose session
/// outlives any identity; it is how an iOS app shows a session that arrives
/// over its own connection. The font and theme follow the modifiers as they
/// change. Without them the terminal draws in Core's font and theme, as
/// ``TerminalView`` does.
public struct Terminal: View {
    /// What a terminal shows.
    enum Program {
        /// The login shell, in a working directory or the home one.
        case shell(initialDirectory: String?)
        /// One command line, run by `/bin/sh -c`.
        case command(String)
        /// One program, with no shell between.
        case executable(URL, arguments: [String], environment: [String: String], currentDirectoryURL: URL?)
        /// A view the host owns, with whatever session it holds.
        case hosted(TerminalView)
    }

    let program: Program

    /// Creates a terminal running the user's login shell.
    ///
    /// - Parameter initialDirectory: The working directory to start in, or nil
    ///   for the user's home.
    @available(iOS, unavailable)
    public init(initialDirectory: String? = nil) {
        program = .shell(initialDirectory: initialDirectory)
    }

    /// Creates a terminal running one command line.
    ///
    /// `/bin/sh -c` runs the line in the user's home directory, with the app's
    /// environment and `PATH`, as ``TerminalView/launchCommand(_:)`` does. The
    /// terminal keeps what the command wrote after it exits.
    ///
    /// - Parameter command: The command line.
    @available(iOS, unavailable)
    public init(command: String) {
        program = .command(command)
    }

    /// Creates a terminal running one program, with no shell between.
    ///
    /// The parameters are `Process`'s, as
    /// ``TerminalView/launch(executableURL:arguments:environment:currentDirectoryURL:)``
    /// takes them.
    ///
    /// - Parameters:
    ///   - executableURL: The program, as a file URL.
    ///   - arguments: Its arguments, each passed as given.
    ///   - environment: Variables the program reads in place of the ones it
    ///     inherits from the app.
    ///   - currentDirectoryURL: The working directory, or nil for the user's
    ///     home directory.
    @available(iOS, unavailable)
    public init(
        executableURL: URL,
        arguments: [String] = [],
        environment: [String: String] = [:],
        currentDirectoryURL: URL? = nil
    ) {
        program = .executable(executableURL, arguments: arguments, environment: environment, currentDirectoryURL: currentDirectoryURL)
    }

    /// Creates a terminal showing a ``TerminalView`` the host owns.
    ///
    /// The view and its session are the host's: they outlive every identity
    /// this terminal takes, and the host launches, attaches or feeds the view
    /// itself. A view is shown in one place at a time. The font and theme
    /// modifiers apply to it, and the action modifiers reach it while the
    /// host has given it no observer of its own; a host that observes the view
    /// hears everything there.
    ///
    /// - Parameter view: The view to show.
    public init(_ view: TerminalView) {
        program = .hosted(view)
    }

    /// The terminal's view.
    public var body: some View {
        TerminalRepresentable(program: program)
    }
}

extension View {
    /// Draws the terminals in this view in a family and size.
    ///
    /// A nil family or size is Core's. A family that cannot be found is drawn
    /// in a substitute.
    ///
    /// - Parameters:
    ///   - family: The family, or nil for Core's.
    ///   - size: The em size in points, or nil for Core's.
    /// - Returns: A view whose terminals draw in the font.
    public func terminalFont(_ family: String? = nil, size: CGFloat? = nil) -> some View {
        environment(\.terminalFont, TerminalFontRequest(family: family, size: size.map { Double($0) }))
    }

    /// Draws the terminals in this view in a theme.
    ///
    /// - Parameter name: The theme's name, as ``TerminalSurface/themeNames``
    ///   lists it, or nil for Core's theme.
    /// - Returns: A view whose terminals draw in the theme.
    public func terminalTheme(_ name: String?) -> some View {
        environment(\.terminalTheme, TerminalThemeRequest(name: name))
    }

    /// Performs an action with the title of a terminal in this view: the one
    /// it shows when the action is given, and each one after.
    ///
    /// - Parameter action: Called on the main actor, after the update that
    ///   raised it, with the title; empty once the program that set it exits.
    ///   Nil performs nothing.
    /// - Returns: A view that reports its terminals' titles.
    public func onTerminalTitleChange(_ action: ((String) -> Void)?) -> some View {
        environment(\.terminalTitleAction, action)
    }

    /// Performs an action when the program in a terminal in this view exits.
    ///
    /// - Parameter action: Called on the main actor once the program exits.
    ///   The terminal keeps its screen. Nil performs nothing.
    /// - Returns: A view that reports its terminals' exits.
    public func onTerminalExit(_ action: (() -> Void)?) -> some View {
        environment(\.terminalExitAction, action)
    }

    /// Performs an action with what the person types into a terminal in this
    /// view, as the bytes the terminal encodes it to.
    ///
    /// For a host that carries a terminal's session itself, the bytes are
    /// what it sends on: what ``TerminalSurfaceObserver/terminalSurface(_:didTransmit:count:)``
    /// hands an observer.
    ///
    /// - Parameter action: Called on the main actor with each run of bytes, in
    ///   order. Nil performs nothing.
    /// - Returns: A view that reports its terminals' typing.
    public func onTerminalInput(_ action: ((Data) -> Void)?) -> some View {
        environment(\.terminalInputAction, action)
    }

    /// Performs an action when a terminal in this view could not start what it
    /// was made to run.
    ///
    /// - Parameter action: Called on the main actor, after the update that made
    ///   the terminal, when the shell, command or program did not launch: a
    ///   pseudo-terminal or process that could not be opened, a command line
    ///   holding a NUL, or a session Core refused. Nil performs nothing.
    /// - Returns: A view that reports its terminals' failed launches.
    @available(iOS, unavailable)
    public func onTerminalLaunchFailure(_ action: (() -> Void)?) -> some View {
        environment(\.terminalLaunchFailureAction, action)
    }
}

/// A font a SwiftUI modifier asked for; nil members are Core's.
struct TerminalFontRequest: Equatable {
    var family: String?
    var size: Double?
}

/// A theme a SwiftUI modifier asked for; a nil name is Core's.
struct TerminalThemeRequest: Equatable {
    var name: String?
}

private struct TerminalFontKey: EnvironmentKey {
    static var defaultValue: TerminalFontRequest? { nil }
}

private struct TerminalThemeKey: EnvironmentKey {
    static var defaultValue: TerminalThemeRequest? { nil }
}

private struct TerminalTitleActionKey: EnvironmentKey {
    static var defaultValue: ((String) -> Void)? { nil }
}

private struct TerminalExitActionKey: EnvironmentKey {
    static var defaultValue: (() -> Void)? { nil }
}

private struct TerminalInputActionKey: EnvironmentKey {
    static var defaultValue: ((Data) -> Void)? { nil }
}

private struct TerminalLaunchFailureActionKey: EnvironmentKey {
    static var defaultValue: (() -> Void)? { nil }
}

extension EnvironmentValues {
    /// The font ``View/terminalFont(_:size:)`` names; nil without the modifier.
    var terminalFont: TerminalFontRequest? {
        get { self[TerminalFontKey.self] }
        set { self[TerminalFontKey.self] = newValue }
    }

    /// The theme ``View/terminalTheme(_:)`` names; nil without the modifier.
    var terminalTheme: TerminalThemeRequest? {
        get { self[TerminalThemeKey.self] }
        set { self[TerminalThemeKey.self] = newValue }
    }

    /// The action ``View/onTerminalTitleChange(_:)`` gives.
    var terminalTitleAction: ((String) -> Void)? {
        get { self[TerminalTitleActionKey.self] }
        set { self[TerminalTitleActionKey.self] = newValue }
    }

    /// The action ``View/onTerminalExit(_:)`` gives.
    var terminalExitAction: (() -> Void)? {
        get { self[TerminalExitActionKey.self] }
        set { self[TerminalExitActionKey.self] = newValue }
    }

    /// The action ``View/onTerminalInput(_:)`` gives.
    var terminalInputAction: ((Data) -> Void)? {
        get { self[TerminalInputActionKey.self] }
        set { self[TerminalInputActionKey.self] = newValue }
    }

    /// The action ``View/onTerminalLaunchFailure(_:)`` gives.
    var terminalLaunchFailureAction: (() -> Void)? {
        get { self[TerminalLaunchFailureActionKey.self] }
        set { self[TerminalLaunchFailureActionKey.self] = newValue }
    }
}

/// The view SwiftUI places for one identity of a terminal: a container the
/// terminal view fills.
final class TerminalHostView: PlatformView {
    /// Puts the terminal view over the container's bounds, taking it from
    /// wherever it stood.
    ///
    /// - Parameter terminal: The view to show.
    func show(_ terminal: TerminalView) {
        terminal.frame = bounds
        #if canImport(AppKit)
        terminal.autoresizingMask = [.width, .height]
        #else
        terminal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        #endif
        addSubview(terminal)
    }
}

/// Carries a terminal's title, exit, typing and failed launch to the SwiftUI
/// actions, each after the update that raised it.
@MainActor
final class TerminalCoordinator: TerminalSurfaceObserver {
    /// The view this identity shows.
    var terminalView: TerminalView?
    /// Whether the host owns the view, and so may observe it itself.
    var isHostOwned = false
    /// The title action the environment gives now.
    var titleAction: ((String) -> Void)?
    /// The exit action the environment gives now.
    var exitAction: (() -> Void)?
    /// The input action the environment gives now.
    var inputAction: ((Data) -> Void)?
    /// The launch failure action the environment gives now.
    var launchFailureAction: (() -> Void)?
    /// The font this coordinator last applied from the environment; nil until
    /// a modifier named one.
    var appliedFont: TerminalFontRequest?
    /// The theme this coordinator last applied from the environment; nil
    /// until a modifier named one.
    var appliedTheme: TerminalThemeRequest?
    /// The title last handed to the title action, so a title told again on a
    /// new observer assignment is not handed over twice.
    private var lastToldTitle: String?

    /// Hands a title to the title action, after the current update.
    ///
    /// - Parameter title: The title.
    func tell(_ title: String) {
        guard let action = titleAction, title != lastToldTitle else { return }
        lastToldTitle = title
        Task { @MainActor in action(title) }
    }

    /// Calls the launch failure action, after the current update.
    func reportLaunchFailure() {
        guard let action = launchFailureAction else { return }
        Task { @MainActor in action() }
    }

    /// Declines process facts: nothing a `Terminal` offers names the program,
    /// so its session walks no process chain for them.
    nonisolated func terminalSurfaceNeedsProcessState(_: TerminalSurface) -> Bool { false }

    /// Asks for the title and directory while a title action would hear them.
    nonisolated func terminalSurfaceNeedsTitleAndDirectory(_: TerminalSurface) -> Bool {
        MainActor.assumeIsolated { titleAction != nil }
    }

    /// Hands the new title to the title action.
    nonisolated func terminalSurface(_: TerminalSurface, didChangeTitle title: String) {
        MainActor.assumeIsolated { tell(title) }
    }

    /// Calls the exit action.
    nonisolated func terminalSurfaceDidExit(_: TerminalSurface) {
        MainActor.assumeIsolated {
            guard let action = exitAction else { return }
            Task { @MainActor in action() }
        }
    }

    /// Hands what the person typed to the input action.
    nonisolated func terminalSurface(_: TerminalSurface, didTransmit bytes: [CChar], count: Int) {
        let data = Data(bytes.prefix(max(0, min(count, bytes.count))).map { UInt8(bitPattern: $0) })
        MainActor.assumeIsolated {
            guard let action = inputAction else { return }
            Task { @MainActor in action(data) }
        }
    }
}

/// ``TerminalView`` in SwiftUI.
@MainActor
struct TerminalRepresentable {
    let program: Terminal.Program

    func makeCoordinator() -> TerminalCoordinator {
        TerminalCoordinator()
    }

    /// Makes this identity's container, shows the terminal in it, dresses the
    /// terminal from the environment and starts what it runs.
    ///
    /// The coordinator observes the terminal before its program starts, so an
    /// exit that comes at once is heard.
    ///
    /// - Parameters:
    ///   - coordinator: The coordinator SwiftUI keeps for this identity.
    ///   - environment: The environment the view is made in.
    /// - Returns: The container.
    func makeHostView(coordinator: TerminalCoordinator, environment: EnvironmentValues) -> TerminalHostView {
        let host = TerminalHostView()
        let terminal: TerminalView
        if case .hosted(let hosted) = program {
            terminal = hosted
            coordinator.isHostOwned = true
        } else {
            terminal = TerminalView()
        }
        coordinator.terminalView = terminal
        host.show(terminal)
        update(host, coordinator: coordinator, environment: environment)
        let hasLaunched: Bool
        switch program {
        case .shell(let initialDirectory):
            hasLaunched = terminal.launchShell(initialDirectory: initialDirectory)
        case .command(let commandLine):
            hasLaunched = terminal.launchCommand(commandLine)
        case .executable(let executableURL, let arguments, let variables, let currentDirectoryURL):
            hasLaunched = terminal.launch(
                executableURL: executableURL,
                arguments: arguments,
                environment: variables,
                currentDirectoryURL: currentDirectoryURL
            )
        case .hosted:
            hasLaunched = true
        }
        if !hasLaunched {
            coordinator.reportLaunchFailure()
        }
        return host
    }

    /// Carries the environment's font, theme and actions to the terminal.
    ///
    /// A font or theme is applied only when the environment's differs from
    /// what this coordinator last applied, so an unrelated update neither
    /// refits the grid nor resets the colours a program set, and a host's own
    /// choice on its view stands until a modifier names another. The
    /// coordinator observes the terminal when it owns it, or when the host
    /// left it unobserved, and observes it again when a title action comes or
    /// goes, which is when the surface asks whether its title is wanted. A
    /// title action that arrives is handed the title standing.
    ///
    /// - Parameters:
    ///   - host: The container.
    ///   - coordinator: The coordinator SwiftUI keeps for this identity.
    ///   - environment: The environment as it stands.
    func update(_ host: TerminalHostView, coordinator: TerminalCoordinator, environment: EnvironmentValues) {
        guard let terminal = coordinator.terminalView else { return }
        let hadTitleAction = coordinator.titleAction != nil
        coordinator.titleAction = environment.terminalTitleAction
        coordinator.exitAction = environment.terminalExitAction
        coordinator.inputAction = environment.terminalInputAction
        coordinator.launchFailureAction = environment.terminalLaunchFailureAction
        let hasTitleAction = coordinator.titleAction != nil
        let mayObserve = !coordinator.isHostOwned || terminal.observer == nil || terminal.observer is TerminalCoordinator
        if mayObserve, terminal.observer !== coordinator || hadTitleAction != hasTitleAction {
            terminal.observer = coordinator
        }
        if mayObserve, !hadTitleAction, hasTitleAction, !terminal.title.isEmpty {
            coordinator.tell(terminal.title)
        }
        let font = environment.terminalFont
        if font != coordinator.appliedFont {
            coordinator.appliedFont = font
            terminal.setFont(family: font?.family, size: font?.size)
        }
        let theme = environment.terminalTheme
        if theme != coordinator.appliedTheme {
            coordinator.appliedTheme = theme
            terminal.themeName = theme?.name
        }
    }

    /// Lets go of this identity's terminal: the observer it set and the
    /// container, unless the terminal has already moved to the next identity's.
    ///
    /// - Parameters:
    ///   - host: The container SwiftUI is tearing down.
    ///   - coordinator: Its coordinator.
    static func dismantle(_ host: TerminalHostView, coordinator: TerminalCoordinator) {
        guard let terminal = coordinator.terminalView else { return }
        if terminal.observer === coordinator {
            terminal.observer = nil
        }
        if terminal.superview === host {
            terminal.removeFromSuperview()
        }
        coordinator.terminalView = nil
    }
}

#if canImport(AppKit)
extension TerminalRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> TerminalHostView {
        makeHostView(coordinator: context.coordinator, environment: context.environment)
    }

    func updateNSView(_ host: TerminalHostView, context: Context) {
        update(host, coordinator: context.coordinator, environment: context.environment)
    }

    static func dismantleNSView(_ host: TerminalHostView, coordinator: TerminalCoordinator) {
        dismantle(host, coordinator: coordinator)
    }
}
#else
extension TerminalRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> TerminalHostView {
        makeHostView(coordinator: context.coordinator, environment: context.environment)
    }

    func updateUIView(_ host: TerminalHostView, context: Context) {
        update(host, coordinator: context.coordinator, environment: context.environment)
    }

    static func dismantleUIView(_ host: TerminalHostView, coordinator: TerminalCoordinator) {
        dismantle(host, coordinator: coordinator)
    }
}
#endif
