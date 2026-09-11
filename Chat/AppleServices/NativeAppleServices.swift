import Foundation
import EventKit
import Contacts

/// A queue-owned operation can be cancelled even while its calling task is suspended.
nonisolated final class AppleServiceFence: @unchecked Sendable {
    private let lock = NSLock()
    private var revoked = false
    private let deadline = Date().addingTimeInterval(30)
    func revoke() { lock.lock(); revoked = true; lock.unlock() }
    func check() throws {
        lock.lock(); let stopped = revoked; lock.unlock()
        if stopped { throw CancellationError() }
        if Date() > deadline { throw AppleServiceError.unavailable("Operation deadline reached. Narrow the query.") }
    }
}

nonisolated final class NativeAppleServices: @unchecked Sendable {
    static let shared = NativeAppleServices()
    private let queue = DispatchQueue(label: "Chat.AppleServices.native", qos: .userInitiated)
    // Created and used only on queue; neither framework object crosses the queue boundary.
    private var eventStore: EKEventStore?
    private var contactStore: CNContactStore?

    func execute(_ service: AppleServiceID, _ request: AppleServiceRequest, grant: AppleServiceGrant, fence: AppleServiceFence) async throws -> AppleServiceResult {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    try fence.check()
                    let result = service == .reminders
                        ? try self.reminders(request, grant: grant, fence: fence)
                        : try self.contacts(request, grant: grant, fence: fence)
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func reminders(_ r: AppleServiceRequest, grant: AppleServiceGrant, fence: AppleServiceFence) throws -> AppleServiceResult {
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            throw AppleServiceError.needsSetup("Connect Reminders in Settings → Apple Services.")
        }
        if eventStore == nil { eventStore = EKEventStore() }
        let store = eventStore!
        let lists = store.calendars(for: .reminder).filter { grant.permits($0.calendarIdentifier) }
        if r.action == "lists" {
            return .page(lists.map { AppleServiceRecord(id: $0.calendarIdentifier, title: $0.title, container: $0.calendarIdentifier, fields: ["account": $0.source.title, "writable": String($0.allowsContentModifications)]) }, request: r)
        }
        if r.action == "search" {
            let dueRange = try Self.reminderDueRange(from: r.dueFrom, through: r.dueThrough)
            let selectedIDs = try Self.reminderListIDs(
                lists: lists.map { ($0.calendarIdentifier, $0.title) },
                container: r.container,
                name: r.listName
            )
            let selected = lists.filter { selectedIDs.contains($0.calendarIdentifier) }
            guard !selected.isEmpty else { return AppleServiceResult(coverage: "All allowed lists") }
            let predicate: NSPredicate
            switch Self.reminderSearchState(r.value) {
            case "completed":
                predicate = store.predicateForCompletedReminders(
                    withCompletionDateStarting: nil,
                    ending: nil,
                    calendars: selected
                )
            case "all":
                predicate = store.predicateForReminders(in: selected)
            default:
                predicate = store.predicateForIncompleteReminders(
                    withDueDateStarting: nil,
                    ending: nil,
                    calendars: selected
                )
            }
            // EventKit's completion is delivered on an arbitrary queue; this dedicated queue can wait.
            let fetched = ReminderFetchBox()
            let semaphore = DispatchSemaphore(value: 0)
            let token = store.fetchReminders(matching: predicate) { reminders in
                fetched.set(reminders ?? [])
                semaphore.signal()
            }
            if semaphore.wait(timeout: .now() + 15) == .timedOut {
                store.cancelFetchRequest(token)
                throw AppleServiceError.unavailable("Reminder search timed out. Select a smaller list.")
            }
            try fence.check()
            let reminders = fetched.take()
            guard reminders.count <= 10_000 else { throw AppleServiceError.invalid("List exceeds search budget. Select a smaller list.") }
            let records = reminders.filter { item in
                if dueRange.start != nil || dueRange.end != nil {
                    guard let due = item.dueDateComponents?.date,
                          dueRange.start.map({ due >= $0 }) ?? true,
                          dueRange.end.map({ due < $0 }) ?? true else { return false }
                }
                return Self.reminderMatchesSearch(
                    title: item.title,
                    notes: item.notes,
                    isCompleted: item.isCompleted,
                    due: item.dueDateComponents,
                    request: r
                )
            }.map { item in
                var record = reminderRecord(item)
                record.fields = record.fields.filter { $0.key == "due" }
                record.isReminderSummary = true
                return record
            }.sorted { $0.id < $1.id }
            let scoped = r.container?.isEmpty == false || r.listName?.isEmpty == false
            return .page(records, request: r, coverage: scoped ? "List: \(selected[0].title)" : "All allowed lists")
        }
        let item: EKReminder
        if r.action == "create" {
            _ = try r.required(r.container ?? r.listName, "list name or ID")
            let selectedIDs = try Self.reminderListIDs(lists: lists.map { ($0.calendarIdentifier, $0.title) }, container: r.container, name: r.listName)
            guard let calendar = lists.first(where: { selectedIDs.contains($0.calendarIdentifier) }), calendar.allowsContentModifications else { throw AppleServiceError.forbidden }
            item = EKReminder(eventStore: store)
            item.calendar = calendar
            item.title = try r.required(r.title, "title")
        } else {
            guard let existing = store.calendarItem(withIdentifier: try r.required(r.id, "id")) as? EKReminder,
                  lists.contains(where: { $0.calendarIdentifier == existing.calendar.calendarIdentifier }) else { throw AppleServiceError.forbidden }
            item = existing
            if r.action == "read" { return AppleServiceResult(records: [reminderRecord(item)]) }
            guard item.calendar.allowsContentModifications else { throw AppleServiceError.forbidden }
            try AppleServiceValidation.checkRevision(r.revision, record: reminderRecord(item))
        }
        switch r.action {
        case "create", "update":
            if let title = r.title { item.title = try r.required(title, "title") }
            if let notes = r.body { item.notes = notes }
            if let due = r.due { item.dueDateComponents = due.isEmpty ? nil : try Self.dueComponents(due) }
            if let priority = r.priority {
                guard (0...9).contains(priority) else { throw AppleServiceError.invalid("priority must be 0...9.") }
                item.priority = priority
            }
            if let url = r.value {
                guard url.isEmpty || URL(string: url)?.scheme != nil else { throw AppleServiceError.invalid("URL must be absolute, or empty to clear.") }
                item.url = url.isEmpty ? nil : URL(string: url)
            }
            if let alarm = r.alarm {
                if alarm.isEmpty { item.alarms = [] }
                else {
                    guard let date = ISO8601DateFormatter().date(from: alarm) else { throw AppleServiceError.invalid("alarm must be an ISO date-time with timezone.") }
                    item.alarms = [EKAlarm(absoluteDate: date)]
                }
            }
            if let recurrence = r.recurrence {
                let frequencies: [String: EKRecurrenceFrequency] = ["daily": .daily, "weekly": .weekly, "monthly": .monthly, "yearly": .yearly]
                if recurrence.isEmpty { item.recurrenceRules = [] }
                else if let frequency = frequencies[recurrence] { item.recurrenceRules = [EKRecurrenceRule(recurrenceWith: frequency, interval: 1, end: nil)] }
                else { throw AppleServiceError.invalid("recurrence must be daily, weekly, monthly, yearly, or empty to clear.") }
            }
        case "complete": item.isCompleted = true
        case "reopen": item.isCompleted = false
        case "delete":
            try fence.check()
            try store.remove(item, commit: true)
            return AppleServiceResult(status: "applied", message: "Reminder deleted.")
        default: throw AppleServiceError.invalid("Unknown Reminders action.")
        }
        try fence.check()
        try store.save(item, commit: true)
        let saved = store.calendarItem(withIdentifier: item.calendarItemIdentifier) as? EKReminder ?? item
        return AppleServiceResult(status: "applied", records: [reminderRecord(saved)])
    }

    static func dueComponents(_ raw: String) throws -> DateComponents {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        if raw.count == 10 {
            let parts = raw.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { throw AppleServiceError.invalid("due must be YYYY-MM-DD or ISO date-time with timezone.") }
            var components = DateComponents(year: parts[0], month: parts[1], day: parts[2])
            guard let date = calendar.date(from: components), calendar.dateComponents([.year, .month, .day], from: date) == components else { throw AppleServiceError.invalid("Invalid due date.") }
            components.calendar = calendar
            return components
        }
        guard let date = ISO8601DateFormatter().date(from: raw) else { throw AppleServiceError.invalid("Timed due dates need an ISO date-time with timezone.") }
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
        components.calendar = calendar
        components.timeZone = calendar.timeZone
        return components
    }

    static func reminderMatchesSearch(
        title: String?,
        notes: String?,
        isCompleted: Bool,
        due: DateComponents?,
        request: AppleServiceRequest,
        now: Date = Date(),
        calendar: Calendar = .current
    ) -> Bool {
        let text = (title ?? "") + " " + (notes ?? "")
        let queryMatches = request.query == nil || text.localizedStandardContains(request.query!)
        guard queryMatches else { return false }

        switch reminderSearchState(request.value) {
        case "completed":
            return isCompleted
        case "all":
            return true
        case "overdue":
            let cutoff = due?.hour == nil ? calendar.startOfDay(for: now) : now
            return !isCompleted && (due?.date.map { $0 < cutoff } ?? false)
        case "today":
            return !isCompleted && (due?.date.map { calendar.isDate($0, inSameDayAs: now) } ?? false)
        case "upcoming":
            return !isCompleted && (due?.date.map { $0 >= calendar.startOfDay(for: now) } ?? false)
        default:
            return !isCompleted
        }
    }

    static func reminderSearchState(_ value: String?) -> String {
        switch value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "completed": "completed"
        case "all": "all"
        case "overdue": "overdue"
        case "today": "today"
        case "upcoming": "upcoming"
        default: "incomplete"
        }
    }

    static func reminderListIDs(lists: [(id: String, name: String)], container: String?, name: String?) throws -> Set<String> {
        let container = container?.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasID = container?.isEmpty == false
        let hasName = name?.isEmpty == false
        guard hasID || hasName else { return Set(lists.map(\.id)) }
        // Resolve IDs first; only fall back to names within the caller's allowed lists.
        let containerIsID = hasID && lists.contains { $0.id == container }
        let matches = lists.filter {
            (!hasID || (containerIsID ? $0.id == container : $0.name == container))
                && (!hasName || $0.name == name)
        }
        guard !matches.isEmpty else { throw AppleServiceError.forbidden }
        guard matches.count == 1 else {
            throw AppleServiceError.invalid("Multiple allowed lists have that name. Use ListReminderLists, then pass the chosen list ID as listName.")
        }
        return Set(matches.map(\.id))
    }

    static func reminderDueRange(from: String?, through: String?) throws -> (start: Date?, end: Date?) {
        func date(_ value: String?) throws -> Date? {
            guard let value else { return nil }
            guard value.count == 10, let date = try dueComponents(value).date else {
                throw AppleServiceError.invalid("Search date bounds must be YYYY-MM-DD.")
            }
            return date
        }
        let start = try date(from)
        let lastDay = try date(through)
        if let start, let lastDay, start > lastDay {
            throw AppleServiceError.invalid("dueFrom must be on or before dueThrough.")
        }
        let end = lastDay.flatMap { Calendar.current.date(byAdding: .day, value: 1, to: $0) }
        return (start, end)
    }

    private func reminderRecord(_ item: EKReminder) -> AppleServiceRecord {
        var fields = ["notes": item.notes ?? "", "completed": String(item.isCompleted), "priority": String(item.priority), "url": item.url?.absoluteString ?? "", "list": item.calendar.title]
        if let due = item.dueDateComponents {
            if due.hour == nil { fields["due"] = String(format: "%04d-%02d-%02d", due.year ?? 0, due.month ?? 0, due.day ?? 0) }
            else { fields["due"] = due.date.map { ISO8601DateFormatter().string(from: $0) }; fields["timezone"] = due.timeZone?.identifier }
        }
        fields["modified"] = item.lastModifiedDate.map { ISO8601DateFormatter().string(from: $0) }
        fields["recurrence"] = (item.recurrenceRules ?? []).map { String(describing: $0) }.joined(separator: "\n")
        fields["alarms"] = (item.alarms ?? []).map { $0.absoluteDate.map { ISO8601DateFormatter().string(from: $0) } ?? "relative:\($0.relativeOffset)" }.joined(separator: ",")
        return AppleServiceRecord(id: item.calendarItemIdentifier, title: item.title ?? "", container: item.calendar.calendarIdentifier, fields: fields)
    }

    private func contacts(_ r: AppleServiceRequest, grant: AppleServiceGrant, fence: AppleServiceFence) throws -> AppleServiceResult {
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else { throw AppleServiceError.needsSetup("Connect Contacts in Settings → Apple Services.") }
        if contactStore == nil { contactStore = CNContactStore() }
        let store = contactStore!
        let containers = try store.containers(matching: nil).filter { grant.permits($0.identifier) }
        if r.action == "containers" {
            return .page(containers.map { AppleServiceRecord(id: $0.identifier, title: $0.name, container: $0.identifier) }, request: r)
        }
        let keys: [CNKeyDescriptor] = [CNContactIdentifierKey, CNContactGivenNameKey, CNContactFamilyNameKey, CNContactOrganizationNameKey, CNContactEmailAddressesKey, CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        var found: [(CNContact, String)] = []
        for container in containers where r.container == nil || r.container == container.identifier {
            try fence.check()
            let fetch = CNContactFetchRequest(keysToFetch: keys)
            fetch.unifyResults = false // Never merge data from an excluded linked account.
            fetch.predicate = CNContact.predicateForContactsInContainer(withIdentifier: container.identifier)
            try store.enumerateContacts(with: fetch) { contact, stop in
                found.append((contact, container.identifier))
                if found.count > 10_000 { stop.pointee = true }
            }
            guard found.count <= 10_000 else { throw AppleServiceError.invalid("Contact search exceeds budget. Select fewer accounts.") }
        }
        if ["search", "resolve"].contains(r.action) {
            let records = found.map { contactRecord($0.0, container: $0.1) }.filter { record in
                r.query == nil || ([record.title] + Array(record.fields.values)).joined(separator: " ").localizedStandardContains(r.query!)
            }.sorted { $0.id < $1.id }
            return .page(records, request: r)
        }
        let contact: CNMutableContact
        let containerID: String
        if r.action == "create" {
            containerID = try r.required(r.container, "container")
            guard containers.contains(where: { $0.identifier == containerID }) else { throw AppleServiceError.forbidden }
            contact = CNMutableContact()
            contact.givenName = try r.required(r.title, "title (given name)")
        } else {
            guard let item = found.first(where: { $0.0.identifier == r.id }) else { throw AppleServiceError.forbidden }
            if r.action == "read" { return AppleServiceResult(records: [contactRecord(item.0, container: item.1)]) }
            guard r.action == "update" else { throw AppleServiceError.invalid("Unknown Contacts action.") }
            try AppleServiceValidation.checkRevision(r.revision, record: contactRecord(item.0, container: item.1))
            contact = item.0.mutableCopy() as! CNMutableContact
            containerID = item.1
        }
        if let title = r.title { contact.givenName = title }
        if let family = r.familyName { contact.familyName = family }
        if let organization = r.body { contact.organizationName = organization }
        // Add endpoints without overwriting existing multivalued fields or their labels.
        if let email = r.email {
            let endpoint = try AppleServiceValidation.endpoint(email)
            guard endpoint.contains("@") else { throw AppleServiceError.invalid("email must be an email address.") }
            if !contact.emailAddresses.contains(where: { ($0.value as String) == endpoint }) { contact.emailAddresses.append(CNLabeledValue(label: CNLabelOther, value: endpoint as NSString)) }
        }
        if let phone = r.phone {
            let number = try AppleServiceValidation.phone(phone)
            if !contact.phoneNumbers.contains(where: { $0.value.stringValue == number }) { contact.phoneNumbers.append(CNLabeledValue(label: CNLabelPhoneNumberMain, value: CNPhoneNumber(stringValue: number))) }
        }
        let save = CNSaveRequest()
        if r.action == "create" { save.add(contact, toContainerWithIdentifier: containerID) }
        else { save.update(contact) }
        try fence.check()
        try store.execute(save)
        return AppleServiceResult(status: "applied", records: [contactRecord(contact, container: containerID)])
    }

    private func contactRecord(_ contact: CNContact, container: String) -> AppleServiceRecord {
        let fields = ["given_name": contact.givenName, "family_name": contact.familyName, "organization": contact.organizationName,
                      "emails": contact.emailAddresses.map { "\(CNLabeledValue<NSString>.localizedString(forLabel: $0.label ?? CNLabelOther)): \($0.value)" }.joined(separator: "\n"),
                      "phones": contact.phoneNumbers.map { "\(CNLabeledValue<CNPhoneNumber>.localizedString(forLabel: $0.label ?? CNLabelOther)): \($0.value.stringValue)" }.joined(separator: "\n")]
        return AppleServiceRecord(id: contact.identifier, title: [contact.givenName, contact.familyName].filter { !$0.isEmpty }.joined(separator: " "), container: container, fields: fields)
    }
}

nonisolated private final class ReminderFetchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reminders: [EKReminder] = []
    func set(_ items: [EKReminder]) { lock.lock(); reminders = items; lock.unlock() }
    func take() -> [EKReminder] { lock.lock(); defer { lock.unlock() }; return reminders }
}
