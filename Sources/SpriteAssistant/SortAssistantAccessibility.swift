import Foundation

enum SortAssistantAccessibility {
    static let thread = "SortAssistantThread"
    static let headerMascotButton = "SortAssistantHeaderMascotButton"
    static let mascotAttentionBadge = "SortAssistantMascotAttentionBadge"
    static let floatingPanel = "SortAssistantFloatingPanel"
    static let messageList = "SortAssistantMessageList"
    static let input = "SortAssistantInput"
    static let inputField = "SortAssistantInputField"
    static let sendButton = "SortAssistantSendButton"
    static let contextFreshnessWarning = "SortAssistantContextFreshnessWarning"
    static let semanticActionConfirmation = "SortAssistantSemanticActionConfirmation"
    static let semanticActionConfirmButton = "SortAssistantSemanticActionConfirm"
    static let semanticActionCancelButton = "SortAssistantSemanticActionCancel"
    static let suggestionList = "SortAssistantSuggestionList"
    static let resultCard = "SortAssistantResultCard"
    static let sortPreviewList = "SortAssistantSortPreviewList"
    static let choicePrompt = "SortAssistantChoicePrompt"

    static func suggestionCard(_ suggestion: ProactiveSuggestion) -> String {
        "SortAssistantSuggestionCard.\(suggestion.type).\(suggestion.workspaceId.uuidString)"
    }

    static func suggestionOpenButton(_ suggestion: ProactiveSuggestion) -> String {
        "SortAssistantSuggestionOpen.\(suggestion.id.uuidString)"
    }

    static func suggestionDismissButton(_ suggestion: ProactiveSuggestion) -> String {
        "SortAssistantSuggestionDismiss.\(suggestion.id.uuidString)"
    }

    static func resultActionButton(_ action: SortAssistantResultAction) -> String {
        "SortAssistantResultAction.\(action.rawValue)"
    }

    static func messageRow(_ id: UUID) -> String {
        "SortAssistantMessage.\(id.uuidString)"
    }
}
