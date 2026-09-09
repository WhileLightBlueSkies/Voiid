"""Build an isolated UI harness from the production bubble/menu sources; no account/network."""
from pathlib import Path
import shutil, sys
root = Path(__file__).resolve().parents[2] / 'Voiid' / 'Voiid'
out = Path(sys.argv[1] if len(sys.argv) > 1 else '/private/tmp/voiid-chat-qa')
(out / 'App').mkdir(parents=True, exist_ok=True)
(out / 'Tests').mkdir(exist_ok=True)
for name in ['Main/MessageContextMenu.swift', 'Main/MessageReactionBadges.swift', 'Models/MessageReactions.swift', 'DesignSystem/Theme.swift', 'DesignSystem/Haptics.swift', 'Main/DateFormatting.swift', 'Main/EmojiPickerSheet.swift', 'Main/AsyncVoiceNote.swift', 'Main/VoiceNote.swift', 'Main/MessageDayGroups.swift']:
    shutil.copyfile(root / name, out / 'App' / Path(name).name)
source = (root / 'Main/ChatDetailView.swift').read_text()
bubble = source[source.index('struct MessageBubble:'):source.index('// MARK: - Game invite bubble')]
shape = source[source.index('struct BubbleShape:'):source.index('// MARK: - Encrypted media rendering')]
(out / 'App/Bubble.swift').write_text('import SwiftUI\nimport UIKit\n' + bubble + shape)
model = (root / 'Models/Models.swift').read_text()
(out / 'App/Message.swift').write_text('import SwiftUI\n' + model[model.index('enum MessageStatus:'):model.index('/// `self` is Note to Self')])
for name in ['Harness.swift', 'Stubs.swift', 'VoiceHarness.swift']:
    shutil.copyfile(Path(__file__).parent / name, out / 'App' / name)
shutil.copyfile(Path(__file__).parent / 'InteractionTests.swift', out / 'Tests/InteractionTests.swift')
shutil.copyfile(Path(__file__).parent / 'VoiceTests.swift', out / 'Tests/VoiceTests.swift')
(out / 'project.yml').write_text('''name: ChatQA
options:
  deploymentTarget:
    iOS: "18.0"
settings:
  base:
    SWIFT_VERSION: "5.0"
    CODE_SIGNING_ALLOWED: NO
targets:
  ChatQA:
    type: application
    platform: iOS
    sources: [App]
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: in.voiid.chat-qa
        GENERATE_INFOPLIST_FILE: YES
        INFOPLIST_KEY_UILaunchScreen_Generation: YES
        INFOPLIST_KEY_NSMicrophoneUsageDescription: Isolated recording control test
  ChatQATests:
    type: bundle.ui-testing
    platform: iOS
    sources: [Tests]
    dependencies:
      - target: ChatQA
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: in.voiid.chat-qa.tests
        GENERATE_INFOPLIST_FILE: YES
schemes:
  ChatQA:
    build:
      targets:
        ChatQA: all
    test:
      targets: [ChatQATests]
''')
print(out)
