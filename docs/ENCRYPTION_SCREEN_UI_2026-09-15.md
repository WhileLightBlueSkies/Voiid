# Encryption-screen UI — 15 September 2026

The Android safety-number screen now places its loaded content in a single Column inside Crossfade. Previously multiple device cards and the instructions were sibling children of Crossfade's Box and could overlap. The updated card displays the QR and grouped digits together, keeps a four-module QR quiet zone, identifies the peer above the cards, and clears the bottom navigation area. Identity-key loading and safety-number derivation are unchanged. Verification instructions describe matching device identities and explain device-change mismatches.

The separate Voiid Ui iOS prototype opens one shared security-code sheet from either the conversation notice or contact profile, including normal one-to-one chats. Group previews select a member before displaying a code. Prototype QR and digits are explicitly labeled samples and do not verify real identities. This does not replace the production iOS SafetyNumberView.

Validation: Android compileDebugKotlin and assembleDebug passed; the signed Voiid Ui device build passed. No Android device was attached for a visual check. APK: `build/share/Voiid-Android-2026-09-15-encryption.apk`.

The encryption notice is now a compact centered capsule in Android and Voiid Ui, with a lock, short title, and verification chevron. The visible badge stays content-sized while the tap area meets the platform's minimum size. Both normal-chat entry points continue to open the same verification screen as the profile menu.
