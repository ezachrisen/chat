import Foundation
import AppKit
import Carbon

/// Only fixed application terminology is accepted here. User strings are descriptor data.
nonisolated final class AppleEventsTransport {
    let target: NSAppleEventDescriptor
    let fence: AppleServiceFence
    init(bundleID: String, fence: AppleServiceFence) {
        self.target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        self.fence = fence
    }
    static func code(_ value: String) -> UInt32 {
        precondition(value.utf8.count == 4)
        return value.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
    static func object(_ kind: String, in container: NSAppleEventDescriptor = .null(), form: String = "ID  ", selector: NSAppleEventDescriptor) -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        record.setDescriptor(NSAppleEventDescriptor(typeCode: code(kind)), forKeyword: code("want"))
        record.setDescriptor(container, forKeyword: code("from"))
        record.setDescriptor(NSAppleEventDescriptor(enumCode: code(form)), forKeyword: code("form"))
        record.setDescriptor(selector, forKeyword: code("seld"))
        return record.coerce(toDescriptorType: code("obj "))!
    }
    static func property(_ key: String, of object: NSAppleEventDescriptor = .null()) -> NSAppleEventDescriptor {
        self.object("prop", in: object, form: "prop", selector: NSAppleEventDescriptor(typeCode: code(key)))
    }
    func send(_ eventID: String, parameters: [String: NSAppleEventDescriptor] = [:]) throws -> NSAppleEventDescriptor {
        try send("core", eventID, parameters: parameters)
    }
    func send(_ eventClass: String, _ eventID: String, parameters: [String: NSAppleEventDescriptor] = [:]) throws -> NSAppleEventDescriptor {
        try fence.check()
        let event = NSAppleEventDescriptor(eventClass: Self.code(eventClass), eventID: Self.code(eventID), targetDescriptor: target, returnID: -1, transactionID: 0)
        for (key, value) in parameters { event.setParam(value, forKeyword: Self.code(key)) }
        let reply: NSAppleEventDescriptor
        do { reply = try event.sendEvent(options: [.waitForReply, .neverInteract], timeout: 8) }
        catch {
            let code = (error as NSError).code
            if code == -1743 || code == -1744 { throw AppleServiceError.needsSetup("Allow Chat to control this app in Settings → Apple Services.") }
            if code == -1712 { throw AppleServiceError.uncertain }
            throw AppleServiceError.unavailable("Apple application returned error \(code).")
        }
        let error = reply.paramDescriptor(forKeyword: Self.code("errn"))?.int32Value ?? 0
        guard error == 0 else {
            if error == -1728 { throw AppleServiceError.forbidden }
            if error == -1712 { throw AppleServiceError.uncertain }
            if error == -1743 || error == -1744 { throw AppleServiceError.needsSetup("Allow Automation access in System Settings.") }
            throw AppleServiceError.unavailable("Apple application returned error \(error).")
        }
        return reply.paramDescriptor(forKeyword: Self.code("----")) ?? .null()
    }
    func get(_ object: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor { try send("getd", parameters: ["----": object]) }
    func property(_ key: String, of object: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor { try get(Self.property(key, of: object)) }
    func string(_ key: String, of object: NSAppleEventDescriptor) throws -> String { try property(key, of: object).stringValue ?? "" }
    func set(_ key: String, of object: NSAppleEventDescriptor, to value: NSAppleEventDescriptor) throws {
        _ = try send("setd", parameters: ["----": Self.property(key, of: object), "data": value])
    }
    func elements(_ kind: String, in parent: NSAppleEventDescriptor = .null(), maximum: Int = 100, offset: Int = 0) throws -> (items: [NSAppleEventDescriptor], more: Bool) {
        let all = Self.object(kind, in: parent, form: "indx", selector: NSAppleEventDescriptor(enumCode: Self.code("all ")))
        let count = Int(try send("cnte", parameters: ["----": all]).int32Value)
        let end = min(count, offset + maximum)
        guard offset < end else { return ([], false) }
        return ((offset..<end).map { Self.object(kind, in: parent, form: "indx", selector: NSAppleEventDescriptor(int32: Int32($0 + 1))) }, end < count)
    }
    func make(_ kind: String, in parent: NSAppleEventDescriptor? = nil, properties: [String: NSAppleEventDescriptor]) throws -> NSAppleEventDescriptor {
        let record = NSAppleEventDescriptor.record()
        for (key, value) in properties { record.setDescriptor(value, forKeyword: Self.code(key)) }
        var params = ["kocl": NSAppleEventDescriptor(typeCode: Self.code(kind)), "prdt": record]
        if let parent { params["insh"] = parent }
        return try send("crel", parameters: params)
    }
}

nonisolated struct MailLocator: Codable, Sendable {
    var account: String
    var path: [String]
    var message: Int32?
    var draft: Bool = false
    var encoded: String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try! encoder.encode(self)).base64EncodedString()
    }
    static func decode(_ raw: String) throws -> Self {
        guard raw.count < 8192, let data = Data(base64Encoded: raw), let ref = try? JSONDecoder().decode(Self.self, from: data), ref.path.count < 20 else { throw AppleServiceError.invalid("Use a Mail ID from a previous result.") }
        return ref
    }
    var mailboxID: String { Self(account: account, path: path).encoded }
    func object() -> NSAppleEventDescriptor {
        if draft { return AppleEventsTransport.object("bcke", selector: .init(int32: message ?? 0)) }
        var object = AppleEventsTransport.object("mact", selector: .init(string: account))
        for name in path { object = AppleEventsTransport.object("mbxp", in: object, form: "name", selector: .init(string: name)) }
        if let message { object = AppleEventsTransport.object("mssg", in: object, selector: .init(int32: message)) }
        return object
    }
}
