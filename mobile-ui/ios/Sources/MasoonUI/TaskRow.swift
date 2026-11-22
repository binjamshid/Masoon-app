// Study task row with status, estimated duration and an optional action.

import SwiftUI

/// Visual category of a task. Maps a task type to icon + accessible name.
/// This is presentation vocabulary only; the engine owns real task types.
public enum TaskRowKind: Sendable {
    case preparation      // tasbih + istighfar informational task
    case warmup           // ghayb warm-up
    case newHifz          // new memorization
    case repetition       // distributed repetition block
    case murajaah         // prior-hifz revision pool
    case listening        // scheduled listening
    case tasmee           // tasmeeʿ / assessment workflow (no audio)
    case review           // end-of-juz / consolidation review

    public var icon: String {
        switch self {
        case .preparation: return "sparkles"
        case .warmup: return "flame"
        case .newHifz: return "book"
        case .repetition: return "repeat"
        case .murajaah: return "arrow.counterclockwise"
        case .listening: return "ear"
        case .tasmee: return "person.wave.2"
        case .review: return "checklist"
        }
    }

    public func accessibleName(locale: Locale) -> String {
        switch self {
        case .preparation: return locale.studyText("استعداد", "Preparation")
        case .warmup: return locale.studyText("تهيئة", "Warm-up")
        case .newHifz: return locale.studyText("حفظ جديد", "New memorization")
        case .repetition: return locale.studyText("تكرار", "Repetition")
        case .murajaah: return locale.studyText("مراجعة", "Revision")
        case .listening: return locale.studyText("استماع", "Listening")
        case .tasmee: return locale.studyText("تسميع", "Recitation check")
        case .review: return locale.studyText("مراجعة شاملة", "Review")
        }
    }
}

/// Execution status of a task row. Icon + label + color, never color alone.
public enum TaskRowStatus: Sendable {
    case pending, inProgress, completed, skipped, needsAttention

    public func label(locale: Locale) -> String {
        switch self {
        case .pending: return locale.studyText("لم تبدأ", "Not started")
        case .inProgress: return locale.studyText("قيد التنفيذ", "In progress")
        case .completed: return locale.studyText("مكتملة", "Completed")
        case .skipped: return locale.studyText("متجاوزة", "Skipped")
        case .needsAttention: return locale.studyText("تحتاج انتباه", "Needs attention")
        }
    }

    public var icon: String {
        switch self {
        case .pending: return "circle"
        case .inProgress: return "play.circle.fill"
        case .completed: return "checkmark.circle.fill"
        case .skipped: return "minus.circle"
        case .needsAttention: return "exclamationmark.circle.fill"
        }
    }

    public var tint: Color {
        switch self {
        case .pending: return MasoonColors.textSecondary
        case .inProgress: return MasoonColors.primary
        case .completed: return MasoonColors.success
        case .skipped: return MasoonColors.textSecondary
        case .needsAttention: return MasoonColors.attention
        }
    }
}

public struct TaskRow: View {
    private let kind: TaskRowKind
    private let title: String
    private let rangeText: String?
    private let estMinutes: Int?
    private let status: TaskRowStatus
    private let action: (() -> Void)?

    @Environment(\.locale) private var locale

    /// - Parameters:
    ///   - title: Arabic task label, e.g. "الحفظ الجديد"
    ///   - rangeText: caller-formatted range, for example "Exercises 1–5"
    ///   - estMinutes: estimated minutes; rendered as a chip in locale numerals
    public init(
        kind: TaskRowKind,
        title: String,
        rangeText: String? = nil,
        estMinutes: Int? = nil,
        status: TaskRowStatus = .pending,
        action: (() -> Void)? = nil
    ) {
        self.kind = kind
        self.title = title
        self.rangeText = rangeText
        self.estMinutes = estMinutes
        self.status = status
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
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(accessibilitySummary))
        .accessibilityAddTraits(action != nil ? .isButton : [])
    }

    private var content: some View {
        HStack(spacing: MasoonSpacing.md) {
            Image(systemName: kind.icon)
                .font(.body)
                .foregroundStyle(MasoonColors.primary)
                .masoonScaledFrame(width: 28, minimum: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: MasoonSpacing.xs) {
                Text(title)
                    .masoonType(.body)
                if let rangeText {
                    Text(rangeText)
                        .masoonType(.footnote, color: MasoonColors.textSecondary)
                }
            }

            Spacer(minLength: MasoonSpacing.sm)

            if let estMinutes {
                Chip(
                    "\(MasoonNumerals.format(estMinutes, locale: locale)) \(locale.studyText("د", "min"))",
                    icon: "clock"
                )
            }

            Image(systemName: status.icon)
                .font(.title3)
                .foregroundStyle(status.tint)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, MasoonSpacing.lg)
        .padding(.vertical, MasoonSpacing.md)
        .frame(minHeight: MasoonMetrics.minTarget)
        .contentShape(Rectangle())
    }

    private var accessibilitySummary: String {
        var parts = [kind.accessibleName(locale: locale), title]
        if let rangeText { parts.append(rangeText) }
        if let estMinutes {
            parts.append(locale.studyText("\(MasoonNumerals.format(estMinutes, locale: locale)) دقائق تقديراً", "about \(MasoonNumerals.format(estMinutes, locale: locale)) minutes"))
        }
        parts.append(status.label(locale: locale))
        return parts.joined(separator: locale.studyText("، ", ", "))
    }
}
