"""Exercise the shipped v6 schema plus the actual v7 migration and retention queries."""
from pathlib import Path
import json
import re
import sqlite3

root = Path(__file__).resolve().parents[2]
schema = json.loads((root / 'app/schemas/com.voiid.app.store.VoiidDatabase/6.json').read_text())
entity = next(e for e in schema['database']['entities'] if e['tableName'] == 'stories')
db = sqlite3.connect(':memory:')
db.execute(entity['createSql'].replace('${TABLE_NAME}', 'stories'))
source = (root / 'app/src/main/java/com/voiid/app/store/StoryRows.kt').read_text()
migration = (root / 'app/src/main/java/com/voiid/app/store/KeptMomentMigration.kt').read_text()
db.execute(re.search(r'db.execSQL\("([^"]+)"\)', migration).group(1))

def query(method):
    return re.search(r'@Query\("([^"]+)"\)\s+abstract fun '+method+r'\(', source).group(1)

def insert(id, mine, owner, expires):
    db.execute('INSERT INTO stories(id,author_id,is_mine,created_at,expires_at,media_json,caption,allows_replies,download_state,upload_state) VALUES(?,?,?,1,?,? ,?,1,?,?)',
               (id, owner, mine, expires, '{}', '', 'ready', 'sent'))

insert('own',1,'me',100)
insert('unkept',1,'me',100)
insert('other',0,'friend',100)
insert('active',1,'me',1000)
assert db.execute('SELECT kept FROM stories WHERE id="own"').fetchone()[0] == 0
assert db.execute(query('keep'), {'id':'other','owner':'me','path':'private'}).rowcount == 0
assert db.execute(query('keep'), {'id':'own','owner':'wrong-account','path':'private'}).rowcount == 0
assert db.execute(query('keep'), {'id':'own','owner':'me','path':'private'}).rowcount == 1
assert len(db.execute(query('kept'), {'owner':'me','nowSeconds':200}).fetchall()) == 1
assert db.execute(query('kept'), {'owner':'friend','nowSeconds':200}).fetchall() == []
db.execute(query('setDownload'), {'id':'own','path':None,'state':'failed'})
assert db.execute('SELECT local_path FROM stories WHERE id="own"').fetchone()[0] == 'private'
db.execute(query('deleteExpired'), {'nowSeconds':200})
assert set(r[0] for r in db.execute('SELECT id FROM stories')) == {'own','active'}
db.execute('UPDATE stories SET is_mine=0 WHERE id="own"')
db.execute(query('deleteExpired'), {'nowSeconds':200})
assert db.execute('SELECT id FROM stories').fetchall() == [('active',)]
assert db.execute(query('kept'), {'owner':'me','nowSeconds':200}).fetchall() == []
print('10 archive migration, ownership, expiry and late-download checks passed.')
