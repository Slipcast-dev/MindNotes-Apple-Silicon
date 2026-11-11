import Foundation
import SwiftUI

/// Настройки ИИ (FR-AI-1). По умолчанию ИИ выключен; без согласия и ключа запросов нет.
@MainActor
final class AISettings: ObservableObject {
    static let shared = AISettings()

    nonisolated static let enabledKey = "aiEnabled"
    nonisolated static let consentKey = "aiConsentGiven"
    private static let modelKey = "aiModel"
    private static let effortKey = "aiChatEffort"
    private static let confirmKey = "aiConfirmCreation"
    private static let usageKey = "aiUsageByDay"

    /// Включён ли ИИ: выключатель и данное согласие. Ключ проверяет клиент.
    nonisolated static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: enabledKey) && UserDefaults.standard.bool(forKey: consentKey)
    }

    @Published var enabled: Bool { didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey) } }
    @Published var consentGiven: Bool { didSet { UserDefaults.standard.set(consentGiven, forKey: Self.consentKey) } }
    @Published var model: String { didSet { UserDefaults.standard.set(model, forKey: Self.modelKey) } }
    @Published var chatEffort: AIEffort { didSet { UserDefaults.standard.set(chatEffort.rawValue, forKey: Self.effortKey) } }
    /// Спрашивать перед созданием страниц и добавлением текста. Правка существующего и корзина — всегда с вопросом.
    @Published var confirmCreation: Bool { didSet { UserDefaults.standard.set(confirmCreation, forKey: Self.confirmKey) } }
    @Published private(set) var hasKey: Bool
    /// Модели из `GET /v1/models` после проверки ключа.
    @Published var availableModels: [String] = []
    @Published private(set) var usage: [String: AIUsage] = [:]

    var isActive: Bool { enabled && consentGiven && hasKey }

    /// Встроенный список, если список моделей не загружен.
    static let fallbackModels = ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "claude-fable-5-2"]

    private init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: Self.enabledKey)
        consentGiven = d.bool(forKey: Self.consentKey)
        model = d.string(forKey: Self.modelKey) ?? AIDefaults.model
        chatEffort = AIEffort(rawValue: d.string(forKey: Self.effortKey) ?? "") ?? .medium
        confirmCreation = d.object(forKey: Self.confirmKey) as? Bool ?? true
        // Keychain читается только при включённом ИИ: выключенный ИИ не трогает даже ключ.
        hasKey = d.bool(forKey: Self.enabledKey) && AIKeychain.hasKey
        if let data = d.data(forKey: Self.usageKey), let saved = try? JSONDecoder().decode([String: AIUsage].self, from: data) { usage = saved }
    }

    func refreshKey() { hasKey = AIKeychain.hasKey }

    func saveKey(_ key: String) {
        AIKeychain.save(key)
        hasKey = AIKeychain.hasKey
    }

    func deleteKey() {
        AIKeychain.delete()
        hasKey = false
        availableModels = []
    }

    // MARK: Расход

    private static func day(_ date: Date = Date()) -> String {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// Учёт по дням (только счётчики, без текста запросов). Хранится 62 дня.
    func record(_ turn: AIUsage) {
        usage[Self.day(), default: AIUsage()].add(turn)
        let keep = Set((0..<62).map { Self.day(Date().addingTimeInterval(-86_400 * Double($0))) })
        usage = usage.filter { keep.contains($0.key) }
        if let data = try? JSONEncoder().encode(usage) { UserDefaults.standard.set(data, forKey: Self.usageKey) }
    }

    var today: AIUsage { usage[Self.day()] ?? AIUsage() }

    var thisMonth: AIUsage {
        let prefix = String(Self.day().prefix(7))
        var sum = AIUsage()
        for (day, value) in usage where day.hasPrefix(prefix) { sum.add(value) }
        return sum
    }
}
