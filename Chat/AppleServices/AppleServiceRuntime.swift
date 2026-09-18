import Foundation
import AppKit
import Combine
import EventKit
import Contacts
import Carbon

@MainActor
final class AppleServiceConnections: ObservableObject {
    static let shared = AppleServiceConnections()
    @Published private(set) var statuses: [AppleServiceID: String] = [:]
    @Published private(set) var connectedServices: Set<AppleServiceID> = []
    @Published private(set) var busy: Set<AppleServiceID> = []
    /// Services the user disconnected in Chat. macOS permission is separate and
    /// can only be removed in System Settings; this stops Chat from using it.
    @Published private(set) var revokedServices: Set<AppleServiceID>
    private static let revokedKey = "appleServicesRevoked"
    private let reminderStore = EKEventStore()
    private let contactStore = CNContactStore()

    init() {
        revokedServices = Set((UserDefaults.standard.stringArray(forKey: Self.revokedKey) ?? []).compactMap(AppleServiceID.init(rawValue:)))
    }

    func refresh() {
        var connected: Set<AppleServiceID> = []
        if EKEventStore.authorizationStatus(for: .reminder) == .fullAccess { connected.insert(.reminders) }
        if CNContactStore.authorizationStatus(for: .contacts) == .authorized { connected.insert(.contacts) }
        if NSWorkspace.shared.urlForApplication(toOpen: URL(string: "tel:+12025550100")!) != nil { connected.insert(.phone) }
        statuses[.reminders] = connected.contains(.reminders) ? "Ready" : "Not connected"
        statuses[.contacts] = connected.contains(.contacts) ? "Ready" : "Not connected"
        statuses[.phone] = connected.contains(.phone) ? "Ready for call handoff" : "Calling app unavailable"
        for service in [AppleServiceID.notes, .mail, .messages] {
            if (try? checkAutomation(service)) != nil { connected.insert(service) }
            statuses[service] = connected.contains(service) ? (service == .messages ? "Sending ready" : "Ready") : "Not connected"
        }
        for service in revokedServices {
            connected.remove(service)
            statuses[service] = "Access revoked in Chat"
        }
        connectedServices = connected
    }
    func revoke(_ service: AppleServiceID) {
        revokedServices.insert(service)
        saveRevoked()
        refresh()
    }
    /// Throws when the user has revoked the service in Chat.
    func checkNotRevoked(_ service: AppleServiceID) throws {
        guard !revokedServices.contains(service) else {
            throw AppleServiceError.needsSetup("\(service.title) access was revoked in Chat. Connect it again in \(service.settingsLocation).")
        }
    }
    private func saveRevoked() {
        UserDefaults.standard.set(revokedServices.map(\.rawValue).sorted(), forKey: Self.revokedKey)
    }
    func connect(_ service: AppleServiceID) async {
        revokedServices.remove(service)
        saveRevoked()
        busy.insert(service)
        defer { busy.remove(service) }
        do {
            switch service {
            case .reminders:
                guard try await reminderStore.requestFullAccessToReminders() else { throw AppleServiceError.needsSetup("Reminders access was denied.") }
            case .contacts:
                guard try await contactStore.requestAccess(for: .contacts) else { throw AppleServiceError.needsSetup("Contacts access was denied.") }
            case .phone: break
            default:
                try await launch(service)
                let bundleID = service.bundleID!
                let status = await Task.detached {
                    let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
                    return AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, true)
                }.value
                guard status == noErr else { throw AppleServiceError.needsSetup("Automation access was denied. Enable Chat in System Settings → Privacy & Security → Automation.") }
            }
            refresh()
        } catch {
            connectedServices.remove(service)
            statuses[service] = error.localizedDescription
        }
    }
    func ensure(_ service: AppleServiceID) async throws {
        if [.notes, .mail, .messages].contains(service) {
            try checkAutomation(service)
            try await launch(service)
        }
    }
    func checkAutomation(_ service: AppleServiceID) throws {
        guard let bundle = service.bundleID, NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) != nil else { throw AppleServiceError.unavailable("\(service.title) is not installed.") }
        let target = NSAppleEventDescriptor(bundleIdentifier: bundle)
        guard AEDeterminePermissionToAutomateTarget(target.aeDesc, typeWildCard, typeWildCard, false) == noErr else {
            throw AppleServiceError.needsSetup("Connect \(service.title) in \(service.settingsLocation).")
        }
    }
    private func launch(_ service: AppleServiceID) async throws {
        guard let bundleID = service.bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { throw AppleServiceError.unavailable("Application is not installed.") }
        if !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty { return }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }
}

