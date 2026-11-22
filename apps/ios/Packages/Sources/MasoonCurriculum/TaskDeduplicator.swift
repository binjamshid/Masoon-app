import MasoonDomain

struct TaskDeduplicationResult {
    let output: [TaskInstance]
    /// One entry per pre-dedup task. State folds use these so every source rule
    /// observes the merged UID and a single completion advances every rotation.
    let stateTasks: [TaskInstance]
}

enum TaskDeduplicator {
    static func deduplicate(namespace: [UInt8], tasks: [TaskInstance]) -> TaskDeduplicationResult {
        var groupIndices: [String: [Int]] = [:]
        var keyOrder: [String] = []
        for (index, task) in tasks.enumerated() {
            let key = executionKey(task)
            if groupIndices[key] == nil { keyOrder.append(key) }
            groupIndices[key, default: []].append(index)
        }

        var output: [TaskInstance] = []
        var stateTasks = tasks
        for key in keyOrder {
            guard let indices = groupIndices[key], let firstIndex = indices.first else { continue }
            if indices.count == 1 {
                output.append(tasks[firstIndex])
                continue
            }
            let group = indices.map { tasks[$0] }
            let origins = Array(Set(group.map(\.originRuleId))).sorted()
            let baseFlags = Array(Set(group.flatMap(\.flags).filter { !$0.hasPrefix("source_rule:") })).sorted()
            let flags = (baseFlags + origins.map { "source_rule:\($0)" }).sorted()
            let uid = UUIDv5.uuid(
                namespace: namespace,
                name: "exact_execution|\(group[0].date.isoString)|\(key)")
            let merged = copying(
                group[0], originRuleId: origins.joined(separator: "+"),
                estimatedMinutes: group.map(\.estimatedMinutes).max() ?? group[0].estimatedMinutes,
                flags: flags, taskUid: uid)
            output.append(merged)
            for index in indices { stateTasks[index] = copying(tasks[index], taskUid: uid) }
        }
        return TaskDeduplicationResult(output: output, stateTasks: stateTasks)
    }

    private static func executionKey(_ task: TaskInstance) -> String {
        let values = [
            task.content.map { "\($0.work):\($0.unitStart)-\($0.unitEnd)" }.joined(separator: ","),
            task.type, optional(task.repetitions), optional(task.spacingMinutes), optional(task.listenCount),
            task.evidence?.compact ?? "nil",
            task.window.map { "\($0.opensOn.isoString)..\($0.closesOn.isoString)" } ?? "nil",
            task.flags.filter { !$0.hasPrefix("source_rule:") }.sorted().joined(separator: ","),
        ]
        return values.map { "\($0.utf8.count):\($0)" }.joined(separator: "|")
    }

    private static func optional(_ value: Int?) -> String { value.map(String.init) ?? "nil" }

    private static func copying(
        _ task: TaskInstance,
        originRuleId: String? = nil,
        estimatedMinutes: Int? = nil,
        flags: [String]? = nil,
        taskUid: String? = nil
    ) -> TaskInstance {
        TaskInstance(
            date: task.date, dayClass: task.dayClass, session: task.session,
            ordering: task.ordering, type: task.type,
            originRuleId: originRuleId ?? task.originRuleId, occurrence: task.occurrence,
            content: task.content, repetitions: task.repetitions,
            spacingMinutes: task.spacingMinutes, listenCount: task.listenCount,
            window: task.window, estimatedMinutes: estimatedMinutes ?? task.estimatedMinutes,
            evidence: task.evidence, flags: flags ?? task.flags, taskUid: taskUid ?? task.taskUid)
    }
}
