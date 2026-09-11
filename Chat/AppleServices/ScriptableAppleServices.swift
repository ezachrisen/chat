import Foundation

nonisolated final class ScriptableAppleServices: @unchecked Sendable {
    static let shared = ScriptableAppleServices()
    private let queues = Dictionary(uniqueKeysWithValues: [AppleServiceID.notes, .mail, .messages].map { ($0, DispatchQueue(label: "Chat.AppleServices.\($0.rawValue)", qos: .userInitiated)) })
    func execute(_ service: AppleServiceID, _ request: AppleServiceRequest, grant: AppleServiceGrant, fence: AppleServiceFence, attachmentURL: URL? = nil) async throws -> AppleServiceResult {
        guard let queue = queues[service], let bundleID = service.bundleID else { throw AppleServiceError.forbidden }
        return try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    let ae = AppleEventsTransport(bundleID: bundleID, fence: fence)
                    let result: AppleServiceResult
                    switch service {
                    case .notes: result = try self.notes(request, grant: grant, ae: ae)
                    case .mail: result = try self.mail(request, grant: grant, ae: ae, attachmentURL: attachmentURL)
                    case .messages: result = try self.messages(request, grant: grant, ae: ae, attachmentURL: attachmentURL)
                    default: throw AppleServiceError.forbidden
                    }
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func notes(_ r: AppleServiceRequest, grant: AppleServiceGrant, ae: AppleEventsTransport) throws -> AppleServiceResult {
        if r.action == "folders" {
            let folders = try ae.elements("cfol", maximum: 200)
            var records: [AppleServiceRecord] = []
            for folder in folders.items {
                let id = try ae.string("ID  ", of: folder)
                guard grant.permits(id) else { continue }
                records.append(AppleServiceRecord(id: id, title: try ae.string("pnam", of: folder), container: id, fields: ["shared": String(try ae.property("shrd", of: folder).booleanValue), "parent": try ae.string("pnam", of: ae.property("cntr", of: folder))]))
            }
            return .page(records, request: r, coverage: folders.more ? "partial; first 200 folders" : "local folders")
        }
        let container = try r.required(r.container, "container (folder ID)")
        guard grant.permits(container) else { throw AppleServiceError.forbidden }
        let folder = AppleEventsTransport.object("cfol", selector: .init(string: container))
        if r.action == "search" {
            let notes = try ae.elements("note", in: folder, maximum: r.pageSize, offset: r.pageOffset)
            var records: [AppleServiceRecord] = []
            for note in notes.items {
                let title = try ae.string("pnam", of: note)
                guard r.query == nil || title.localizedStandardContains(r.query!) else { continue }
                records.append(AppleServiceRecord(id: try ae.string("ID  ", of: note), title: title, container: container))
            }
            return AppleServiceResult(records: records, nextOffset: notes.more ? r.pageOffset + r.pageSize : nil, coverage: "title search within this folder's scanned page; continue nextOffset even if empty")
        }
        if r.action == "create" {
            let title = try r.required(r.title, "title")
            let body = Self.noteHTML(title + "\n" + (r.body ?? ""))
            let note = try ae.make("note", in: folder, properties: ["body": .init(string: body)])
            return AppleServiceResult(status: "applied", records: [try noteRecord(note, container: container, ae: ae)])
        }
        let note = AppleEventsTransport.object("note", in: folder, selector: .init(string: try r.required(r.id, "id")))
        if r.action == "show" {
            guard try ae.string("ID  ", of: ae.property("cntr", of: note)) == container else { throw AppleServiceError.forbidden }
            _ = try ae.send("note", "show", parameters: ["----": note])
            return AppleServiceResult(status: "handed_off")
        }
        let record = try noteRecord(note, container: container, ae: ae)
        if r.action == "read" { return AppleServiceResult(records: [record]) }
        guard ["append", "update"].contains(r.action) else { throw AppleServiceError.unsupported("This Notes action is not available.") }
        try AppleServiceValidation.checkRevision(r.revision, record: record)
        let html = try ae.string("body", of: note)
        guard Self.isSimpleNote(html), try ae.elements("atts", in: note, maximum: 1).items.isEmpty else {
            throw AppleServiceError.unsupported("This note has rich content. Create a companion note to preserve the original.")
        }
        let content = try r.required(r.body, "body")
        let updated = r.action == "append" ? (record.fields["text"] ?? "") + "\n" + content : content
        try ae.set("body", of: note, to: .init(string: Self.noteHTML(updated)))
        return AppleServiceResult(status: "applied", records: [try noteRecord(note, container: container, ae: ae)])
    }
    private func noteRecord(_ note: NSAppleEventDescriptor, container: String, ae: AppleEventsTransport) throws -> AppleServiceRecord {
        let actualContainer = try ae.property("cntr", of: note)
        guard try ae.string("ID  ", of: actualContainer) == container else { throw AppleServiceError.forbidden }
        guard try !ae.property("pwpr", of: note).booleanValue else { throw AppleServiceError.unsupported("The note is locked. Open it in Notes.") }
        return AppleServiceRecord(id: try ae.string("ID  ", of: note), title: try ae.string("pnam", of: note), container: container,
                                  fields: ["text": try ae.string("text", of: note), "modified": try ae.property("asmo", of: note).dateValue.map { ISO8601DateFormatter().string(from: $0) } ?? "", "shared": String(try ae.property("shrd", of: note).booleanValue)])
    }
    static func noteHTML(_ text: String) -> String {
        text.components(separatedBy: "\n").map { "<div>" + $0.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;") + "</div>" }.joined()
    }
    static func isSimpleNote(_ html: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: "<[^>]*>") else { return false }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).allSatisfy { match in
            guard let range = Range(match.range, in: html) else { return false }
            let tag = html[range].lowercased().replacingOccurrences(of: " ", with: "")
            return ["<div>", "</div>", "<br>", "<br/>", "<p>", "</p>"].contains(tag)
        }
    }

    private func mail(_ r: AppleServiceRequest, grant: AppleServiceGrant, ae: AppleEventsTransport, attachmentURL: URL?) throws -> AppleServiceResult {
        if ["accounts", "mailboxes"].contains(r.action) {
            var records: [AppleServiceRecord] = []
            let accounts = try ae.elements("mact", maximum: 30)
            for account in accounts.items {
                let accountID = try ae.string("ID  ", of: account)
                if r.action == "accounts" {
                    // Account metadata is returned only when the account has an allowed mailbox.
                    if grant.allowsAll || grant.resourceIDs.contains(where: { (try? MailLocator.decode($0).account) == accountID }) {
                        records.append(AppleServiceRecord(id: accountID, title: try ae.string("pnam", of: account), container: accountID))
                    }
                } else {
                    try mailboxes(account, accountID: accountID, accountName: ae.string("pnam", of: account), path: [], grant: grant, ae: ae, records: &records)
                }
            }
            return .page(records, request: r, coverage: "local mailbox directory; max 300")
        }
        if r.action == "draft" {
            let sender = try AppleServiceValidation.endpoint(r.required(r.sender, "sender"))
            guard grant.sendingIdentities.contains(sender) else { throw AppleServiceError.forbidden }
            let recipient = try AppleServiceValidation.endpoint(r.required(r.recipient, "recipient"))
            let draft = try ae.make("bcke", properties: ["sndr": .init(string: sender), "subj": .init(string: r.title ?? ""), "ctnt": .init(string: r.body ?? ""), "pvis": .init(boolean: false)])
            _ = try ae.make("trcp", in: draft, properties: ["radd": .init(string: recipient)])
            if let attachmentURL { _ = try ae.make("atts", in: AppleEventsTransport.property("ctnt", of: draft), properties: ["atfn": .init(fileURL: attachmentURL)]) }
            _ = try ae.send("save", parameters: ["----": draft])
            return AppleServiceResult(status: "applied", records: [try draftRecord(draft, ae: ae, attachmentURL: attachmentURL)])
        }
        let locator = try MailLocator.decode(r.required(r.id ?? r.container, "id or container"))
        if locator.draft {
            let draft = locator.object()
            let record = try draftRecord(draft, ae: ae, attachmentURL: attachmentURL)
            guard grant.sendingIdentities.contains(try AppleServiceValidation.mailAddress(record.fields["sender"] ?? "")) else { throw AppleServiceError.forbidden }
            if r.action == "read" { return AppleServiceResult(records: [record]) }
            if r.action == "prepare_send" { return AppleServiceResult(records: [record]) }
            try AppleServiceValidation.checkRevision(r.revision, record: record)
            if r.action == "send" {
                guard try ae.send("emsg", "send", parameters: ["----": draft]).booleanValue else { throw AppleServiceError.uncertain }
                return AppleServiceResult(status: "submitted", message: "Mail accepted the send request; delivery is not confirmed.")
            }
            guard r.action == "update_draft" else { throw AppleServiceError.invalid("Unsupported draft action.") }
            if let title = r.title { try ae.set("subj", of: draft, to: .init(string: title)) }
            if let body = r.body { try ae.set("ctnt", of: draft, to: .init(string: body)) }
            _ = try ae.send("save", parameters: ["----": draft])
            return AppleServiceResult(status: "applied", records: [try draftRecord(draft, ae: ae, attachmentURL: attachmentURL)])
        }
        guard grant.permits(locator.mailboxID) else { throw AppleServiceError.forbidden }
        let object = locator.object()
        if r.action == "search" {
            guard locator.message == nil else { throw AppleServiceError.invalid("Search requires a mailbox container.") }
            let messages = try ae.elements("mssg", in: object, maximum: r.pageSize, offset: r.pageOffset)
            var records: [AppleServiceRecord] = []
            for item in messages.items {
                let subject = try ae.string("subj", of: item)
                let sender = try ae.string("sndr", of: item)
                guard r.query == nil || (subject + " " + sender).localizedStandardContains(r.query!) else { continue }
                let id = try ae.property("ID  ", of: item).int32Value
                let ref = MailLocator(account: locator.account, path: locator.path, message: id)
                records.append(AppleServiceRecord(id: ref.encoded, title: subject, container: locator.mailboxID, fields: ["sender": sender]))
            }
            return AppleServiceResult(records: records, nextOffset: messages.more ? r.pageOffset + r.pageSize : nil, coverage: "subject/sender search over scanned mailbox page; continue nextOffset even if empty")
        }
        guard locator.message != nil else { throw AppleServiceError.invalid("A message ID is required.") }
        if r.action == "show" {
            _ = try ae.send("aevt", "odoc", parameters: ["----": object])
            return AppleServiceResult(status: "handed_off")
        }
        let record = try mailRecord(object, locator: locator, ae: ae)
        if r.action == "read" { return AppleServiceResult(records: [record]) }
        if r.action == "reply" {
            let sender = try AppleServiceValidation.endpoint(r.required(r.sender, "sender"))
            guard grant.sendingIdentities.contains(sender) else { throw AppleServiceError.forbidden }
            let draft = try ae.send("emal", "rpms", parameters: ["----": object, "ropw": .init(boolean: false)])
            try ae.set("sndr", of: draft, to: .init(string: sender))
            if let body = r.body {
                let original = try ae.string("ctnt", of: draft)
                try ae.set("ctnt", of: draft, to: .init(string: body + "\n\n" + original))
            }
            _ = try ae.send("save", parameters: ["----": draft])
            return AppleServiceResult(status: "applied", records: [try draftRecord(draft, ae: ae, attachmentURL: attachmentURL)])
        }
        try AppleServiceValidation.checkRevision(r.revision, record: record)
        switch r.action {
        case "set_read", "set_flagged":
            guard let value = r.value, ["true", "false"].contains(value) else { throw AppleServiceError.invalid("value must be true or false.") }
            try ae.set(r.action == "set_read" ? "isrd" : "isfl", of: object, to: .init(boolean: value == "true"))
        case "move":
            let destination = try MailLocator.decode(r.required(r.container, "container"))
            guard destination.message == nil, !destination.draft, grant.permits(destination.mailboxID) else { throw AppleServiceError.forbidden }
            _ = try ae.send("move", parameters: ["----": object, "insh": destination.object()])
            return AppleServiceResult(status: "applied", message: "Message moved. Search the destination to obtain its new ID.")
        default: throw AppleServiceError.invalid("Unknown Mail action.")
        }
        return AppleServiceResult(status: "applied", records: [try mailRecord(object, locator: locator, ae: ae)])
    }

    private func mailboxes(_ parent: NSAppleEventDescriptor, accountID: String, accountName: String, path: [String], grant: AppleServiceGrant, ae: AppleEventsTransport, records: inout [AppleServiceRecord]) throws {
        guard path.count < 12, records.count < 300 else { throw AppleServiceError.invalid("Mailbox directory exceeds budget.") }
        for mailbox in try ae.elements("mbxp", in: parent, maximum: 100).items {
            let name = try ae.string("pnam", of: mailbox)
            let locator = MailLocator(account: accountID, path: path + [name])
            if grant.permits(locator.encoded) { records.append(AppleServiceRecord(id: locator.encoded, title: (path + [name]).joined(separator: " / "), container: locator.encoded, fields: ["account": accountID, "account_name": accountName])) }
            try mailboxes(mailbox, accountID: accountID, accountName: accountName, path: path + [name], grant: grant, ae: ae, records: &records)
        }
    }
    private func mailRecord(_ item: NSAppleEventDescriptor, locator: MailLocator, ae: AppleEventsTransport) throws -> AppleServiceRecord {
        AppleServiceRecord(id: locator.encoded, title: try ae.string("subj", of: item), container: locator.mailboxID,
                           fields: ["sender": try ae.string("sndr", of: item), "text": try ae.string("ctnt", of: item), "message_id": try ae.string("meid", of: item), "read": String(try ae.property("isrd", of: item).booleanValue), "flagged": String(try ae.property("isfl", of: item).booleanValue)])
    }
    private func draftRecord(_ draft: NSAppleEventDescriptor, ae: AppleEventsTransport, attachmentURL: URL?) throws -> AppleServiceRecord {
        let id = try ae.property("ID  ", of: draft).int32Value
        var fields = ["sender": try ae.string("sndr", of: draft), "text": try ae.string("ctnt", of: draft)]
        for (type, key) in [("trcp", "to"), ("crcp", "cc"), ("brcp", "bcc")] {
            let recipients = try ae.elements(type, in: draft, maximum: 50)
            guard !recipients.more else { throw AppleServiceError.unsupported("Too many recipients.") }
            fields[key] = try recipients.items.map { try ae.string("radd", of: $0) }.joined(separator: "\n")
        }
        let content = AppleEventsTransport.property("ctnt", of: draft)
        let attachments = try ae.elements("atts", in: content, maximum: 2)
        guard !attachments.more, attachments.items.count <= 1 else { throw AppleServiceError.unsupported("This draft has attachments not imported for this action. Review it in Mail.") }
        if let attachment = attachments.items.first {
            guard let attachmentURL, let attachedURL = try ae.property("atfn", of: attachment).fileURLValue else { throw AppleServiceError.unsupported("Pass the imported attachmentID used to create this draft, or send it in Mail.") }
            let values = try attachedURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
            guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= 25 * 1024 * 1024 else { throw AppleServiceError.conflict }
            let actual = AppleAttachmentStore.digest(try Data(contentsOf: attachedURL))
            guard actual == AppleAttachmentStore.digest(try Data(contentsOf: attachmentURL)) else { throw AppleServiceError.conflict }
            fields["attachment"] = attachmentURL.lastPathComponent + ":" + actual
        } else if attachmentURL != nil { throw AppleServiceError.conflict }
        return AppleServiceRecord(id: MailLocator(account: "", path: [], message: id, draft: true).encoded, title: try ae.string("subj", of: draft), container: "drafts", fields: fields)
    }

    private func messages(_ r: AppleServiceRequest, grant: AppleServiceGrant, ae: AppleEventsTransport, attachmentURL: URL?) throws -> AppleServiceResult {
        if r.action == "accounts" {
            var records: [AppleServiceRecord] = []
            for account in try ae.elements("icsv", maximum: 20).items {
                let id = try ae.string("ID  ", of: account)
                records.append(AppleServiceRecord(id: id, title: try ae.string("msdn", of: account), container: id,
                    fields: ["service": String(try ae.property("styp", of: account).enumCodeValue)]))
            }
            return AppleServiceResult(records: records)
        }
        if r.id == nil, let recipient = r.recipient {
            let endpoint = try AppleServiceValidation.endpoint(recipient)
            let accounts = try ae.elements("icsv", maximum: 20).items.filter { account in
                let enabled = try ae.property("enbl", of: account).booleanValue
                let type = try ae.property("styp", of: account).enumCodeValue
                let matches = try r.sender.map { try ae.string("ID  ", of: account) == $0 } ?? (type == AppleEventsTransport.code("sims"))
                return enabled && matches
            }
            guard accounts.count == 1, let account = accounts.first else { throw AppleServiceError.invalid("Choose one enabled Messages account with sender from accounts.") }
            let accountID = try ae.string("ID  ", of: account)
            let participant = AppleEventsTransport.object("pres", in: account, form: "name", selector: .init(string: endpoint))
            let record = AppleServiceRecord(id: "direct:" + accountID + ":" + endpoint, title: endpoint, container: accountID, fields: ["participants": endpoint, "account": accountID])
            if r.action == "prepare" { return AppleServiceResult(records: [record]) }
            guard r.action == "send" else { throw AppleServiceError.invalid("Use prepare then send for a new recipient.") }
            try AppleServiceValidation.checkRevision(r.revision, record: record)
            try sendMessage(r, to: participant, ae: ae, attachmentURL: attachmentURL)
            return AppleServiceResult(status: "submitted", message: "Messages accepted the request. Delivery and transport are not confirmed.")
        }
        if r.action == "chats" {
            let chats = try ae.elements("imct", maximum: r.pageSize, offset: r.pageOffset)
            var records: [AppleServiceRecord] = []
            for chat in chats.items {
                let id = try ae.string("ID  ", of: chat)
                guard grant.permits(id) else { continue }
                records.append(try chatRecord(chat, id: id, ae: ae))
            }
            return AppleServiceResult(records: records, nextOffset: chats.more ? r.pageOffset + r.pageSize : nil)
        }
        // Exact existing chat IDs avoid silently choosing a transport, account, or group.
        let id = try r.required(r.id, "id (existing conversation)")
        guard grant.permits(id) else { throw AppleServiceError.forbidden }
        let chat = AppleEventsTransport.object("imct", selector: .init(string: id))
        let record = try chatRecord(chat, id: id, ae: ae)
        if r.action == "prepare" { return AppleServiceResult(records: [record]) }
        guard r.action == "send" else { throw AppleServiceError.invalid("Unsupported Messages action.") }
        try AppleServiceValidation.checkRevision(r.revision, record: record)
        try sendMessage(r, to: chat, ae: ae, attachmentURL: attachmentURL)
        return AppleServiceResult(status: "submitted", message: "Messages accepted the send request; delivery is not confirmed.")
    }
    private func sendMessage(_ r: AppleServiceRequest, to target: NSAppleEventDescriptor, ae: AppleEventsTransport, attachmentURL: URL?) throws {
        guard r.body?.isEmpty == false || attachmentURL != nil else { throw AppleServiceError.invalid("Provide text or an imported attachment.") }
        if let body = r.body, !body.isEmpty { _ = try ae.send("icht", "send", parameters: ["----": .init(string: body), "TO  ": target]) }
        if let attachmentURL { _ = try ae.send("icht", "send", parameters: ["----": .init(fileURL: attachmentURL), "TO  ": target]) }
    }
    private func chatRecord(_ chat: NSAppleEventDescriptor, id: String, ae: AppleEventsTransport) throws -> AppleServiceRecord {
        let participants = try ae.elements("pres", in: chat, maximum: 100)
        guard !participants.more else { throw AppleServiceError.unsupported("Conversation exceeds participant budget.") }
        let handles = try participants.items.map { try ae.string("hndl", of: $0) }.sorted()
        return AppleServiceRecord(id: id, title: try ae.string("pnam", of: chat), container: id, fields: ["participants": handles.joined(separator: "\n"), "account": try ae.string("ID  ", of: ae.property("icsv", of: chat))])
    }
}