nonisolated struct ApplePreparedAction: Codable, Identifiable, Sendable {
    var id: String
    var agentID: UUID
    var service: AppleServiceID
    var request: AppleServiceRequest
    var origin: AppleServiceOrigin
    var destinations: [String]
    var summary: String
    var state: String = "prepared"
    var createdAt = Date()
    var result: AppleServiceResult?
}

@MainActor
final class AppleActionStore: ObservableObject {
    static let shared = AppleActionStore()
    @Published private(set) var actions: [ApplePreparedAction] = []
    private let url: URL
    private var loadFailed = false
    init(url: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("com.zachrisen.chat/apple-actions.json")) {
        self.url = url
        if let data = try? Data(contentsOf: url), let saved = try? JSONDecoder().decode([ApplePreparedAction].self, from: data) {
            actions = saved.map { action in
                var action = action
                if action.state == "executing" { action.state = "uncertain" }
                return action
            }
        } else if FileManager.default.fileExists(atPath: url.path) {
            loadFailed = true
        }
    }
    func action(_ id: String, agentID: UUID) -> ApplePreparedAction? { actions.first { $0.id == id && $0.agentID == agentID } }
    func save(_ action: ApplePreparedAction) throws {
        guard !loadFailed else { throw AppleServiceError.unavailable("Action receipts could not be read. Restore the action store before making changes.") }
        var updated = actions.filter { $0.id != action.id || $0.agentID != action.agentID }
        updated.append(action)
        // Keep uncertain receipts until explicitly cleared; prune only old finished actions.
        updated.removeAll { ["applied", "submitted", "handed_off", "cancelled", "failed"].contains($0.state) && $0.createdAt < Date().addingTimeInterval(-30 * 86400) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(updated).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        actions = updated
    }
    func cancel(_ id: String, agentID: UUID) throws {
        guard var action = action(id, agentID: agentID), ["prepared", "authorized"].contains(action.state) else { return }
        action.state = "cancelled"
        action.request.body = nil
        try save(action)
    }
}

nonisolated struct AppleServiceContext: Sendable {
    var agentID: UUID
    var origin: AppleServiceOrigin
    var grant: @MainActor @Sendable (AppleServiceID) throws -> AppleServiceGrant
}

@MainActor
final class AppleServiceRuntime {
    static let shared = AppleServiceRuntime()
    typealias Backend = @MainActor @Sendable (AppleServiceID, AppleServiceRequest, AppleServiceGrant, AppleServiceFence) async throws -> AppleServiceResult
    private let actionStore: AppleActionStore
    private let backend: Backend?
    init(actionStore: AppleActionStore = .shared, backend: Backend? = nil) {
        self.actionStore = actionStore
        self.backend = backend
    }
    private var fences: [UUID: [(UUID, AppleServiceFence)]] = [:]
    /// Stops every in-flight service operation, e.g. after the user revokes a service.
    func revokeInFlight() {
        for fence in fences.values.flatMap({ $0.map(\.1) }) { fence.revoke() }
    }
    func revoke(agentID: UUID) {
        for (_, fence) in fences[agentID] ?? [] { fence.revoke() }
        for action in actionStore.actions where action.agentID == agentID && action.state == "prepared" {
            try? actionStore.cancel(action.id, agentID: agentID)
        }
    }

