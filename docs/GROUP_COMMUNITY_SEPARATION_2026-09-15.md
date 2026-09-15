# Group and community list separation

Both mobile chat stores now classify conversations against active community channel membership from the existing community APIs. The Groups tab reads an account-scoped persisted set of confirmed standalone group IDs. Successful refresh replaces this set, removing deleted groups from the list without deleting local transcripts. Unclassified legacy groups stay hidden until the first successful refresh. Failed classification preserves the last confirmed list. Pending community applications do not trigger member-only channel requests.

Community channel conversations remain available internally for encrypted sends, incoming messages, and MLS events, while their navigation belongs to Communities. New standalone groups are immediately added to the persisted list; groups created during a refresh survive its older snapshot. Concurrent refresh callers wait for reconciliation before looking up an incoming conversation. A response at the 200-community cap is rejected rather than used to misclassify channels.

Validation: iOS device build passed. Android assembleDebug and 16 focused unit tests passed (5 group-list membership tests and 11 community wire-format tests). The fixture runner compiles the actual iOS reconciliation methods extracted from Stores.swift and checks ten channels plus four stale groups, transcript retention, pending applications, failed refresh, offline restart, concurrent creation, an empty server snapshot, internal channel availability, capped community responses, and concurrent refresh waiters:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer CLANG_MODULE_CACHE_PATH=/tmp/voiid-group-check-cache python3 apps/ios/checks/group-list/check.py
```

No production API deployment or data deletion is part of this change. The existing communities/mine endpoint is capped at 200 communities; those responses now preserve the last confirmed list and fail the refresh. An explicit conversation scope in the server payload is a future requirement to refresh accounts at that limit. Live two-account community messaging was not exercised by the fixture test.

Final artifacts and validation logs are saved under `build/share/group-community-ready/`. Neither final artifact was installed on hardware during this preparation pass.
