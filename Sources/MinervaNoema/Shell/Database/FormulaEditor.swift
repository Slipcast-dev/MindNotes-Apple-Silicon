import SwiftUI

extension FormulaType {
    var title: String {
        switch self {
        case .number: return L("число")
        case .text: return L("текст")
        case .bool: return L("логическое")
        case .date: return L("дата")
        }
    }
}

/// Результат формулы в ячейке: только чтение; ошибка видна значком с текстом в подсказке.
struct FormulaCell: View {
    let property: PropertyDefinition
    let value: PropertyValue?

    var body: some View {
        switch value {
        case .error(let message)?:
            HStack(spacing: 4) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 11))
                Text("Ошибка").font(.system(size: 13)).lineLimit(1)
            }
            .foregroundColor(Tokens.danger)
            .help(message)
            .accessibilityLabel(Text(L("Ошибка формулы: %@", message)))
        case .checkbox(let on)?:
            Image(systemName: on ? "checkmark.square.fill" : "square")
                .foregroundColor(on ? Tokens.accent : Tokens.muted)
                .accessibilityLabel(Text(on ? "Да" : "Нет"))
        default:
            Text(PropertyDisplay.text(value, property: property) ?? L("Пусто"))
                .font(.system(size: 13))
                .foregroundColor(value == nil ? Tokens.muted : Tokens.ink)
                .lineLimit(1)
                .help(L("Считается по формуле"))
        }
    }
}

/// Что редактируется: новая формула с именем или существующее свойство.
struct FormulaEditTarget: Identifiable {
    var id = UUID()
    var name: String
    var property: PropertyDefinition?
}

/// Окно формулы: текст, проверка с местом ошибки, тип результата и пример на первых записях.
struct FormulaEditorSheet: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var model: DatabaseModel
    let target: FormulaEditTarget
    @State private var source = ""
    @State private var preview: SQLiteWorkspace.FormulaPreview?
    @State private var checking = false

    private var properties: [PropertyDefinition] {
        model.database?.properties.filter { $0.id != target.property?.id } ?? []
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L("Формула «%@»", target.name)).font(.system(size: 17, weight: .semibold))
            TextEditor(text: $source)
                .font(.system(size: 13, design: .monospaced))
                .frame(height: 90)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(Tokens.line))
                .accessibilityLabel(Text("Текст формулы"))
            status
            HStack(alignment: .top, spacing: 16) {
                list(L("Свойства"), properties.map { (label: $0.name, insert: "prop(" + FormulaReferences.quote($0.name) + ")") })
                list(L("Функции"), FormulaFunctions.all.filter { $0.name != "prop" }.map { (label: $0.signature, insert: $0.name + "(") })
            }
            .frame(height: 170)
            HStack {
                Spacer()
                Button("Отмена") { dismiss() }.buttonStyle(NotesButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Сохранить", action: save)
                    .buttonStyle(NotesButtonStyle(kind: .primary))
                    .disabled(source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || preview?.error != nil || preview == nil || checking)
            }
        }
        .padding(20)
        .frame(width: 640, height: 520)
        .onAppear {
            if let property = target.property, let database = model.database { source = model.store.formulaDisplayText(property, in: database) }
        }
        .task(id: source) {
            checking = true
            // Отменённая проверка не трогает флаг: его ведёт только проверка текущего текста.
            do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
            let text = source
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { preview = nil; checking = false; return }
            let result = try? await model.store.previewFormula(database: model.databaseID, source: text, editing: target.property?.id)
            guard !Task.isCancelled else { return }
            preview = result
            checking = false
        }
    }

    /// Ошибка с фрагментом, на который она указывает, или тип и пример.
    @ViewBuilder private var status: some View {
        if let error = preview?.error {
            VStack(alignment: .leading, spacing: 2) {
                Label(error.message, systemImage: "exclamationmark.triangle").foregroundColor(Tokens.danger)
                if let fragment = fragment(error.range) { Text(L("Место: «%@»", fragment)).foregroundColor(Tokens.muted) }
            }
            .font(.system(size: 12))
        } else if let preview, let type = preview.type {
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Результат: %@", type.title)).font(.system(size: 12, weight: .semibold))
                ForEach(Array(preview.samples.enumerated()), id: \.offset) { _, sample in
                    Text("\(sample.title.isEmpty ? L("Без названия") : sample.title): \(sample.value.isEmpty ? L("Пусто") : sample.value)")
                        .font(.system(size: 12)).foregroundColor(Tokens.muted).lineLimit(1)
                }
            }
        } else {
            Text("Например: prop(\"Цена\") * prop(\"Количество\")").font(.system(size: 12)).foregroundColor(Tokens.muted)
        }
    }

    private func fragment(_ range: FormulaRange) -> String? {
        let chars = Array(source)
        guard range.lowerBound < chars.count, range.lowerBound < range.upperBound else { return nil }
        let text = String(chars[range.lowerBound..<min(range.upperBound, chars.count)])
        return text.count > 60 ? String(text.prefix(60)) + "…" : text
    }

    private func list(_ title: String, _ items: [(label: String, insert: String)]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundColor(Tokens.muted)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        Button { source += item.insert } label: {
                            Text(item.label).font(.system(size: 12, design: .monospaced)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .buttonStyle(.plain)
                        .help(L("Вставить в формулу"))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func save() {
        let text = source, name = target.name
        let store = model.store, databaseID = model.databaseID
        if let property = target.property {
            model.perform { try await store.updateFormula(property.id, source: text, now: SystemClock().nowMillis()) }
        } else {
            model.perform { try await store.addFormula(database: databaseID, name: name, source: text, id: UUID(), now: SystemClock().nowMillis()) }
        }
        dismiss()
    }
}
