import SwiftUI
import PerchKit

/// Which tools to watch, and how completion should be announced.
struct SettingsView: View {
    let store: SessionStore
    let settings: Settings

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                section("Watched apps") {
                    if store.knownProviders.isEmpty {
                        Text("No supported tools found")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.label)
                    } else {
                        ForEach(store.knownProviders) { info in
                            providerToggle(info)
                        }
                        Text("Disabled tools are not polled at all.")
                            .font(.system(size: 8.5))
                            .foregroundStyle(Palette.label)
                    }
                }

                section("When a task finishes") {
                    toggle("Play a sound", isOn: Binding(
                        get: { settings.notifySound != .none },
                        // Restore the default rather than leaving it silent.
                        set: { settings.notifySound = $0 ? .glass : .none }
                    ))

                    if settings.notifySound != .none {
                        // A system `Picker` renders as a near-black popup on
                        // this panel and is effectively unreadable. Inline
                        // chips give the same choice with real contrast, and
                        // preview the sound on tap.
                        SoundChips(
                            selection: Binding(
                                get: { settings.notifySound },
                                set: { settings.notifySound = $0; $0.play() }
                            )
                        )
                    }

                    toggle("Flash the notch", isOn: Binding(
                        get: { settings.notifyVisual },
                        set: { settings.notifyVisual = $0 }
                    ))
                    toggle("Show a notification", isOn: Binding(
                        get: { settings.notifyBanner },
                        set: { settings.notifyBanner = $0 }
                    ))
                }

                section("Sessions") {
                    HStack {
                        Text("Hide after")
                            .font(.system(size: 10))
                            .foregroundStyle(Palette.secondary)
                        Spacer()
                        Text("\(Int(settings.visibilityHours))h")
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(Palette.primary)
                    }
                    Slider(
                        value: Binding(
                            get: { settings.visibilityHours },
                            set: { settings.visibilityHours = $0 }
                        ),
                        in: 1 ... 48,
                        step: 1
                    ) { editing in
                        // Providers hold the window, so rebuild once the drag ends.
                        if !editing { reload() }
                    }
                    .controlSize(.mini)

                    // Purely a display choice now: subagent spend is always
                    // counted, this only decides whether they get their own rows.
                    toggle("Show Codex subagents", isOn: Binding(
                        get: { settings.showSubagents },
                        set: { settings.showSubagents = $0 }
                    ))
                }

                section("Claude Code limits") {
                    StatuslineSection()
                }

                section("Live reporting") {
                    ReportingSection()
                }

                section("Plugins") {
                    Button {
                        let directory = PluginLoader.pluginsDirectory
                        try? FileManager.default.createDirectory(
                            at: directory, withIntermediateDirectories: true
                        )
                        NSWorkspace.shared.open(directory)
                    } label: {
                        Label("Open plugins folder", systemImage: "folder")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.cyan)

                    Button {
                        reload()
                    } label: {
                        Label("Reload plugins", systemImage: "arrow.clockwise")
                            .font(.system(size: 10))
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.cyan)
                }
            }
            .padding(10)
        }
        .scrollIndicators(.never)
    }

    private func reload() {
        store.reloadProviders()
        Task { await store.refresh() }
    }

    private func providerToggle(_ info: ProviderInfo) -> some View {
        HStack(spacing: 7) {
            Image(systemName: info.appearance.symbolName)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(info.appearance.color)
                .frame(width: 14)
            Text(info.displayName)
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.primary)
            Spacer()
            Toggle("", isOn: Binding(
                get: { settings.isEnabled(info.id) },
                set: { settings.setEnabled($0, for: info.id); reload() }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            .tint(.green)
        }
    }

    private func toggle(_ label: String, isOn: Binding<Bool>) -> some View {
        HStack {
            Text(label)
                .font(.system(size: 10.5))
                .foregroundStyle(Palette.primary)
            Spacer()
            Toggle("", isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.green)
        }
    }

    /// Turn on the push reporters each tool offers.
    ///
    /// Both write into the user's own config, so this is opt-in and says which
    /// file it touches. Each tool has its own mechanism — hooks for Claude
    /// Code, `notify` for Codex — so they install independently.
    private struct ReportingSection: View {
        @State private var claudeInstalled = ClaudeCodeReporter.isInstalled()
        @State private var codexInstalled = CodexReporter.isInstalled()
        @State private var error: String?

        var body: some View {
            VStack(alignment: .leading, spacing: 8) {
                Text("Let each tool report its own task state instead of Perch guessing from file timestamps.")
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                row(
                    name: "Claude Code hooks",
                    detail: "Adds Perch's hooks to ~/.claude/settings.json. Your own hooks are left alone.",
                    isOn: claudeInstalled
                ) {
                    if claudeInstalled {
                        try ClaudeCodeReporter.uninstall()
                    } else {
                        try ClaudeCodeReporter.install()
                    }
                    claudeInstalled = ClaudeCodeReporter.isInstalled()
                }

                row(
                    name: "Codex notify",
                    detail: "Sets `notify` in ~/.codex/config.toml. Any program already there keeps running.",
                    isOn: codexInstalled
                ) {
                    if codexInstalled {
                        try CodexReporter.uninstall()
                    } else {
                        try CodexReporter.install()
                    }
                    codexInstalled = CodexReporter.isInstalled()
                }

                if let error {
                    Text(error)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }

        private func row(
            name: String,
            detail: String,
            isOn: Bool,
            action: @escaping () throws -> Void
        ) -> some View {
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(name)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Palette.primary)
                    Spacer()
                    Toggle("", isOn: Binding(
                        get: { isOn },
                        set: { _ in
                            error = nil
                            do { try action() } catch { self.error = error.localizedDescription }
                        }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                }
                Text(detail)
                    .font(.system(size: 8.5))
                    .foregroundStyle(Palette.label)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Install or remove the status-line helper.
    ///
    /// This writes to the user's own Claude Code settings, so it is opt-in and
    /// says plainly what it changes rather than doing it silently.
    private struct StatuslineSection: View {
        private let store = StatuslineStore.shared
        @State private var isInstalled = StatuslineStore.shared.isInstalled
        @State private var error: String?

        var body: some View {
            VStack(alignment: .leading, spacing: 6) {
                Text(
                    isInstalled
                        ? "Reading 5-hour and weekly limits, and the real context-window size, from Claude Code's status line."
                        : "Claude Code sends its rate limits and true context-window size only to a status-line command — they are never written to session logs."
                )
                .font(.system(size: 9))
                .foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if !isInstalled {
                    Text("Enabling sets `statusLine` in ~/.claude/settings.json. Any status line you already use is kept and still runs.")
                        .font(.system(size: 8.5))
                        .foregroundStyle(Palette.label)
                        .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 6) {
                    Button {
                        toggle()
                    } label: {
                        Label(
                            isInstalled ? "Disable" : "Enable limits",
                            systemImage: isInstalled ? "xmark.circle" : "checkmark.circle"
                        )
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(isInstalled ? Palette.primary : Color.black)
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(isInstalled ? Color.white.opacity(0.12) : Color.green.opacity(0.9))
                        )
                    }
                    .buttonStyle(.plain)

                    if isInstalled, store.hasData {
                        Label("Receiving data", systemImage: "checkmark.seal.fill")
                            .font(.system(size: 9))
                            .foregroundStyle(.green)
                    } else if isInstalled {
                        Text("Waiting for the next Claude Code message…")
                            .font(.system(size: 8.5))
                            .foregroundStyle(Palette.label)
                    }
                }

                if let error {
                    Text(error)
                        .font(.system(size: 8.5))
                        .foregroundStyle(.orange)
                }
            }
        }

        private func toggle() {
            error = nil
            do {
                if isInstalled {
                    try store.uninstall()
                } else {
                    try store.installHelper()
                    try store.configureClaudeCode()
                }
                isInstalled = store.isInstalled
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    /// Selectable sound chips, sized to wrap within the panel.
    private struct SoundChips: View {
        @Binding var selection: CompletionSound

        private let options = CompletionSound.allCases.filter { $0 != .none }

        var body: some View {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 5) {
                    Text("Sound")
                        .font(.system(size: 10))
                        .foregroundStyle(Palette.secondary)
                    Spacer()
                    Text("Tap to preview")
                        .font(.system(size: 8.5))
                        .foregroundStyle(Palette.label)
                }
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 5), count: 3),
                    spacing: 5
                ) {
                    ForEach(options) { option in
                        chip(option)
                    }
                }
            }
        }

        private func chip(_ option: CompletionSound) -> some View {
            let isSelected = selection == option
            return Button { selection = option } label: {
                HStack(spacing: 3) {
                    Image(systemName: isSelected ? "speaker.wave.2.fill" : "speaker.fill")
                        .font(.system(size: 8))
                    Text(option.title)
                        .font(.system(size: 9.5, weight: isSelected ? .semibold : .regular))
                        .lineLimit(1)
                }
                .foregroundStyle(isSelected ? Color.black : Palette.primary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color.green.opacity(0.9) : Color.white.opacity(0.10))
                )
            }
            .buttonStyle(.plain)
        }
    }

    private func section(
        _ title: String,
        @ViewBuilder content: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title.uppercased())
                .font(.system(size: 8.5, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.label)
                .kerning(0.6)
            content()
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(.white.opacity(0.05)))
    }
}
