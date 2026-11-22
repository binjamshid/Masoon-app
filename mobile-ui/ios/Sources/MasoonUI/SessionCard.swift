// Summary of a study session with completion and status.

import SwiftUI

public enum SessionCardState: Sendable {
    case notStarted, inProgress, completed, rest

    public func label(locale: Locale) -> String {
        switch self {
        case .notStarted: return locale.studyText("لم تبدأ", "Not started")
        case .inProgress: return locale.studyText("قيد التنفيذ", "In progress")
        case .completed: return locale.studyText("مكتملة", "Completed")
        case .rest: return locale.studyText("يوم راحة", "Rest day")
        }
    }

    public var icon: String {
        switch self {
        case .notStarted: return "circle"
        case .inProgress: return "play.circle"
        case .completed: return "checkmark.circle.fill"
        case .rest: return "moon.zzz"
        }
    }

    public var tint: Color {
        switch self {
        case .notStarted: return MasoonColors.textSecondary
        case .inProgress: return MasoonColors.primary
        case .completed: return MasoonColors.success
        case .rest: return MasoonColors.textSecondary
        }
    }
}

public struct SessionCard: View {
    @Environment(\.locale) private var locale

    private let title: String
    private let subtitle: String?
    private let progress: Double
    private let state: SessionCardState
    private let action: (() -> Void)?

    /// - Parameters:
    ///   - title: e.g. "جلسة الصباح"
    ///   - subtitle: optional summary, e.g. "٤ مهام · ~٢٥ دقيقة"
    ///   - progress: 0…1 session completion
    public init(
        title: String,
        subtitle: String? = nil,
        progress: Double,
        state: SessionCardState,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.progress = progress
        self.state = state
        self.action = action
    }

    public var body: some View {
        Group {
            if let action {
                Button(action: action) { content }
                    .buttonStyle(.plain)
            } else {
                content
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text(accessibilitySummary))
        .accessibilityAddTraits(action != nil ? .isButton : [])
    }

    private var content: some View {
        HStack(spacing: MasoonSpacing.lg) {
            ProgressRing(progress: progress, size: 52, tint: state.tint)
            VStack(alignment: .leading, spacing: MasoonSpacing.xs) {
                Text(title)
                    .masoonType(.headline)
                if let subtitle {
                    Text(subtitle)
                        .masoonType(.subheadline, color: MasoonColors.textSecondary)
                }
                HStack(spacing: MasoonSpacing.xs) {
                    Image(systemName: state.icon)
                        .font(.caption)
                        .accessibilityHidden(true)
                    Text(state.label(locale: locale))
                        .font(.masoon(.caption))
                }
                .foregroundStyle(state.tint)
            }
            Spacer(minLength: 0)
            if action != nil {
                DirectionalChevron()
            }
        }
        .padding(MasoonSpacing.lg)
        .frame(minHeight: MasoonMetrics.minTarget)
        .masoonCard()
        .contentShape(Rectangle())
    }

    private var accessibilitySummary: String {
        var parts = [title]
        if let subtitle { parts.append(subtitle) }
        parts.append(state.label(locale: locale))
        return parts.joined(separator: locale.studyText("، ", ", "))
    }
}
