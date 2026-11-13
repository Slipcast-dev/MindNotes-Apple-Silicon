import SwiftUI

/// Макет 3: какие календари показывать в виде «День». Новые события всё равно пишутся в календарь приложения.
struct CalendarPickerView: View {
    let engine: CalendarSyncEngine
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String> = []
    @State private var all: [CalendarInfo] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            List {
                ForEach(Dictionary(grouping: all, by: \.source).sorted { $0.key < $1.key }, id: \.key) { source, cals in
                    Section(source.isEmpty ? L("Другие") : source) {
                        ForEach(cals) { c in
                            Toggle(isOn: Binding(get: { selected.contains(c.id) },
                                                 set: { on in if on { selected.insert(c.id) } else { selected.remove(c.id) } })) {
                                HStack(spacing: 6) {
                                    Circle().fill(Color(rgb: c.color)).frame(width: 9, height: 9)
                                    Text(c.title)
                                    if !c.isEditable {
                                        Image(systemName: "lock").foregroundStyle(.secondary).help(L("Только для чтения"))
                                    }
                                }
                            }
                        }
                    }
                }
            }
            Text(L("Новые события сохраняются в календарь приложения. Календари с замком доступны только для чтения."))
                .font(.caption).foregroundStyle(.secondary).padding(12)
            HStack {
                Button(L("Показать все")) { selected = Set(all.map(\.id)) }
                Spacer()
                Button(L("Отмена")) { dismiss() }
                Button(L("Готово")) {
                    engine.setVisibleCalendars(selected.count == all.count ? nil : selected)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 380, minHeight: 420)
        .onAppear {
            all = engine.gateway.containers(.event)
            selected = engine.settings.visibleCalendarIDs ?? Set(all.map(\.id))
        }
    }
}
