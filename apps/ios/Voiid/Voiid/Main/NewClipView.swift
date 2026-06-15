//
//  NewClipView.swift
//  Voiid
//
//  New clip upload (Figma Screen-10.5b).
//

import SwiftUI
import PhotosUI

struct NewClipView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var picked = false

    var body: some View {
        NavigationStack {
            VStack(spacing: VoiidSpacing.md) {
                PhotosPicker(selection: $pickerItem, matching: .videos) {
                    RoundedRectangle(cornerRadius: VoiidRadius.lg)
                        .fill(VoiidColor.fieldFill)
                        .frame(height: 360)
                        .overlay(VStack(spacing: VoiidSpacing.sm) {
                            Image(systemName: picked ? "checkmark.circle.fill" : "video.badge.plus")
                                .font(.system(size: 54)).foregroundColor(VoiidColor.primary)
                            Text(picked ? "Video selected" : "Tap to pick a video")
                                .font(VoiidFont.body).foregroundColor(VoiidColor.textSecondary)
                        })
                }
                .onChange(of: pickerItem) { _, v in picked = v != nil; if picked { Haptics.success() } }

                VoiidTextField(placeholder: "Title", text: $title)
                VoiidTextField(placeholder: "Description", text: $description)
                Spacer()
                VoiidPrimaryButton(title: "Share", enabled: picked && !title.isEmpty) {
                    Haptics.success(); dismiss()
                }
            }
            .padding(VoiidSpacing.lg)
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("New Clip").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
        }
    }
}
