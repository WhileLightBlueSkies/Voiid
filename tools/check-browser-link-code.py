#!/usr/bin/env python3
"""Exercise the production Swift QR parser without booting an app or using an account."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = root / "apps/ios/Voiid/Voiid/Main/Settings/LinkBrowserCode.swift"
with tempfile.TemporaryDirectory(prefix="voiid-link-parser-") as directory:
    folder = Path(directory)
    (folder / "main.swift").write_text('''import Foundation
let token = String(repeating: "a", count: 32)
precondition(LinkBrowserCode.token(from: "voiid://link?token=\\(token)") == token)
for raw in ["https://example.com?token=\\(token)", "voiid://link?token=\\(token)&token=\\(token)", "voiid://link/path?token=\\(token)", "voiid://link?token=\\(token)#fake", "voiid://evil@link?token=\\(token)", "voiid://link:443?token=\\(token)", "voiid://link?token=\\(token)%0A", "voiid://link?token=short", "voiid://profile?token=\\(token)"] {
    precondition(LinkBrowserCode.token(from: raw) == nil, "Accepted unexpected QR payload")
}
print("QR parser: valid code accepted; 9 invalid payloads rejected")
''')
    subprocess.run(["swiftc", "-module-cache-path", str(folder / "cache"), str(source), str(folder / "main.swift"), "-o", str(folder / "check")], check=True)
    subprocess.run([str(folder / "check")], check=True)
