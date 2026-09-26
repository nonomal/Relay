//
//  SettingRowMac.swift
//  RelayMac
//

import SwiftUI

struct SettingRowMac: View {
    let setting: Setting
    /// The value in whatever JSON shape BoxJS stored it; read through `JSONValue`'s
    /// web-faithful coercions.
    @Binding var value: JSONValue

    var body: some View {
        switch setting.kind {
        case .boolean:
            toggleRow
        case .radios:
            radioPicker
        case .selects:
            menuPickerRow
        case .text, .textarea, .number, .slider, .colorpicker, .checkboxes:
            // Checkboxes edit as their stored comma-separated text.
            textRow
        }
    }

    // MARK: - Rows

    private var toggleRow: some View {
        Toggle(isOn: boolBinding) {
            labelText
        }
    }

    private var textRow: some View {
        HStack {
            labelText
            Spacer()
            TextField("", text: stringBinding, prompt: promptText)
                .textFieldStyle(.roundedBorder)
                .labelsHidden()
                .frame(maxWidth: 280)
        }
    }

    private var promptText: Text? {
        guard let placeholder = setting.placeholder, !placeholder.isEmpty else { return nil }
        return Text(placeholder)
    }

    private var radioPicker: some View {
        let items: [RadioItem] = setting.items ?? []
        return Picker(selection: stringBinding) {
            unmatchedOption(in: items)
            ForEach(items) { item in
                Text(item.label).tag(item.key)
            }
        } label: {
            labelText
        }
    }

    private var menuPickerRow: some View {
        let items: [RadioItem] = setting.items ?? []
        let selectedKey = stringBinding.wrappedValue
        let selectedLabel = items.first(where: { $0.key == selectedKey })?.label ?? selectedKey

        return HStack {
            labelText
            Spacer()
            if items.isEmpty {
                Text("—")
                    .foregroundStyle(.secondary)
            } else {
                Picker("", selection: stringBinding) {
                    unmatchedOption(in: items)
                    ForEach(items) { item in
                        Text(item.label).tag(item.key)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .frame(maxWidth: 280, alignment: .trailing)
                .help(selectedLabel)
            }
        }
    }

    /// A stored value outside the options gets an entry of its own, so the picker never
    /// holds a selection it cannot show.
    @ViewBuilder
    private func unmatchedOption(in items: [RadioItem]) -> some View {
        let current = stringBinding.wrappedValue
        if !items.contains(where: { $0.key == current }) {
            Text(current.isEmpty ? "未选择" : current).tag(current)
        }
    }

    private var labelText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(setting.name ?? setting.id)
            if let desc = setting.desc, !desc.isEmpty {
                Text(desc).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Bindings

    private var stringBinding: Binding<String> {
        Binding {
            value.wireText
        } set: { newValue in
            value = .string(newValue)
        }
    }

    private var boolBinding: Binding<Bool> {
        Binding {
            value.boolValue ?? false
        } set: { newValue in
            value = .bool(newValue)
        }
    }
}
