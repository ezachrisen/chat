import Combine
import CoreLocation
import EventKit
import Foundation

nonisolated enum CalendarLimits {
    static let notesCharacterLimit = 250
    static let maxEvents = 200
    static let maxRange: TimeInterval = 367 * 24 * 60 * 60
}

nonisolated struct CalendarAccessPolicy: Sendable, Equatable {
    var allowsAll: Bool
    var allowedIDs: Set<String>

    static let all = CalendarAccessPolicy(allowsAll: true, allowedIDs: [])
    static let none = CalendarAccessPolicy(allowsAll: false, allowedIDs: [])

    func permits(_ calendarID: String) -> Bool {
        allowsAll || allowedIDs.contains(calendarID)
    }
}

nonisolated struct CalendarInfo: Identifiable, Sendable, Equatable {
    var id: String { calendarIdentifier }
    let calendarIdentifier: String
    let title: String
    let sourceTitle: String
    let typeName: String
    let colorRed: Double
    let colorGreen: Double
    let colorBlue: Double

    var subtitle: String {
        [sourceTitle, typeName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

nonisolated enum CalendarAccessError: LocalizedError {
    case denied
    case restricted
    case writeOnly
    case invalidStart(String)
    case invalidEnd(String)
    case endBeforeStart
    case rangeTooLarge
    case noCalendarsAllowed
    case unknownOrForbiddenIDs([String])

    var errorDescription: String? {
        switch self {
        case .denied:
            return "Calendar access is turned off for Chat. Enable it in System Settings → Privacy & Security → Calendars."
        case .restricted:
            return "Calendar access is restricted on this Mac."
        case .writeOnly:
            return "Chat has write-only Calendar access and cannot read events. Grant full access in System Settings → Privacy & Security → Calendars."
        case .invalidStart(let value):
            return "Could not parse start “\(value)”. Use an ISO 8601 date or date-time such as 2026-08-01 or 2026-08-01T09:00:00."
        case .invalidEnd(let value):
            return "Could not parse end “\(value)”. Use an ISO 8601 date or date-time such as 2026-08-31 or 2026-08-31T17:00:00."
        case .endBeforeStart:
            return "end must be after start."
        case .rangeTooLarge:
            return "The date range must be 366 days or less. Split the query into smaller ranges."
        case .noCalendarsAllowed:
            return "This agent is not allowed to read any calendars. The user must allow All or pick individual calendars in the agent editor."
        case .unknownOrForbiddenIDs(let ids):
            return "None of the requested calendar_ids can be read: \(ids.joined(separator: ", ")). Use calendar IDs from the allowed calendars list, not calendar names."
        }
    }
}

@MainActor
final class CalendarDirectory: ObservableObject {
    static let shared = CalendarDirectory()

    @Published private(set) var calendars: [CalendarInfo] = []
    @Published private(set) var authorizationStatus: EKAuthorizationStatus
    @Published private(set) var isRequestingAccess = false

    private let store = EKEventStore()
    private var cancellables: Set<AnyCancellable> = []

    var hasFullAccess: Bool {
        switch authorizationStatus {
        case .fullAccess:
            return true
        case .authorized:
            return true
        default:
            return false
        }
    }

    var canRequestAccess: Bool {
        switch authorizationStatus {
        case .notDetermined, .writeOnly:
            return true
        default:
            return false
        }
    }

    var accessMessage: String? {
        switch authorizationStatus {
        case .fullAccess, .authorized:
            return nil
        case .notDetermined:
            return "Chat will ask for Calendar access so this agent can read events."
        case .denied:
            return "Calendar access is off. Enable it in System Settings → Privacy & Security → Calendars."
        case .restricted:
            return "Calendar access is restricted on this Mac."
        case .writeOnly:
            return "Chat can create events but cannot read them. Grant full Calendar access in System Settings."
        @unknown default:
            return "Calendar access is unavailable."
        }
    }

    private init() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: store)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.reloadCalendarsIfAuthorized()
            }
            .store(in: &cancellables)
    }

    func prepare() async {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        if hasFullAccess {
            reloadCalendarsIfAuthorized()
            return
        }
        await requestAccess()
    }

    func readEvents(
        start: String,
        end: String,
        calendarIDsRaw: String?,
        policy: CalendarAccessPolicy
    ) async throws -> String {
        try await ensureFullAccess()

        let startDate = try CalendarDateParser.parse(start, role: .start)
        let endDate = try CalendarDateParser.parse(end, role: .end)
        guard endDate > startDate else {
            throw CalendarAccessError.endBeforeStart
        }
        guard endDate.timeIntervalSince(startDate) <= CalendarLimits.maxRange else {
            throw CalendarAccessError.rangeTooLarge
        }

        let available = loadCalendarInfos()
        let allowed = available.filter { policy.permits($0.calendarIdentifier) }
        guard !allowed.isEmpty else {
            throw CalendarAccessError.noCalendarsAllowed
        }

        let requestedIDs = CalendarDateParser.parseCalendarIDs(calendarIDsRaw)
        let allowedByID = Dictionary(uniqueKeysWithValues: allowed.map { ($0.calendarIdentifier, $0) })
        let queried: [CalendarInfo]
        var skippedIDs: [String] = []

        if requestedIDs.isEmpty {
            queried = allowed
        } else {
            var selected: [CalendarInfo] = []
            var seen = Set<String>()
            selected.reserveCapacity(requestedIDs.count)
            for id in requestedIDs {
                if !seen.insert(id).inserted { continue }
                if let calendar = allowedByID[id] {
                    selected.append(calendar)
                } else {
                    skippedIDs.append(id)
                }
            }
            queried = selected
        }

        guard !queried.isEmpty else {
            throw CalendarAccessError.unknownOrForbiddenIDs(skippedIDs)
        }

        let ekCalendars = queried.compactMap { store.calendar(withIdentifier: $0.calendarIdentifier) }
        guard !ekCalendars.isEmpty else {
            throw CalendarAccessError.unknownOrForbiddenIDs(queried.map(\.calendarIdentifier))
        }

        let predicate = store.predicateForEvents(
            withStart: startDate,
            end: endDate,
            calendars: ekCalendars
        )
        let ekEvents = store.events(matching: predicate)
            .sorted { lhs, rhs in
                if lhs.startDate != rhs.startDate {
                    return lhs.startDate < rhs.startDate
                }
                return (lhs.title ?? "").localizedStandardCompare(rhs.title ?? "") == .orderedAscending
            }

        let truncated = ekEvents.count > CalendarLimits.maxEvents
        let slice = truncated ? Array(ekEvents.prefix(CalendarLimits.maxEvents)) : ekEvents
        let records = slice.map { eventRecord(from: $0) }

        return CalendarEventsMarkdown.render(
            start: startDate,
            end: endDate,
            allowed: allowed,
            queried: queried,
            skippedIDs: skippedIDs,
            events: records,
            totalEventCount: ekEvents.count,
            truncated: truncated
        )
    }

    private func requestAccess() async {
        isRequestingAccess = true
        defer { isRequestingAccess = false }

        do {
            let granted = try await store.requestFullAccessToEvents()
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            if granted || hasFullAccess {
                reloadCalendarsIfAuthorized()
            } else {
                calendars = []
            }
        } catch {
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            calendars = []
        }
    }

    private func ensureFullAccess() async throws {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        if hasFullAccess {
            return
        }
        switch authorizationStatus {
        case .denied:
            throw CalendarAccessError.denied
        case .restricted:
            throw CalendarAccessError.restricted
        case .writeOnly:
            await requestAccess()
            if !hasFullAccess {
                throw CalendarAccessError.writeOnly
            }
        case .notDetermined:
            await requestAccess()
            if !hasFullAccess {
                throw CalendarAccessError.denied
            }
        default:
            await requestAccess()
            if !hasFullAccess {
                throw CalendarAccessError.denied
            }
        }
    }

    private func reloadCalendarsIfAuthorized() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        guard hasFullAccess else {
            calendars = []
            return
        }
        calendars = loadCalendarInfos()
    }

    private func loadCalendarInfos() -> [CalendarInfo] {
        store.calendars(for: .event)
            .map(Self.info(from:))
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func info(from calendar: EKCalendar) -> CalendarInfo {
        let rgb = rgbComponents(calendar.cgColor)
        return CalendarInfo(
            calendarIdentifier: calendar.calendarIdentifier,
            title: calendar.title,
            sourceTitle: calendar.source?.title ?? "",
            typeName: typeName(calendar.type),
            colorRed: rgb.0,
            colorGreen: rgb.1,
            colorBlue: rgb.2
        )
    }

    private static func rgbComponents(_ color: CGColor?) -> (Double, Double, Double) {
        guard
            let color,
            let converted = color.converted(
                to: CGColorSpaceCreateDeviceRGB(),
                intent: .defaultIntent,
                options: nil
            ),
            let components = converted.components,
            components.count >= 3
        else {
            return (0.55, 0.55, 0.55)
        }
        return (Double(components[0]), Double(components[1]), Double(components[2]))
    }

    private static func typeName(_ type: EKCalendarType) -> String {
        switch type {
        case .local:
            return "Local"
        case .calDAV:
            return "CalDAV"
        case .exchange:
            return "Exchange"
        case .subscription:
            return "Subscription"
        case .birthday:
            return "Birthday"
        @unknown default:
            return "Other"
        }
    }

    private func eventRecord(from event: EKEvent) -> CalendarEventRecord {
        let timeZone = event.timeZone ?? TimeZone.current
        let notes = CalendarEventsMarkdown.truncatedNotes(event.notes)
        let structured = event.structuredLocation
        let geo = structured?.geoLocation?.coordinate
        return CalendarEventRecord(
            eventID: event.eventIdentifier ?? event.calendarItemIdentifier,
            calendarItemID: event.calendarItemIdentifier,
            externalID: event.calendarItemExternalIdentifier,
            calendarID: event.calendar?.calendarIdentifier ?? "",
            calendarTitle: event.calendar?.title ?? "",
            title: oneLine(event.title) ?? "(No title)",
            start: event.startDate,
            end: event.endDate,
            isAllDay: event.isAllDay,
            timeZoneID: event.isAllDay ? nil : timeZone.identifier,
            location: oneLine(event.location) ?? oneLine(structured?.title),
            latitude: geo.map(\.latitude),
            longitude: geo.map(\.longitude),
            url: event.url?.absoluteString,
            status: statusName(event.status),
            availability: availabilityName(event.availability),
            organizer: participantLine(event.organizer),
            attendees: (event.attendees ?? []).prefix(40).compactMap(participantLine),
            attendeeCount: event.attendees?.count ?? 0,
            alarms: (event.alarms ?? []).compactMap(alarmLine),
            recurrence: (event.recurrenceRules ?? []).map(Self.recurrenceLine),
            isDetached: event.isDetached,
            occurrenceDate: event.hasRecurrenceRules || event.isDetached ? event.occurrenceDate : nil,
            createdAt: event.creationDate,
            lastModifiedAt: event.lastModifiedDate,
            birthdayContactID: event.birthdayContactIdentifier,
            notes: notes?.text,
            notesTruncated: notes?.truncated ?? false
        )
    }

    private func statusName(_ status: EKEventStatus) -> String? {
        switch status {
        case .none:
            return nil
        case .confirmed:
            return "confirmed"
        case .tentative:
            return "tentative"
        case .canceled:
            return "canceled"
        @unknown default:
            return "unknown"
        }
    }

    private func availabilityName(_ availability: EKEventAvailability) -> String? {
        switch availability {
        case .notSupported:
            return nil
        case .busy:
            return "busy"
        case .free:
            return "free"
        case .tentative:
            return "tentative"
        case .unavailable:
            return "unavailable"
        @unknown default:
            return nil
        }
    }

    private func participantLine(_ participant: EKParticipant?) -> String? {
        guard let participant else { return nil }
        var parts: [String] = []
        if let name = oneLine(participant.name) {
            parts.append(name)
        }
        if let email = email(from: participant.url) {
            parts.append("<\(email)>")
        }
        if participant.isCurrentUser {
            parts.append("(you)")
        }
        if let status = participantStatusName(participant.participantStatus), status != "accepted" {
            parts.append(status)
        }
        if let role = participantRoleName(participant.participantRole), role != "required" {
            parts.append(role)
        }
        if let type = participantTypeName(participant.participantType) {
            parts.append(type)
        }
        let line = parts.joined(separator: " ")
        return line.isEmpty ? nil : line
    }

    private func email(from url: URL?) -> String? {
        guard let url else { return nil }
        if url.scheme?.lowercased() == "mailto" {
            let address = url.absoluteString.dropFirst("mailto:".count)
            let trimmed = String(address).trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let value = url.absoluteString.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private func participantRoleName(_ role: EKParticipantRole) -> String? {
        switch role {
        case .unknown:
            return nil
        case .required:
            return "required"
        case .optional:
            return "optional"
        case .chair:
            return "chair"
        case .nonParticipant:
            return "non-participant"
        @unknown default:
            return nil
        }
    }

    private func participantStatusName(_ status: EKParticipantStatus) -> String? {
        switch status {
        case .unknown:
            return nil
        case .pending:
            return "pending"
        case .accepted:
            return "accepted"
        case .declined:
            return "declined"
        case .tentative:
            return "tentative"
        case .delegated:
            return "delegated"
        case .completed:
            return "completed"
        case .inProcess:
            return "in-process"
        @unknown default:
            return nil
        }
    }

    private func participantTypeName(_ type: EKParticipantType) -> String? {
        switch type {
        case .unknown:
            return nil
        case .person:
            return nil
        case .room:
            return "room"
        case .resource:
            return "resource"
        case .group:
            return "group"
        @unknown default:
            return nil
        }
    }

    private func alarmLine(_ alarm: EKAlarm) -> String? {
        if let absolute = alarm.absoluteDate {
            return CalendarEventsMarkdown.isoString(absolute, timeZone: TimeZone.current)
        }
        let offset = alarm.relativeOffset
        if offset == 0 {
            return "at start"
        }
        return CalendarEventsMarkdown.offsetLabel(offset)
    }

    private static func recurrenceLine(_ rule: EKRecurrenceRule) -> String {
        var parts: [String] = [frequencyName(rule.frequency)]
        if rule.interval > 1 {
            parts.append("interval \(rule.interval)")
        }
        if let days = rule.daysOfTheWeek, !days.isEmpty {
            parts.append("days \(days.map(dayName).joined(separator: ","))")
        }
        if let days = rule.daysOfTheMonth, !days.isEmpty {
            parts.append("month_days \(days.map(\.stringValue).joined(separator: ","))")
        }
        if let months = rule.monthsOfTheYear, !months.isEmpty {
            parts.append("months \(months.map(\.stringValue).joined(separator: ","))")
        }
        if let weeks = rule.weeksOfTheYear, !weeks.isEmpty {
            parts.append("weeks \(weeks.map(\.stringValue).joined(separator: ","))")
        }
        if let days = rule.daysOfTheYear, !days.isEmpty {
            parts.append("year_days \(days.map(\.stringValue).joined(separator: ","))")
        }
        if let positions = rule.setPositions, !positions.isEmpty {
            parts.append("positions \(positions.map(\.stringValue).joined(separator: ","))")
        }
        if let end = rule.recurrenceEnd {
            if let date = end.endDate {
                parts.append("until \(CalendarEventsMarkdown.displayDateTime(date, timeZone: TimeZone.current))")
            } else if end.occurrenceCount > 0 {
                parts.append("count \(end.occurrenceCount)")
            }
        }
        return parts.joined(separator: "; ")
    }

    private static func frequencyName(_ frequency: EKRecurrenceFrequency) -> String {
        switch frequency {
        case .daily:
            return "daily"
        case .weekly:
            return "weekly"
        case .monthly:
            return "monthly"
        case .yearly:
            return "yearly"
        @unknown default:
            return "unknown"
        }
    }

    private static func dayName(_ day: EKRecurrenceDayOfWeek) -> String {
        let names = ["sun", "mon", "tue", "wed", "thu", "fri", "sat"]
        let index = day.dayOfTheWeek.rawValue - 1
        let base = (index >= 0 && index < names.count) ? names[index] : "day\(day.dayOfTheWeek.rawValue)"
        if day.weekNumber != 0 {
            return "\(base)#\(day.weekNumber)"
        }
        return base
    }

    private func oneLine(_ value: String?) -> String? {
        guard let value else { return nil }
        let collapsed = value
            .split(whereSeparator: \.isNewline)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return collapsed.isEmpty ? nil : collapsed
    }
}

nonisolated struct CalendarEventRecord: Sendable {
    var eventID: String
    var calendarItemID: String
    var externalID: String?
    var calendarID: String
    var calendarTitle: String
    var title: String
    var start: Date
    var end: Date
    var isAllDay: Bool
    var timeZoneID: String?
    var location: String?
    var latitude: Double?
    var longitude: Double?
    var url: String?
    var status: String?
    var availability: String?
    var organizer: String?
    var attendees: [String]
    var attendeeCount: Int
    var alarms: [String]
    var recurrence: [String]
    var isDetached: Bool
    var occurrenceDate: Date?
    var createdAt: Date?
    var lastModifiedAt: Date?
    var birthdayContactID: String?
    var notes: String?
    var notesTruncated: Bool
}

nonisolated enum CalendarDateParser {
    enum Role {
        case start
        case end
    }

    static func parse(_ raw: String, role: Role) throws -> Date {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw role == .start
                ? CalendarAccessError.invalidStart(raw)
                : CalendarAccessError.invalidEnd(raw)
        }

        let normalized = trimmed.replacingOccurrences(of: " ", with: "T")
        if isDateOnly(normalized) {
            return try parseDateOnly(normalized, role: role)
        }
        if let date = parseDateTime(normalized) {
            return date
        }
        throw role == .start
            ? CalendarAccessError.invalidStart(raw)
            : CalendarAccessError.invalidEnd(raw)
    }

    static func parseCalendarIDs(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private static func isDateOnly(_ value: String) -> Bool {
        value.count == 10
            && value.utf8.allSatisfy { $0 == 45 || ($0 >= 48 && $0 <= 57) }
            && value[value.index(value.startIndex, offsetBy: 4)] == "-"
            && value[value.index(value.startIndex, offsetBy: 7)] == "-"
    }

    private static func parseDateOnly(_ value: String, role: Role) throws -> Date {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd"
        guard let day = formatter.date(from: value) else {
            throw role == .start
                ? CalendarAccessError.invalidStart(value)
                : CalendarAccessError.invalidEnd(value)
        }
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        if role == .start {
            return start
        }
        guard let next = calendar.date(byAdding: .day, value: 1, to: start) else {
            throw CalendarAccessError.invalidEnd(value)
        }
        return next
    }

    private static func parseDateTime(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: value) {
            return date
        }

        let internet = ISO8601DateFormatter()
        internet.formatOptions = [.withInternetDateTime]
        if let date = internet.date(from: value) {
            return date
        }

        let local = ISO8601DateFormatter()
        local.timeZone = TimeZone.current
        local.formatOptions = [
            .withFullDate,
            .withTime,
            .withDashSeparatorInDate,
            .withColonSeparatorInTime
        ]
        return local.date(from: value)
    }
}

nonisolated enum CalendarEventsMarkdown {
    static func truncatedNotes(_ notes: String?) -> (text: String, truncated: Bool)? {
        guard let notes else { return nil }
        let trimmed = notes.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.count > CalendarLimits.notesCharacterLimit {
            return (String(trimmed.prefix(CalendarLimits.notesCharacterLimit)), true)
        }
        return (trimmed, false)
    }

    static func isoString(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = timeZone
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }

    static func offsetLabel(_ offset: TimeInterval) -> String {
        let seconds = Int(offset.rounded())
        let absolute = abs(seconds)
        let side = seconds <= 0 ? "before" : "after"
        if absolute == 0 {
            return "at start"
        }
        if absolute % 86400 == 0 {
            return "\(absolute / 86400)d \(side)"
        }
        if absolute % 3600 == 0 {
            return "\(absolute / 3600)h \(side)"
        }
        if absolute % 60 == 0 {
            return "\(absolute / 60)m \(side)"
        }
        return "\(absolute)s \(side)"
    }

    static func render(
        start: Date,
        end: Date,
        allowed: [CalendarInfo],
        queried: [CalendarInfo],
        skippedIDs: [String],
        events: [CalendarEventRecord],
        totalEventCount: Int,
        truncated: Bool
    ) -> String {
        let local = TimeZone.current
        let now = Date()
        var lines: [String] = []
        lines.append("Calendar events")
        lines.append("range_start: \(isoString(start, timeZone: local))")
        lines.append("range_end: \(isoString(end, timeZone: local))")
        lines.append("timezone: \(timezoneDescription(local, at: now))")
        lines.append("as_of: \(displayDateTime(now, timeZone: local))")
        lines.append("times_note: Timed event start and end are already converted to this timezone. All-day events are calendar dates with no time of day.")
        appendCalendarDirectory(allowed: allowed, queried: queried, skippedIDs: skippedIDs, to: &lines)
        if truncated {
            lines.append("event_count: \(totalEventCount)")
            lines.append("showing: \(events.count)")
            lines.append("truncated: true")
            lines.append("truncated_note: Narrow start and end to see the remaining events.")
        } else {
            lines.append("event_count: \(events.count)")
        }
        if events.isEmpty {
            lines.append("")
            lines.append("No events in this range.")
            return lines.joined(separator: "\n")
        }

        for event in events {
            lines.append("")
            lines.append("event: \(event.title)")
            append("calendar", event.calendarTitle, to: &lines)
            if event.isAllDay {
                lines.append("start: \(allDayDisplay(event.start, timeZoneID: event.timeZoneID))")
                lines.append("end: \(allDayEndDisplay(event.start, event.end, timeZoneID: event.timeZoneID))")
                lines.append("all_day: true")
            } else {
                lines.append("start: \(displayDateTime(event.start, timeZone: local))")
                lines.append("end: \(displayDateTime(event.end, timeZone: local))")
            }
            append("location", event.location, to: &lines)
            append("url", event.url, to: &lines)
            if let status = event.status, status != "confirmed" {
                lines.append("status: \(status)")
            }
            if let availability = event.availability, availability != "busy" {
                lines.append("availability: \(availability)")
            }
            append("organizer", event.organizer, to: &lines)
            if !event.attendees.isEmpty {
                lines.append("attendees: \(event.attendees.joined(separator: "; "))")
                if event.attendeeCount > event.attendees.count {
                    lines.append("attendee_count: \(event.attendeeCount)")
                    lines.append("attendees_truncated: true")
                }
            }
            if !event.recurrence.isEmpty {
                lines.append("recurrence: \(event.recurrence.joined(separator: " | "))")
            }
            if let notes = event.notes {
                let collapsed = notes
                    .split(whereSeparator: \.isNewline)
                    .joined(separator: " ")
                lines.append("notes: \(collapsed)")
                if event.notesTruncated {
                    lines.append("notes_truncated: true")
                }
            }
        }

        return lines.joined(separator: "\n")
    }

    static func displayDateTime(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEE MMMM d yyyy jm zzz")
        return formatter.string(from: date)
    }

    static func timezoneDescription(_ timeZone: TimeZone, at date: Date) -> String {
        let identifier = timeZone.identifier
        let abbreviation = timeZone.abbreviation(for: date) ?? identifier
        let seconds = timeZone.secondsFromGMT(for: date)
        let sign = seconds >= 0 ? "+" : "-"
        let absolute = abs(seconds)
        let hours = absolute / 3600
        let minutes = (absolute % 3600) / 60
        let utc = minutes == 0
            ? "UTC\(sign)\(hours)"
            : String(format: "UTC%@%d:%02d", sign, hours, minutes)
        if abbreviation == identifier {
            return "\(identifier) (\(utc))"
        }
        return "\(identifier) (\(abbreviation), \(utc))"
    }

    private static func appendCalendarDirectory(
        allowed: [CalendarInfo],
        queried: [CalendarInfo],
        skippedIDs: [String],
        to lines: inout [String]
    ) {
        let allowedIDs = Set(allowed.map(\.calendarIdentifier))
        let queriedIDs = Set(queried.map(\.calendarIdentifier))
        let sameSet = allowedIDs == queriedIDs
        if sameSet {
            lines.append("calendars:")
            for calendar in queried {
                lines.append("- \(calendar.title) [id: \(calendar.calendarIdentifier)]")
            }
        } else {
            lines.append("allowed_calendars:")
            for calendar in allowed {
                lines.append("- \(calendar.title) [id: \(calendar.calendarIdentifier)]")
            }
            lines.append("queried_calendars:")
            for calendar in queried {
                lines.append("- \(calendar.title) [id: \(calendar.calendarIdentifier)]")
            }
        }
        if !skippedIDs.isEmpty {
            lines.append("skipped_calendar_ids: \(skippedIDs.joined(separator: ", "))")
            lines.append("skipped_note: Use calendar IDs from the calendars list, not calendar names.")
        }
    }

    private static func append(_ key: String, _ value: String?, to lines: inout [String]) {
        guard let value else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        lines.append("\(key): \(trimmed)")
    }

    private static func allDayTimeZone(_ timeZoneID: String?) -> TimeZone {
        TimeZone(identifier: timeZoneID ?? "") ?? TimeZone.current
    }

    private static func allDayDisplay(_ date: Date, timeZoneID: String?) -> String {
        displayDate(date, timeZone: allDayTimeZone(timeZoneID))
    }

    private static func allDayEndDisplay(_ start: Date, _ end: Date, timeZoneID: String?) -> String {
        let timeZone = allDayTimeZone(timeZoneID)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let inclusive = calendar.date(byAdding: .second, value: -1, to: end) ?? end
        return displayDate(max(inclusive, start), timeZone: timeZone)
    }

    private static func displayDate(_ date: Date, timeZone: TimeZone) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale.current
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("EEEE MMMM d yyyy")
        return formatter.string(from: date)
    }
}
