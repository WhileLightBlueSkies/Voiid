"""Source integration guards; runtime/device acceptance is tracked separately."""
import pathlib
import unittest
ROOT = pathlib.Path(__file__).resolve().parents[2]
ANDROID = ROOT / 'apps/android/app/src/main/java/com/voiid/app/ui/components'
class NativeUIContract(unittest.TestCase):
    def test_sheet_exit_waits_for_animation(self):
        s = (ANDROID / 'VoiidSheet.kt').read_text()
        exit = s.split('// Exit:')[1].split('fun settleAfterGesture')[0]
        self.assertIn('settleJob?.join()', exit)
        self.assertIn('ensureActive()', exit)
    def test_detent_identity_is_not_sorted_index(self):
        s = (ANDROID / 'VoiidSheet.kt').read_text()
        self.assertIn('detentAnchors.getOrNull(settledIndex)', s)
        self.assertIn('rawTranslate = offscreenAnchor', s)
    def test_native_dialog_back_policy(self):
        s = (ANDROID / 'VoiidDialog.kt').read_text()
        self.assertIn('dismissOnBackPress = backDismissable && !busy', s)
        self.assertIn('dismissOnBackPress = backDismissable,', s)
    def test_photo_has_release_cancel_and_semantic_close(self):
        s = (ANDROID / 'VoiidPhotoViewer.kt').read_text()
        for marker in ['awaitEachGesture', 'calculateVelocity()', 'finally', 'IconButton(', 'safeDrawingPadding()', 'clampPhotoPan']:
            self.assertIn(marker, s)
    def test_tabs_have_no_unowned_timers_or_shrinking_labels(self):
        s = (ROOT / 'apps/ios/Voiid/Voiid/Main/RootTabView.swift').read_text()
        self.assertNotIn('DispatchQueue.main.asyncAfter', s)
        self.assertNotIn('minimumScaleFactor', s)
        self.assertIn('accessibilityReduceMotion', s)
        self.assertIn('stretchTask?.cancel()', s)
    def test_font_tokens_are_semantic(self):
        s = (ROOT / 'apps/ios/Voiid/Voiid/DesignSystem/Theme.swift').read_text()
        font = s.split('enum VoiidFont {')[1].split('// MARK: - Ludo')[0]
        self.assertNotIn('.system(size:', font)
