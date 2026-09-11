import Foundation

nonisolated enum ToolRecoveryPolicy {
    static func canRecover(_ error: any Error, toolName: String, argumentsJSON: String) -> Bool {
        guard isRead(toolName: toolName, argumentsJSON: argumentsJSON) else { return false }
        if error is DecodingError { return true }
        if let serviceError = error as? AppleServiceError {
            // Permission loss, setup failures, cancellation, and uncertain outcomes must not be retried.
            if case .invalid = serviceError { return true }
            return false
        }
        if let skillError = error as? SkillAccessError {
            switch skillError {
            case .emptyPath, .notFound, .notAFile, .tooLarge: return true
            default: return false
            }
        }
        if let calendarError = error as? CalendarAccessError {
            switch calendarError {
            case .invalidStart, .invalidEnd, .endBeforeStart, .rangeTooLarge: return true
            default: return false
            }
        }
        if let stashError = error as? AgentStashError {
            switch stashError {
            case .invalid, .notFound: return true
            case .limitReached, .unavailable: return false
            }
        }
        return false
    }

    private static func isRead(toolName: String, argumentsJSON: String) -> Bool {
        if ["ListReminderLists", "FindReminders", "ReadReminder", "ListAgentStash", "ReadAgentStash", "ReadSkillFileTool", "ReadCalendarEvents"].contains(toolName) { return true }
        guard AppleServiceID.allCases.contains(where: { $0.toolName == toolName }),
              let request = try? JSONDecoder().decode(AppleServiceRequest.self, from: Data(argumentsJSON.utf8)) else { return false }
        return request.isRead
    }
}
