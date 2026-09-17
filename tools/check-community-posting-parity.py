#!/usr/bin/env python3
"""Decode real production Swift wire models for Home/Space permission and counter parity."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
source = (root / 'apps/ios/Voiid/Voiid/Networking/CommunityService.swift').read_text()
def block(signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end].replace('private struct', 'struct')
fixture = '''import Foundation
enum CommunityMembership { case suspended, banned, joined, requested, none }
'''
for signature in ['    struct CommunityCard:', '    private struct CommunityEnvelope:', '    struct Channel:', '    struct Post:', '    struct PostPage:']:
    fixture += block(signature) + '\n'
fixture += r'''
let decoder = JSONDecoder()
for allowed in [true, false] {
    let raw = """
    {"community":{"id":"c","handle":"topic","name":"Topic","posting_policy":"selected"},
    "membership_state":"active","membership_role":"member","can_post":\(allowed)}
    """
    let card = try decoder.decode(CommunityEnvelope.self, from: Data(raw.utf8)).merged(inviteValid: nil)
    precondition(card.isMember && card.can_post == allowed)
}
let missing = try decoder.decode(CommunityEnvelope.self, from: Data(#"{"community":{"id":"c","handle":"topic","name":"Topic","posting_policy":"none"},"membership_state":"active","membership_role":"owner"}"#.utf8)).merged(inviteValid: nil)
precondition(missing.isManager && missing.can_post != true)
let channel = try decoder.decode(Channel.self, from: Data(#"{"conversation_id":"s","kind":"chat","posting":"none","can_post":false,"purpose":"Read only","pinned_at":"2026-09-17T00:00:00Z"}"#.utf8))
precondition(!channel.isAnnouncement && channel.posting == "none" && channel.can_post == false)
precondition(channel.purpose == "Read only" && channel.pinned_at != nil)
let page = try decoder.decode(PostPage.self, from: Data(#"{"posts":[{"id":"post","view_count":27,"like_count":4,"liked_by_me":true,"channel_id":"s","author_is_official":true}],"can_post":false,"next_cursor":"opaque"}"#.utf8))
precondition(page.rows[0].view_count == 27 && page.rows[0].likes == 4 && page.rows[0].isLiked)
precondition(page.rows[0].author_is_official == true && page.can_post == false && page.next_cursor == "opaque")
print("PASS: Swift Home permissions, fail-closed legacy responses, Space metadata, feed counters and official identity")
'''
with tempfile.TemporaryDirectory(prefix='voiid-community-wire-') as d:
    p=Path(d); (p/'Check.swift').write_text(fixture)
    subprocess.run(['swiftc','-module-cache-path',str(p/'cache'),str(p/'Check.swift'),'-o',str(p/'check')],check=True)
    subprocess.run([str(p/'check')],check=True)
