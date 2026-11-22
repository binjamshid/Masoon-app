import MasoonDomain

/// Normalized task stream serializer — ENGINE_PARITY §3, byte-exact:
///
/// ```
/// date|day_class|session|ordering|type|origin_rule_id|content|reps|spacing_min|listen_count|window|est_min|evidence|flags|task_uid
/// ```
///
/// Lines joined with `\n`; the file ends with exactly one trailing `\n`.
/// After the last task line, one state checkpoint line:
/// `#STATE|cursor={surah}:{ayah}|juz_done={n}|cycle_weeks={n}|debt_new={n_ranges}|status={plan_status}`

public enum StreamSerializer {
    public static func serialize(_ result: GenerationResult) -> String {
        var lines: [String] = []
        lines.reserveCapacity(result.tasks.count + 1)
        for task in result.tasks {
            lines.append(line(for: task))
        }
        lines.append(stateLine(result.finalState))
        return lines.joined(separator: "\n") + "\n"
    }

    static func line(for task: TaskInstance) -> String {
        let content = task.content.map(\.streamForm).joined(separator: "+")
        let reps = task.repetitions.map(String.init) ?? ""
        let spacing = task.spacingMinutes.map(String.init) ?? ""
        let listen = task.listenCount.map(String.init) ?? ""
        let window = task.window.map { "\($0.opensOn.isoString)..\($0.closesOn.isoString)" } ?? ""
        // flags: comma-joined, sorted ASCII (already sorted at emission).
        let flags = task.flags.joined(separator: ",")
        return [
            task.date.isoString,
            task.dayClass,
            task.session,
            String(task.ordering),
            task.type,
            task.originRuleId,
            content,
            reps,
            spacing,
            listen,
            window,
            String(task.estimatedMinutes),
            task.evidence?.compact ?? "",
            flags,
            task.taskUid,
        ].joined(separator: "|")
    }

    static func stateLine(_ state: FinalPlanState) -> String {
        let cursor = state.cursor.map { "\($0.surah):\($0.ayah)" } ?? "-"
        return "#STATE|cursor=\(cursor)|juz_done=\(state.juzCompleted)|cycle_weeks=\(state.cycleWeeks)|debt_new=\(state.debtNewRanges)|status=\(state.status.rawValue)"
    }
}
