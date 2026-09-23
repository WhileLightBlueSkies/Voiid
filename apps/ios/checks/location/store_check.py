"""Exercise the actual inbound upsert SQL against an isolated SQLite database."""
from pathlib import Path
import re
import sqlite3

source = (Path(__file__).resolve().parents[2] / 'Voiid/Voiid/Storage/LocationStore.swift').read_text()
section = source.split('static func upsertInbound', 1)[1].split('static func isEnded', 1)[0]
sql = re.search(r'sql: """(.*?)"""', section, re.S).group(1)
db = sqlite3.connect(':memory:')
db.execute('CREATE TABLE location_shares(id TEXT PRIMARY KEY, kind TEXT, direction TEXT, conversation_id TEXT, peer_user_id TEXT, started_at INTEGER, expires_at INTEGER, ended_at INTEGER, cadence_seconds INTEGER, state TEXT)')

def upsert(owner='android', expires=2000, chat='group'):
    db.execute(sql, ('share', chat, owner, 1000, expires, 15))

def row():
    return db.execute('SELECT conversation_id,peer_user_id,expires_at,ended_at,state FROM location_shares').fetchone()

upsert()
assert row() == ('group', 'android', 2000, None, 'live')
upsert(expires=3000)
assert row()[2] == 3000
upsert(expires=2000)
assert row()[2] == 3000, 'Replaying older start must not shorten extension'
upsert(owner='imposter', expires=5000)
assert row()[1:3] == ('android', 3000), 'Owner must not change'
db.execute("UPDATE location_shares SET ended_at=1500,state='ended'")
upsert(expires=6000)
assert row() == ('group', 'android', 3000, 1500, 'ended'), 'Refreshing history must not revive stopped share'
stop_section = source.split('static func wasStoppedBeforeExpiry', 1)[1].split('static func end(', 1)[0]
stop_sql = re.search(r'sql: "([^"]+)"', stop_section).group(1)
assert db.execute(stop_sql, ('share',)).fetchone()[0] == 1, 'An early stop keeps its stopped label'
db.execute('UPDATE location_shares SET ended_at=3000')
assert db.execute(stop_sql, ('share',)).fetchone()[0] == 0, 'Expiry is ended, not stopped'
db.execute('UPDATE location_shares SET ended_at=NULL')
assert db.execute(stop_sql, ('share',)).fetchone()[0] == 0, 'An active row is not stopped'
assert db.execute(stop_sql, ('unknown',)).fetchone()[0] == 0
print('9 location store reconciliation and stop-reason checks passed.')
