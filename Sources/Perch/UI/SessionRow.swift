import SwiftUI
import PerchKit

/// One session: always-visible summary, plus token detail and transcript when
/// the row is expanded.
struct SessionRow: View {
    let session: AgentSession
    let appearance: ProviderAppearance?
    let isExpanded: Bool
    /// Briefly true right after this task finished, to draw the eye to it.
    var isFlashing: Bool = false
    let onToggle: () -> Void
    let onOpen: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            summary
            if isExpanded {
                detail
            }
        }
        .padding(9)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(.white.opacity(isHovering ? 0.09 : 0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(session.state.tint, lineWidth: isFlashing ? 1.5 : 0)
                .opacity(isFlashing ? 1 : 0)
                .animation(.easeOut(duration: 0.3), value: isFlashing)
        )
        .overlay(alignment: .leading) {
            // Accent stripe makes the owning tool identifiable without reading.
            RoundedRectangle(cornerRadius: 2)
                .fill(appearance?.color ?? .gray)
                .frame(width: 2.5)
                .padding(.vertical, 7)
        }
        .contentShape(.rect)
        .onTapGesture(perform: onToggle)
        .onHover { isHovering = $0 }
    }

    private var summary: some View {
        HStack(spacing: 8) {
            Image(systemName: appearance?.symbolName ?? "sparkles")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(appearance?.color ?? .secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 2) {
                Text(session.title)
                    .font(.system(size: 11.5, weight: .medium))
                    .foregroundStyle(.white.opacity(0.95))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Without a bound the title's intrinsic width pushes the
                    // token column off the panel.
                    .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 5) {
                    StateIndicator(state: session.state)
                    Text(session.state.label)
                        .foregroundStyle(session.state.tint)
                    if let project = session.projectName {
                        Text("·").foregroundStyle(Palette.label)
                        Text(project).foregroundStyle(Palette.secondary).lineLimit(1)
                    }
                    if let branch = session.branch {
                        Text("·").foregroundStyle(Palette.label)
                        Label(branch, systemImage: "arrow.triangle.branch")
                            .foregroundStyle(Palette.secondary)
                            .lineLimit(1)
                    }
                }
                .font(.system(size: 9.5, weight: .medium))
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 2) {
                Text(Format.tokens(session.usage.total))
                    .font(.system(size: 10.5, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(0.85))
                Text(Format.relative(session.updatedAt))
                    .font(.system(size: 9))
                    .foregroundStyle(Palette.label)
            }

            // Jump-to-app affordance, revealed on hover to keep the row calm.
            if isHovering {
                Button(action: onOpen) {
                    Image(systemName: "arrow.up.forward.app.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .buttonStyle(.plain)
                .help("Open in \(session.providerID)")
                .transition(.opacity)
            }
        }
    }

    private var detail: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let fraction = session.usage.contextFraction {
                ContextGauge(fraction: fraction, usage: session.usage)
            }
            TokenBreakdown(usage: session.usage)

            if let model = session.model {
                HStack(spacing: 4) {
                    Image(systemName: "cpu")
                    Text(model)
                    Spacer()
                    Image(systemName: "clock")
                    Text(Format.duration(session.duration))
                }
                .font(.system(size: 9, design: .rounded))
                .foregroundStyle(Palette.label)
            }

            if !session.transcript.isEmpty {
                Divider().opacity(0.12)
                TranscriptList(entries: session.transcript)
            }
        }
        .padding(.leading, 22)
        .transition(.opacity.combined(with: .move(edge: .top)))
    }
}

/// How full the context window is — the number people actually act on.
struct ContextGauge: View {
    let fraction: Double
    let usage: TokenUsage

    private var tint: Color {
        switch fraction {
        case ..<0.6: .green
        case ..<0.85: .yellow
        default: .red
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("Context")
                Spacer()
                Text("\(Int(fraction * 100))%")
                    .monospacedDigit()
                    .foregroundStyle(tint)
                if let window = usage.contextWindow {
                    Text("of \(Format.tokens(window))")
                        .foregroundStyle(Palette.label)
                }
            }
            .font(.system(size: 9, weight: .medium, design: .rounded))
            .foregroundStyle(Palette.secondary)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.1))
                    Capsule()
                        .fill(tint.gradient)
                        .frame(width: max(2, proxy.size.width * fraction))
                }
            }
            .frame(height: 3.5)
        }
    }
}

/// Input / output split, with the cached share of input called out.
///
/// "Cached" is a *portion of* In, not an addition to it — cached input costs a
/// fraction of fresh input, so it is worth seeing, but it must never read as
/// extra volume.
struct TokenBreakdown: View {
    let usage: TokenUsage

    var body: some View {
        HStack(spacing: 10) {
            metric("In", usage.input, .blue)
            metric("Out", usage.output, .purple)
            if usage.cached > 0 {
                metric("of which cached", usage.cached, .teal)
            }
            if usage.reasoning > 0 { metric("Think", usage.reasoning, .indigo) }
            Spacer()
        }
    }

    private func metric(_ label: String, _ value: Int, _ color: Color) -> some View {
        HStack(spacing: 3) {
            Circle().fill(color).frame(width: 4, height: 4)
            Text(label).foregroundStyle(Palette.label)
            Text(Format.tokens(value))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.8))
        }
        .font(.system(size: 9, weight: .medium, design: .rounded))
    }
}

/// The last few turns, so the user can tell what the agent is doing without
/// switching to it.
struct TranscriptList: View {
    let entries: [TranscriptEntry]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(entries) { entry in
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: symbol(for: entry.role))
                        .font(.system(size: 8))
                        .foregroundStyle(color(for: entry.role))
                        .frame(width: 10)
                    Text(entry.text)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.white.opacity(entry.role == .tool ? 0.5 : 0.72))
                        .lineLimit(entry.role == .tool ? 1 : 3)
                        .truncationMode(.tail)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func symbol(for role: TranscriptEntry.Role) -> String {
        switch role {
        case .user: "person.fill"
        case .assistant: "sparkle"
        case .tool: "wrench.fill"
        }
    }

    private func color(for role: TranscriptEntry.Role) -> Color {
        switch role {
        case .user: .blue
        case .assistant: .purple
        case .tool: .gray
        }
    }
}
