package masoon.curriculum

import masoon.domain.Uuid5

data class TaskDeduplicationResult(
    val output: List<TaskInstance>,
    /** One entry per pre-dedup task, with merged UIDs for state advancement. */
    val stateTasks: List<TaskInstance>,
)

object TaskDeduplicator {
    fun deduplicate(tasks: List<TaskInstance>): TaskDeduplicationResult {
        val groups = linkedMapOf<String, MutableList<Int>>()
        tasks.forEachIndexed { index, task -> groups.getOrPut(executionKey(task)) { mutableListOf() }.add(index) }
        val output = mutableListOf<TaskInstance>()
        val stateTasks = tasks.toMutableList()
        for ((key, indices) in groups) {
            val first = tasks[indices.first()]
            if (indices.size == 1) {
                output += first
                continue
            }
            val group = indices.map(tasks::get)
            val origins = group.map { it.originRuleId }.distinct().sorted()
            val baseFlags = group.flatMap { it.flags }.filterNot { it.startsWith("source_rule:") }.distinct()
            val flags = (baseFlags + origins.map { "source_rule:$it" }).distinct().sorted()
            val uid = Uuid5.uuid5(first.planId, "exact_execution|${first.date}|$key")
            output += first.copy(
                taskUid = uid,
                originRuleId = origins.joinToString("+"),
                estimatedMinutes = group.maxOf { it.estimatedMinutes },
                flags = flags,
            )
            indices.forEach { index -> stateTasks[index] = tasks[index].copy(taskUid = uid) }
        }
        return TaskDeduplicationResult(output, stateTasks)
    }

    private fun executionKey(task: TaskInstance): String {
        val values = listOf(
            task.content.joinToString(",") { "${it.surah}:${it.ayahStart}-${it.ayahEnd}" },
            task.type,
            task.targetRepetitions?.toString() ?: "nil",
            task.spacingMinutes?.toString() ?: "nil",
            task.listenCount?.toString() ?: "nil",
            task.evidenceCompact,
            if (task.windowOpensOn == null) "nil" else "${task.windowOpensOn}..${task.windowClosesOn}",
            task.flags.filterNot { it.startsWith("source_rule:") }.sorted().joinToString(","),
        )
        return values.joinToString("|") { "${it.toByteArray(Charsets.UTF_8).size}:$it" }
    }
}
