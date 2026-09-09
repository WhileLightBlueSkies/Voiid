#!/usr/bin/env python3
"""Exercise the production transcript merge/cache with same-count chat and call updates."""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
s = (root/'apps/ios/Voiid/Voiid/Models/Stores.swift').read_text()
def block(marker):
    start = s.index(marker); opening = s.index('{', start); depth = 1; end = opening + 1
    while depth:
        depth += (s[end] == '{') - (s[end] == '}'); end += 1
    return s[start:end]
def property(name):
    start = s.index('@Published var '+name)
    end = s.index('\n', start)
    return (block('@Published var '+name) if '{' in s[start:end] else s[start:end]).replace('@Published ', '')
code = '''import Foundation
struct VMessage {
    let id: String
    let createdAt: Date
    var status: String = "sending"
    var reactions: [String: String] = [:]
    var deleted = false
}
final class Store {
'''+property('messagesByConversation')+'\n'+property('callLogsByConversation')+'\n'+block('func messages(for')+'\n'+block('private struct MergeStamp:')+'''
private var mergeCache: [String: (stamp: MergeStamp, value: [VMessage])] = [:]
}
let store = Store()
store.messagesByConversation["chat"] = [VMessage(id: "text", createdAt: Date(timeIntervalSince1970: 2))]
store.callLogsByConversation["chat"] = [VMessage(id: "call", createdAt: Date(timeIntervalSince1970: 1))]
precondition(store.messages(for: "chat").map(\\.id) == ["call", "text"])
store.messagesByConversation["chat"]![0].status = "read"
precondition(store.messages(for: "chat").last?.status == "read", "A call entry freezes the text status until another message is added")
store.messagesByConversation["chat"]![0].reactions = ["peer": "❤️"]
precondition(store.messages(for: "chat").last?.reactions == ["peer": "❤️"])
store.messagesByConversation["chat"]![0].deleted = true
precondition(store.messages(for: "chat").last?.deleted == true)
store.callLogsByConversation["chat"]![0].status = "answered"
precondition(store.messages(for: "chat").first?.status == "answered")
print("PASS existing text status, reactions, deletion and call outcome update without a new message")
'''
with tempfile.TemporaryDirectory(prefix='voiid-transcript-cache-') as directory:
    folder = Path(directory); (folder/'main.swift').write_text(code)
    subprocess.run(['xcrun','swiftc','-module-cache-path',str(folder/'cache'),str(folder/'main.swift'),'-o',str(folder/'check')],check=True)
    subprocess.run([str(folder/'check')],check=True)
