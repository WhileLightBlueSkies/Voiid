# Kept moments checks

Run `python3 apps/android/checks/story-archive/store_check.py` from the repository root.

The check loads the committed Room v6 stories schema, applies the actual v7 migration,
then exercises the actual DAO queries. It covers default expiry, ownership/account guards,
author-only retention, hiding active stories from the archive, and preventing late downloads
from replacing a retained file path. It does not replace an Android migration/device test.

On a device, post your own image and video, tap **Keep** while viewing, and verify that
they appear in **Moments → Archive** after expiry. Other people's moments must still
expire. Confirm deletion and sign-out remove the retained local copies. Retained files live
under `noBackupFilesDir/kept-moments`; keeping does not extend server or recipient expiry.
