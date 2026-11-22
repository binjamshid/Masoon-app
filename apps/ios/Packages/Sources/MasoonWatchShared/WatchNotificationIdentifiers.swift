/// Notification category and action identifiers, and the `userInfo` keys that
/// travel with a reminder.
///
/// These live in a target both app targets link so they physically cannot drift.
/// The mechanism depends on an exact string match: when a mirrored iOS
/// notification's `categoryIdentifier` matches a category the **watchOS** app
/// registered, watchOS presents the watch app's actions and routes the response
/// to the watch app's delegate, with no phone involvement. A typo on either side
/// degrades silently to a notification with no actions — which is why nothing
/// here is spelled out twice.
public enum WatchNotificationIdentifiers {

    /// Registered by both targets. `ReminderScheduler` stamps it on every
    /// session reminder.
    public static let sessionCategory = "masoon.category.session"
    /// Listening reminders: informational, no completion action.
    public static let listeningCategory = "masoon.category.listening"

    /// Completes the task named in `userInfo` with `self_check` evidence.
    public static let completeAction = "masoon.action.complete"
    /// Opens the watch app on the task rather than acting on it.
    public static let openAction = "masoon.action.open"

    /// `userInfo` keys. `date` is the task instance's plan-LocalDate, not the
    /// delivery date: `EventFold` keys on `payload.date` (D-032), and a reminder
    /// fired at 05:00 for a task dated the previous day must still complete the
    /// right instance.
    public enum UserInfoKey {
        public static let planId = "plan_id"
        public static let taskUid = "task_uid"
        public static let date = "date"
        public static let evidenceKind = "evidence_kind"
        public static let planTimezone = "plan_timezone"
    }
}
