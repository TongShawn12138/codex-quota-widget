import Foundation

struct QuotaWorkProgress: Codable, Hashable, Sendable {
    let tasks: [QuotaWorkTask]
    let checkedAt: Date
}

struct QuotaWorkTask: Codable, Hashable, Sendable {
    let title: String
    let status: String
    let completedSteps: Int?
    let totalSteps: Int?
    let currentStep: String?
    let completedToolCalls: Int?
    let startedAt: Date?
}
