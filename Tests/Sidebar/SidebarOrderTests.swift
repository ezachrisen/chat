import Testing
@testable import SidebarCore

@Test func missingOrInvalidOrderKeepsDefaultOrder() {
    #expect(SidebarOrder.sorted(["group:a", "agent:b"], saved: "invalid") == ["group:a", "agent:b"])
}

@Test func savedOrderIgnoresDeletedAndDuplicateKeysAndAppendsNewChats() {
    #expect(SidebarOrder.sorted(["a", "b", "c"], saved: "[\"b\",\"gone\",\"b\",\"a\"]") == ["b", "a", "c"])
}

@Test func movesInBothDirectionsAndRoundTrips() throws {
    let keys = ["group:a", "agent:b", "agent:c"]
    let down = try #require(SidebarOrder.moving(keys[0], to: keys[2], keys: keys, saved: "[]"))
    #expect(SidebarOrder.sorted(keys, saved: down) == [keys[1], keys[2], keys[0]])
    let up = try #require(SidebarOrder.moving(keys[0], to: keys[1], keys: keys, saved: down))
    #expect(SidebarOrder.sorted(keys, saved: up) == keys)
}

@Test func nestedOrderDoesNotOverwriteTopLevelOrder() throws {
    let saved = "[\"agent:b\",\"group:a\",\"chat:1\",\"chat:2\"]"
    let updated = try #require(SidebarOrder.moving("chat:2", to: "chat:1", keys: ["chat:1", "chat:2"], saved: saved))
    #expect(SidebarOrder.sorted(["group:a", "agent:b"], saved: updated) == ["agent:b", "group:a"])
    #expect(SidebarOrder.sorted(["chat:1", "chat:2"], saved: updated) == ["chat:2", "chat:1"])
}

@Test func foreignOrSameRowDropsAreRejected() {
    #expect(SidebarOrder.moving("foreign", to: "a", keys: ["a", "b"], saved: "[]") == nil)
    #expect(SidebarOrder.moving("a", to: "a", keys: ["a", "b"], saved: "[]") == nil)
}