    func execute(_ service: AppleServiceID, _ request: AppleServiceRequest, context: AppleServiceContext, approved: Bool = false) async throws -> AppleServiceResult {
        try Task.checkCancellation()
        guard try JSONEncoder().encode(request).count <= 48_000,
              request.limit.map({ (1...100).contains($0) }) ?? true,
              request.offset.map({ (0...10_000).contains($0) }) ?? true,
              request.query.map({ $0.count <= 500 }) ?? true else { throw AppleServiceError.invalid("Request exceeds service limits.") }
        let grant = try context.grant(service)
        try authorize(request, service: service, grant: grant, origin: context.origin)
        guard service.actions.contains(request.action) else { throw AppleServiceError.invalid("Unknown service action.") }
        if request.action == "attachments" {
            return AppleServiceResult(records: AppleAttachmentStore.shared.list(agentID: context.agentID).map { item in
                AppleServiceRecord(id: item.id, title: item.name, container: "imported", fields: ["bytes": String(item.size), "expires": ISO8601DateFormatter().string(from: item.createdAt.addingTimeInterval(86400))])
            })
        }
        if request.isPreparedExecution {
            return try await commit(try request.required(request.actionID, "actionID"), service: service, context: context, approved: approved)
        }
        if request.isPreparation { return try await prepare(service, request, context: context, grant: grant) }
        if request.action == "show" { return try await run(service, request, context: context, grant: grant) }
        if !request.isRead {
            // Every mutation gets an app-owned receipt before touching the source application.
            // Caller-provided actionID is a retry key, never an authorization token.
            let key = try request.required(request.actionID, "actionID (a unique key for this change; reuse it only for retries)")
            guard key.count <= 200 else { throw AppleServiceError.invalid("actionID is too long.") }
            if let prior = actionStore.action(key, agentID: context.agentID) {
                guard prior.service == service, prior.request == request else { throw AppleServiceError.conflict }
                return receipt(prior)
            }
            var action = ApplePreparedAction(id: key, agentID: context.agentID, service: service, request: request, origin: context.origin, destinations: [], summary: "\(service.title): \(request.action)", state: "executing")
            try actionStore.save(action)
            do {
                let result = try await run(service, request, context: context, grant: grant)
                action.state = result.status
                action.result = result
                try actionStore.save(action)
                return result
            } catch {
                action.state = "uncertain"
                try? actionStore.save(action)
                throw error
            }
        }
        return try await run(service, request, context: context, grant: grant)
    }
    private func authorize(_ request: AppleServiceRequest, service: AppleServiceID, grant: AppleServiceGrant, origin: AppleServiceOrigin) throws {
        guard grant.enabled else { throw AppleServiceError.forbidden }
        if origin.isBackground && !grant.allowsBackground { throw AppleServiceError.forbidden }
        if origin.isDelegated && !grant.allowsDelegation { throw AppleServiceError.forbidden }
        if origin.isConsultation && !request.isRead { throw AppleServiceError.forbidden }
        if request.action == "show" && origin != .interactive { throw AppleServiceError.forbidden }
        if !request.isRead && request.action != "show" && !request.isPreparation && !request.isPreparedExecution && !grant.allowsChanges { throw AppleServiceError.forbidden }
        if request.action == "delete" && !grant.allowsDeletion { throw AppleServiceError.forbidden }
        if service == .messages && ["read", "search"].contains(request.action) && !grant.allowsHistory { throw AppleServiceError.forbidden }
    }
    private func run(_ service: AppleServiceID, _ request: AppleServiceRequest, context: AppleServiceContext, grant: AppleServiceGrant) async throws -> AppleServiceResult {
        let fence = AppleServiceFence()
        let identifier = UUID()
        fences[context.agentID, default: []].append((identifier, fence))
        defer { fences[context.agentID]?.removeAll { $0.0 == identifier } }
        return try await withTaskCancellationHandler {
            if backend == nil { try AppleServiceConnections.shared.checkNotRevoked(service) }
            let result: AppleServiceResult
            if let backend {
                result = try await backend(service, request, grant, fence)
            } else if [.reminders, .contacts].contains(service) {
                result = try await NativeAppleServices.shared.execute(service, request, grant: grant, fence: fence)
            } else if service == .messages && ["read", "search"].contains(request.action) {
                result = try await MessagesHistoryService.shared.execute(request, grant: grant, fence: fence)
            } else if service == .phone {
                let number = try AppleServiceValidation.phone(request.required(request.recipient, "recipient"))
                try fence.check()
                guard let url = URL(string: "tel:" + number), let app = NSWorkspace.shared.urlForApplication(toOpen: url) else { throw AppleServiceError.unavailable("No calling application is available.") }
                let configuration = NSWorkspace.OpenConfiguration()
                _ = try await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: configuration)
                result = AppleServiceResult(status: "handed_off", message: "Handed the number to \(app.deletingPathExtension().lastPathComponent). Connection is not confirmed.")
            } else {
                try await AppleServiceConnections.shared.ensure(service)
                guard try context.grant(service) == grant else { throw AppleServiceError.forbidden }
                try Task.checkCancellation()
                let attachmentURL: URL?
                if let id = request.attachmentID { attachmentURL = try AppleAttachmentStore.shared.resolve(id, agentID: context.agentID).1 }
                else { attachmentURL = nil }
                result = try await ScriptableAppleServices.shared.execute(service, request, grant: grant, fence: fence, attachmentURL: attachmentURL)
            }
            try Task.checkCancellation()
            guard try context.grant(service) == grant else { throw AppleServiceError.forbidden }
            return result
        } onCancel: { fence.revoke() }
    }
    private func prepare(_ service: AppleServiceID, _ request: AppleServiceRequest, context: AppleServiceContext, grant: AppleServiceGrant) async throws -> AppleServiceResult {
        var execution = request
        var destinations: [String]
        var summary: String
        if service == .phone {
            let number = try AppleServiceValidation.phone(request.required(request.recipient, "recipient"))
            execution.recipient = number
            execution.action = "call"
            destinations = [number]
            summary = "Call \(number)"
        } else if service == .messages {
            guard (request.id == nil) != (request.recipient == nil) else { throw AppleServiceError.invalid("Choose either a conversation id or a recipient, not both.") }
            if request.attachmentID == nil { _ = try request.required(request.body, "body") }
            let result = try await run(service, request, context: context, grant: grant)
            guard let chat = result.records.first else { throw AppleServiceError.forbidden }
            execution.revision = chat.revision
            if let recipient = request.recipient { execution.recipient = try AppleServiceValidation.endpoint(recipient) }
            execution.sender = chat.fields["account"] ?? request.sender
            execution.action = "send"
            destinations = execution.recipient.map { [$0] } ?? [chat.id]
            summary = "Message to \(chat.title)\n\(chat.fields["participants"] ?? "")\n\n\(request.body ?? "")"
        } else if service == .mail {
            let result = try await run(service, request, context: context, grant: grant)
            guard let draft = result.records.first else { throw AppleServiceError.forbidden }
            destinations = ["to", "cc", "bcc"].flatMap { draft.fields[$0, default: ""].split(separator: "\n").map(String.init) }
            destinations = try destinations.map { try AppleServiceValidation.mailAddress($0) }
            guard !destinations.isEmpty else { throw AppleServiceError.invalid("Draft has no recipients.") }
            execution.revision = draft.revision
            execution.action = "send"
            execution.sender = draft.fields["sender"]
            summary = "From: \(execution.sender ?? "")\nTo: \(draft.fields["to"] ?? "")\nCc: \(draft.fields["cc"] ?? "")\nBcc: \(draft.fields["bcc"] ?? "")\nSubject: \(draft.title)\n\n\(draft.fields["text"] ?? "")"
        } else { throw AppleServiceError.invalid("This service has no communication action.") }
        if let id = request.attachmentID {
            let attachment = try AppleAttachmentStore.shared.resolve(id, agentID: context.agentID).0
            summary += "\nAttachment: \(attachment.name) (\(attachment.size) bytes)"
        }
        let actionID = UUID().uuidString
        execution.actionID = actionID
        let action = ApplePreparedAction(id: actionID, agentID: context.agentID, service: service, request: execution, origin: context.origin, destinations: destinations, summary: summary)
        try actionStore.save(action)
        return AppleServiceResult(status: "prepared", message: summary + "\nSend/call using this actionID. Without a standing destination grant, review it in Settings → agent → Tools → Apple Services.", actionID: actionID)
    }
    private func commit(_ id: String, service: AppleServiceID, context: AppleServiceContext, approved: Bool) async throws -> AppleServiceResult {
        guard var action = actionStore.action(id, agentID: context.agentID), action.service == service else { throw AppleServiceError.forbidden }
        if action.state != "prepared" { return receipt(action) }
        guard action.createdAt > Date().addingTimeInterval(-3600) else { throw AppleServiceError.invalid("Prepared action expired. Prepare a fresh action.") }
        let grant = try context.grant(service)
        try authorize(action.request, service: service, grant: grant, origin: context.origin)
        guard approved || (action.origin == context.origin && action.destinations.allSatisfy { grant.sendDestinations.contains($0) }) else {
            return AppleServiceResult(status: "needs_approval", message: "Review this exact action in the agent's Tools settings, or configure a standing destination grant.", actionID: id)
        }
        action.state = "executing"
        try actionStore.save(action)
        do {
            let result = try await run(service, action.request, context: context, grant: grant)
            action.state = result.status
            action.result = result
            try actionStore.save(action)
            return result
        } catch {
            action.state = "uncertain"
            try? actionStore.save(action)
            throw error
        }
    }
    private func receipt(_ action: ApplePreparedAction) -> AppleServiceResult {
        action.result ?? AppleServiceResult(status: action.state, message: "Existing action receipt. Do not repeat an uncertain action.", actionID: action.id)
    }
}
