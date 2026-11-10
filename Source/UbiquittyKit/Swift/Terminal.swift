// Copyright (C) 2026 Stanislav Yaglo
// SPDX-License-Identifier: Apache-2.0

// Terminal.swift — the terminal as a SwiftUI view.
//
// `Terminal` is ``TerminalView`` in a representable, as SwiftUI's `Map` is
// MapKit's map view: the platform view keeps the name with "View" in it and
// the SwiftUI view takes the plain noun. What it runs is an initializer; the
// font, the theme and the two callbacks are modifiers that ride the
// environment, so one modifier serves every terminal beneath it, as `font`
// and `mapStyle` do.
//
// The representable holds no terminal state. The font and theme it is given
// are compared with what the view was last asked for, which the view keeps,
// and the callbacks are the coordinator's for as long as SwiftUI keeps it.

import Foundation
import SwiftUI

/// A terminal in SwiftUI: a ``TerminalView`` running the login shell, one
/// command line, or the bytes a host feeds it.
///
/// ```swift
/// Terminal()
///     .terminalFont("Menlo", size: 13)
///     .onTerminalTitleChange { title = $0 }
///     .onTerminalExit { dismiss() }
/// ```
///
/// What the terminal runs is read once, when SwiftUI makes the view; a
/// terminal given a new identity with `id(_:)` runs anew. On iOS, which starts
/// no local program, a terminal shows a stream a host feeds it. The font and the
/// theme follow the modifiers as they change. Without them the terminal draws
/// in Core's configured font and theme, as ``TerminalView`` does.
public struct Terminal: View {
    /// What a terminal runs.
    enum Program {
        /// The login shell, in a working directory or the home one.
        case shell(initialDirectory: String?)
        /// One command line, run by `/bin/sh -c`.
        case command(String)
        /// No program: the bytes a host writes to the stream are the screen's.
        case feed(AsyncStream<Data>)
    }

    let program: Program

    /// Creates a terminal running the user's login shell.
    ///
    /// - Parameter initialDirectory: The working directory to start in, or nil
    ///   for the user's home.
    public init(initialDirectory: String? = nil) {
        program = .shell(initialDirectory: initialDirectory)
    }

    /// Creates a terminal running one command line.
    ///
    /// The terminal keeps what the command wrote after it exits.
    ///
    /// - Parameter command: The command line `/bin/sh -c` runs.
    public init(command: String) {
        program = .command(command)
    }

    /// Creates a terminal that shows the bytes a host writes, with no program
    /// of its own.
    ///
    /// Each element is written to the screen as a program's output would be,
    /// in order, until the stream finishes or the terminal goes away. A stream
    /// has one reader, so it serves one terminal.
    ///
    /// - Parameter output: The bytes to show.
    public init(feeding output: AsyncStream<Data>) {
        program = .feed(output)
    }

    /// The terminal's view.
    public var body: some View {
        TerminalRepresentable(program: program)
    }
}

extension View {
    /// Draws the terminals in this view in a family and size.
    ///
    /// A nil family or size is Core's configured one. A family that cannot be
    /// found is drawn in a substitute.
    ///
    /// - Parameters:
    ///   - family: The family, or nil for the configured one.
    ///   - size: The em size in points, or nil for the configured one.
    /// - Returns: A view whose terminals draw in the font.
    public func terminalFont(_ family: String? = nil, size: CGFloat? = nil) -> some View {
        environment(\.terminalFont, TerminalFontRequest(family: family, size: size.map { Double($0) }))
    }

    /// Draws the terminals in this view in a theme.
    ///
    /// - Parameter name: The theme's name, as ``TerminalSurface/themeNames``
    ///   lists it, or nil for Core's configured theme.
    /// - Returns: A view whose terminals draw in the theme.
    public func terminalTheme(_ name: String?) -> some View {
        environment(\.terminalTheme, name)
    }

    /// Performs an action when the title of a terminal in this view changes.
    ///
    /// - Parameter action: Called on the main actor with the new title, which
    ///   is empty once the program that set it exits.
    /// - Returns: A view that reports its terminals' titles.
    public func onTerminalTitleChange(_ action: @escaping (String) -> Void) -> some View {
        environment(\.terminalTitleAction, action)
    }

    /// Performs an action when the program in a terminal in this view exits.
    ///
    /// - Parameter action: Called on the main actor once the shell or command
    ///   exits. The terminal keeps its screen.
    /// - Returns: A view that reports its terminals' exits.
    public func onTerminalExit(_ action: @escaping () -> Void) -> some View {
        environment(\.terminalExitAction, action)
    }
}

/// A font a SwiftUI modifier asked for; nil members are the configured ones.
struct TerminalFontRequest: Equatable {
    var family: String?
    var size: Double?
}

private struct TerminalFontKey: EnvironmentKey {
    static var defaultValue: TerminalFontRequest { TerminalFontRequest() }
}

private struct TerminalThemeKey: EnvironmentKey {
    static var defaultValue: String? { nil }
}

