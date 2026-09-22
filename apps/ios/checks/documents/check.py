"""Compile actual attachment import/wire code without building or launching the app."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[4]
view = (root / 'apps/ios/Voiid/Voiid/Main/ChatDetailView.swift').read_text()
engine = (root / 'apps/ios/Voiid/Voiid/Networking/ChatEngine.swift').read_text()
reader = view[view.index('nonisolated struct ChatDocumentFile:'):view.index('struct ChatDocumentBubble:')]
ref = engine[engine.index('struct MediaRef:'):engine.index('/// A story reply')]
envelope = engine[engine.index('    struct MediaEnvelope:'):engine.index('    /// Decode a decrypted plaintext')]
with tempfile.TemporaryDirectory(prefix='voiid-document-check-') as temp:
    path = Path(temp)
    (path / 'Source.swift').write_text('import Foundation\nimport UniformTypeIdentifiers\n' + reader + ref + 'enum ChatEngine {\n' + envelope + '\n}')
    subprocess.run(['xcrun', '-sdk', 'macosx', 'swiftc', '-module-cache-path', '/tmp/voiid-document-check-cache', str(path / 'Source.swift'), str(Path(__file__).with_name('DocumentCheck.swift')), '-o', str(path / 'check')], check=True)
    subprocess.run([str(path / 'check')], check=True)
