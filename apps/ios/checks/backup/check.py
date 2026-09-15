"""Compile production backup encode/import code against isolated storage fixtures."""
from pathlib import Path
import subprocess, tempfile, plistlib, re
root=Path(__file__).resolve().parents[4]
entitlements=plistlib.loads((root/'apps/ios/Voiid/Voiid/Voiid.entitlements').read_bytes())
cloud=(root/'apps/ios/Voiid/Voiid/Networking/ICloudBackupService.swift').read_text()
container=re.search(r'static let containerID = "([^"]+)"',cloud).group(1)
assert container in entitlements['com.apple.developer.ubiquity-container-identifiers']
s=(root/'apps/ios/Voiid/Voiid/Networking/ChatEngine.swift').read_text()
models=s[s.index('struct MediaRef:'):s.index('@MainActor\nfinal class ChatEngine')]
logic=s[s.index('    private struct BackupArchive:'):s.index('    /// Queue a text message')]
fixture=r'''
import Foundation
@MainActor final class TokenStore { static let shared=TokenStore(); var userId: String?="11111111-1111-1111-1111-111111111111" }
__MODELS__
@MainActor final class Engine {
 var store: [String:[DecryptedMessage]]=[:]; var storeLoaded=true; var diskOK=true; var writes=0
 func ensureLoaded() {}; func markDirty(_ id:String) {}
 func persist() async -> Bool { writes += 1; return diskOK }
__LOGIC__
}
@main struct Check {
 @MainActor static func main() async throws {
  let id="22222222-2222-2222-2222-222222222222"
  let m=DecryptedMessage(id:"m1",senderId:"peer",text:"photo",createdAt:Date(timeIntervalSince1970: 1789460000.125),isMine:false,media:MediaRef(mediaUrl:"media/key",mime:"image/jpeg",key:"k",nonce:"n",sha256:"h"))
  let e=Engine(); e.store=[id:[m]]
  let data=try e.exportStore()
  let fixtures=URL(fileURLWithPath:CommandLine.arguments[1]); try FileManager.default.createDirectory(at:fixtures,withIntermediateDirectories:true)
  try data.write(to:fixtures.appendingPathComponent("ios-v1.json"))
  let restored=Engine(); try await restored.importStore(data)
  precondition(restored.store[id]![0].createdAt == m.createdAt)
  precondition(restored.store[id]![0].media == m.media && restored.writes == 1)
  restored.store[id]![0].text="local edit"
  try await restored.importStore(data); precondition(restored.store[id]!.count == 1 && restored.store[id]![0].text == "local edit")
  let old=try JSONEncoder().encode([id:[m,m]])
  let legacy=Engine(); try await legacy.importStore(old)
  precondition(legacy.store[id]!.count == 1 && legacy.store[id]![0].createdAt == m.createdAt)
  for invalid in [Data(),Data("not json".utf8),Data("{\"../outside\":[]}".utf8)] {
   do { try await restored.importStore(invalid); fatalError("invalid import succeeded") } catch {}
   precondition(restored.store[id]![0].text == "local edit")
  }
  TokenStore.shared.userId="other"
  do { try await restored.importStore(data); fatalError("wrong account succeeded") } catch {}
  TokenStore.shared.userId="11111111-1111-1111-1111-111111111111"
  restored.diskOK=false
  do { try await restored.importStore(data); fatalError("disk failure succeeded") } catch {}
  let android=fixtures.appendingPathComponent("android-v1.json")
  if FileManager.default.fileExists(atPath:android.path) {
   let target=Engine(); try await target.importStore(Data(contentsOf:android))
   precondition(target.store[id]![0].createdAt == m.createdAt)
   precondition(target.store[id]![0].locationJSON != nil)
  }
  print("PASS: archive timestamps/media, legacy decode, dedup/local preservation, malformed/path rejection, account binding, disk failure; Android fixture checked when present")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='voiid-backup-check-') as d:
 p=Path(d)/'Check.swift';p.write_text(fixture.replace('__MODELS__',models).replace('__LOGIC__',logic))
 exe=Path(d)/'check'
 subprocess.run(['xcrun','swiftc','-parse-as-library',str(p),'-o',str(exe)],check=True)
 subprocess.run([str(exe),str(root/'apps/android/app/src/test/resources/backup')],check=True)