private struct TerminalTitleActionKey: EnvironmentKey {
    static var defaultValue: ((String) -> Void)? { nil }
}

private struct TerminalExitActionKey: EnvironmentKey {
    static var defaultValue: (() -> Void)? { nil }
}

extension EnvironmentValues {
    /// The font ``View/terminalFont(_:size:)`` names.
    var terminalFont: TerminalFontRequest {
        get { self[TerminalFontKey.self] }
        set { self[TerminalFontKey.self] = newValue }
    }

    /// The theme ``View/terminalTheme(_:)`` names.
    var terminalTheme: String? {
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
}

/// Carries a terminal's title and exit to the SwiftUI actions, and its fed
/// bytes to the view.
@MainActor
final class TerminalCoordinator: TerminalSurfaceObserver {
    /// The title action the environment gives now.
    var titleAction: ((String) -> Void)?
    /// The exit action the environment gives now.
    var exitAction: (() -> Void)?
    /// The task writing a fed stream to the view, while one runs.
    private var feedTask: Task<Void, Never>?

    /// Writes each element of `output` to `view` until the stream finishes or
    /// ``stop()`` is called.
    ///
    /// - Parameters:
    ///   - view: The view to write to, held weakly.
    ///   - output: The bytes to write.
    func feed(_ view: TerminalView, from output: AsyncStream<Data>) {
        feedTask = Task { @MainActor [weak view] in
            for await bytes in output {
                view?.feed(bytes)
            }
        }
    }

    /// Stops writing a fed stream.
    func stop() {
        feedTask?.cancel()
        feedTask = nil
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
        MainActor.assumeIsolated { titleAction?(title) }
    }

    /// Calls the exit action.
    nonisolated func terminalSurfaceDidExit(_: TerminalSurface) {
        MainActor.assumeIsolated { exitAction?() }
    }
}

/// ``TerminalView`` in SwiftUI.
@MainActor
struct TerminalRepresentable {
    let program: Terminal.Program

    func makeCoordinator() -> TerminalCoordinator {
        TerminalCoordinator()
    }

    /// Makes the view, dresses it from the environment and starts its program.
    ///
    /// The coordinator observes the view before the program starts, so an
    /// exit that comes at once is heard.
    ///
    /// - Parameters:
    ///   - coordinator: The coordinator SwiftUI keeps for the view.
    ///   - environment: The environment the view is made in.
    /// - Returns: The view.
    func makeTerminalView(coordinator: TerminalCoordinator, environment: EnvironmentValues) -> TerminalView {
        let view = TerminalView()
        update(view, coordinator: coordinator, environment: environment)
        switch program {
        case .shell(let initialDirectory):
            view.launchShell(initialDirectory: initialDirectory)
        case .command(let commandLine):
            view.launchCommand(commandLine)
        case .feed(let output):
            coordinator.feed(view, from: output)
        }
        return view
    }

    /// Carries the environment's font, theme and actions to the view.
    ///
    /// A font or theme is applied only when it differs from what the view was
    /// last asked for: applying one refits the grid or resets the colours a
    /// program set, which an unrelated update must not do. The observer is
    /// assigned again when a title action comes or goes, because that is when
    /// the surface asks whether its title is wanted.
    ///
    /// - Parameters:
    ///   - view: The view.
    ///   - coordinator: The coordinator SwiftUI keeps for the view.
    ///   - environment: The environment as it stands.
    func update(_ view: TerminalView, coordinator: TerminalCoordinator, environment: EnvironmentValues) {
        let hadTitleAction = coordinator.titleAction != nil
        coordinator.titleAction = environment.terminalTitleAction
        coordinator.exitAction = environment.terminalExitAction
        if view.observer == nil || hadTitleAction != (coordinator.titleAction != nil) {
            view.observer = coordinator
        }
        let font = environment.terminalFont
        if font.family != view.fontFamily || font.size != view.fontSize {
            view.requestFont(family: font.family, size: font.size)
        }
        if environment.terminalTheme != view.themeName {
            view.themeName = environment.terminalTheme
        }
    }
}

#if canImport(AppKit)
extension TerminalRepresentable: NSViewRepresentable {
    func makeNSView(context: Context) -> TerminalView {
        makeTerminalView(coordinator: context.coordinator, environment: context.environment)
    }

    func updateNSView(_ view: TerminalView, context: Context) {
        update(view, coordinator: context.coordinator, environment: context.environment)
    }

    static func dismantleNSView(_ view: TerminalView, coordinator: TerminalCoordinator) {
        coordinator.stop()
    }
}
#else
extension TerminalRepresentable: UIViewRepresentable {
    func makeUIView(context: Context) -> TerminalView {
        makeTerminalView(coordinator: context.coordinator, environment: context.environment)
    }

    func updateUIView(_ view: TerminalView, context: Context) {
        update(view, coordinator: context.coordinator, environment: context.environment)
    }

    static func dismantleUIView(_ view: TerminalView, coordinator: TerminalCoordinator) {
        coordinator.stop()
    }
}
#endif
