// Records a named listener’s assessment as reported by the learner.

import SwiftUI
import Foundation

public struct TasmeeAttestationForm: View {
    public struct Submission: Sendable {
        public let musammiName: String
        public let time: String
        public let score: Int
        public let mistakeCount: Int
    }

    private let onSubmit: (Submission) -> Void
    private let onCancel: () -> Void

    @State private var musammiName: String = ""
    @State private var time: Date
    @State private var score: Int = 100
    @State private var mistakeCount: Int = 0

    @Environment(\.locale) private var locale

    /// Seeds the picker from an HH:mm device-local time.
    public init(
        defaultTime: String,
        onSubmit: @escaping (Submission) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _time = State(initialValue: Self.date(fromHHmm: defaultTime) ?? Date())
    }

    private var trimmedName: String {
        var chars = Substring(musammiName)
        while let first = chars.first, first.isWhitespace { chars.removeFirst() }
        while let last = chars.last, last.isWhitespace { chars.removeLast() }
        return String(chars)
    }

    private var isFilled: Bool { !trimmedName.isEmpty }

    public var body: some View {
        Form {
            Section {
                TextField(
                    locale.studyText("اسم المُسمِّع", "Listener's name"),
                    text: $musammiName)
                #if os(iOS)
                .textInputAutocapitalization(.words)
                #endif
                DatePicker(
                    locale.studyText("وقت الجلسة", "Session time"),
                    selection: $time,
                    displayedComponents: .hourAndMinute)
            } header: {
                Text(locale.studyText("من استمع، ومتى", "Who listened, and when"))
            } footer: {
                Text(locale.studyText(
                    "المُسمِّع هو من استمع إلى تسميعك وحكم عليه — التطبيق لا يستمع إلى تلاوتك ولا يقيّمها.",
                    "Listener — the person who listened to your tasmee' and made the call. The app never listens to or grades your recitation."))
            }

            Section {
                Stepper(value: $score, in: 0...100) {
                    HStack {
                        Text(locale.studyText("الدرجة", "Score"))
                        Spacer()
                        Text(MasoonNumerals.format(score, locale: locale))
                            .foregroundStyle(MasoonColors.textSecondary)
                    }
                }
                Stepper(value: $mistakeCount, in: 0...200) {
                    HStack {
                        Text(locale.studyText("عدد الأخطاء", "Mistake count"))
                        Spacer()
                        Text(MasoonNumerals.format(mistakeCount, locale: locale))
                            .foregroundStyle(MasoonColors.textSecondary)
                    }
                }
            } header: {
                Text(locale.studyText("ما ذكره المُسمِّع", "What the listener reported"))
            } footer: {
                Text(locale.studyText(
                    "الدرجة وعدد الأخطاء كما ذكرهما المُسمِّع — إقرار منك بما قاله، وليس تقييماً آلياً.",
                    "The score and mistake count are exactly as the listener reported them — your record of what they said, not an automated grade."))
            }

            Section {
                Button {
                    onSubmit(Submission(
                        musammiName: trimmedName,
                        time: Self.hhmm(from: time),
                        score: score,
                        mistakeCount: mistakeCount))
                } label: {
                    HStack {
                        Spacer()
                        Text(locale.studyText("تسجيل التصديق", "Record the attestation"))
                        Spacer()
                    }
                }
                .disabled(!isFilled)
            } footer: {
                if !isFilled {
                    Text(locale.studyText("اسم المُسمِّع مطلوب.", "The listener's name is required."))
                }
            }
        }
        .navigationTitle(locale.studyText("تصديق التسميع", "Recitation attestation"))
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(locale.studyText("إلغاء", "Cancel"), action: onCancel)
            }
        }
    }

    // Convert between a device-local wall-clock string and the picker date.

    private static func hhmm(from date: Date) -> String {
        let comps = Calendar.current.dateComponents([.hour, .minute], from: date)
        return String(format: "%02d:%02d", comps.hour ?? 0, comps.minute ?? 0)
    }

    private static func date(fromHHmm text: String) -> Date? {
        let parts = text.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = h
        comps.minute = m
        return Calendar.current.date(from: comps)
    }
}
