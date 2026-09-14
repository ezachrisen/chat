import Foundation

enum SidebarOrder {
    static func decode(_ value: String) -> [String] {
        (try? JSONDecoder().decode([String].self, from: Data(value.utf8))) ?? []
    }

    static func sorted(_ keys: [String], saved: String) -> [String] {
        var remaining = Set(keys)
        return (decode(saved) + keys).filter { remaining.remove($0) != nil }
    }

    static func moving(_ source: String, to target: String, keys: [String], saved: String) -> String? {
        var ordered = sorted(keys, saved: saved)
        guard source != target,
              let from = ordered.firstIndex(of: source),
              let to = ordered.firstIndex(of: target) else { return nil }
        ordered.remove(at: from)
        ordered.insert(source, at: to)
        // Keep ordering for other agents' nested chats and temporarily hidden agents.
        ordered += decode(saved).filter { !keys.contains($0) }
        guard let data = try? JSONEncoder().encode(ordered) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
