//
//  CreateProfileScreen.swift
//  Voiid
//
//  Onboarding — profile photo + about (Figma Screen-5). Native back button.
//

import SwiftUI
import PhotosUI

struct CreateProfileScreen: View {
    let onFinish: () -> Void
    @EnvironmentObject var session: AppSession
    @Environment(\.dismiss) private var dismiss
    @State private var about = ""
    @State private var photoItem: PhotosPickerItem?
    @State private var photo: Image?

    private let pillHeight: CGFloat = 64
    private let pillRadius: CGFloat = VoiidRadius.pill
    private let avatar: CGFloat = 110

    var body: some View {
        ZStack {
            VoiidBackground().dismissKeyboardOnTap()
            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: 8)
                // Title matches the Phone/OTP screens (22 bold), left-aligned
                Text("Create profile")
                    .font(VoiidFont.rounded(22, .bold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .padding(.horizontal, VoiidSpacing.lg)

                // Avatar with pink camera badge (centered)
                PhotosPicker(selection: $photoItem, matching: .images) {
                    ZStack(alignment: .bottomTrailing) {
                        ZStack {
                            Circle().fill(VoiidColor.fieldFill)
                            if let photo {
                                photo.resizable().scaledToFill()
                                    .frame(width: avatar, height: avatar).clipShape(Circle())
                            } else {
                                Image("VoiidWordmark")   // faint logo mark placeholder
                                    .resizable().scaledToFit()
                                    .frame(width: avatar * 0.5)
                                    .opacity(0.25)
                            }
                        }
                        .frame(width: avatar, height: avatar)

                        // pink camera badge
                        Circle().fill(VoiidColor.accent)
                            .frame(width: 32, height: 32)
                            .overlay(Image(systemName: "camera.fill")
                                .font(.system(size: 14)).foregroundColor(VoiidColor.primary))
                            .overlay(Circle().stroke(VoiidColor.background, lineWidth: 2))
                    }
                }
                .frame(maxWidth: .infinity)   // center the avatar
                .padding(.top, VoiidSpacing.xl)
                .onChange(of: photoItem) { _, item in
                    Task {
                        if let data = try? await item?.loadTransferable(type: Data.self),
                           let ui = UIImage(data: data) { photo = Image(uiImage: ui) }
                    }
                }

                // About you pill text area
                TextField("", text: $about,
                          prompt: Text("About you").foregroundColor(VoiidColor.placeholder),
                          axis: .vertical)
                    .font(VoiidFont.rounded(17, .regular)).lineLimit(4...7)
                    .foregroundColor(VoiidColor.textPrimary)
                    .padding(.horizontal, VoiidSpacing.lg)
                    .padding(.vertical, VoiidSpacing.md)
                    .frame(maxWidth: .infinity, minHeight: 130, alignment: .topLeading)
                    .background(VoiidColor.fieldFill)
                    .clipShape(RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 28).stroke(VoiidColor.fieldBorder, lineWidth: 1))
                    .padding(.horizontal, VoiidSpacing.lg)
                    .padding(.top, VoiidSpacing.xxl)

                Spacer()

                Button(action: {
                    session.profile.bio = about
                    Haptics.success(); onFinish()
                }) {
                    Text("Sign up")
                        .font(VoiidFont.rounded(18, .medium))
                        .foregroundColor(VoiidColor.textPrimary)
                        .frame(maxWidth: .infinity).frame(height: pillHeight)
                        .background(VoiidColor.accent)
                        .clipShape(RoundedRectangle(cornerRadius: pillRadius, style: .continuous))
                }
                .buttonStyle(SoftPressStyle())
                .padding(.horizontal, VoiidSpacing.lg).padding(.bottom, VoiidSpacing.xl)
            }
        }
        // Native back button (system chevron) — nav bar shown, transparent over our bg.
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(VoiidColor.primary)   // native back chevron color
    }
}
