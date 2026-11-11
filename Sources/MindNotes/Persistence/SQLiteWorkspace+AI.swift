import Foundation

/// Данные ИИ-ассистента без смены схемы (ADR-0016): настройки свойств — в их `config_json`,
/// остальное — в `workspace_meta`. Прежние версии сохраняют неизвестные поля и ключи.
extension SQLiteWorkspace {
    /// Меняет одно поле `config.extra` свойства; остальные настройки остаются как были.
    func setPropertyExtra(_ id: UUID, key: String, value: JSONValue?) async throws {
        try await writer.run { db in
            try db.transaction {
                guard try db.scalarInt("SELECT 1 FROM property_definitions WHERE id=?", [SQLValue(id)]) != nil else {
                    throw WorkspaceError.storage(code: 0, detail: NSLocalizedString("Свойство не найдено.", comment: ""))
                }
                var config = PropertyConfig(json: try db.scalarText("SELECT config_json FROM property_definitions WHERE id=?", [SQLValue(id)]))
                config.extra[key] = value
                try db.run("UPDATE property_definitions SET config_json=? WHERE id=?", [config.isEmpty ? .null : .text(try config.jsonString()), SQLValue(id)])
            }
        }
    }
}
