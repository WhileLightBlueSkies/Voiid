//
//  PollComposeSheet.swift
//  Voiid
//
//  Compose a group poll: question + 2–6 options.
//

import SwiftUI

struct PollComposeSheet: View {
    var onSend: (String, [String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var question = ""
    @State private var options: [String] = ["", ""]

    private var valid: Bool {
        !question.trimmingCharacters(in: .whitespaces).isEmpty &&
        options.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.count >= 2
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                    field("Ask a question", text: $question)

                    Text("Options").font(VoiidFont.rounded(13, .medium)).foregroundColor(VoiidColor.textSecondary)
                    ForEach(options.indices, id: \.self) { i in
                        field("Option \(i + 1)", text: $options[i])
                    }
                    if options.count < 6 {
                        Button {
                            Haptics.tap(); options.append("")
                        } label: {
                            Label("Add option", systemImage: "plus.circle")
                                .font(VoiidFont.rounded(15, .regular)).foregroundColor(VoiidColor.primary)
                        }
                    }
                }
                .padding(VoiidSpacing.lg)
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("New Poll").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Send") {
                        let opts = options.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        Haptics.success(); onSend(question.trimmingCharacters(in: .whitespaces), opts); dismiss()
                    }.disabled(!valid).fontWeight(.semibold)
                }
            }
        }
    }

    private func field(_ placeholder: String, text: Binding<String>) -> some View {
        TextField("", text: text, prompt: Text(placeholder).foregroundColor(VoiidColor.placeholder))
            .font(VoiidFont.rounded(16, .regular)).foregroundColor(VoiidColor.textPrimary)
            .padding(.horizontal, VoiidSpacing.md).frame(height: 50)
            .background(VoiidColor.fieldFill)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md).stroke(VoiidColor.fieldBorder, lineWidth: 1))
    }
}
