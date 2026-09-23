Run `python3 apps/android/checks/location/run.py` from the repository root.

Uses cached Kotlin 2.0.21 and serialization dependencies to compile the real wire models into a temporary directory. Does not build, install, or launch an Android app.

Covers waiting versus ended states with and without a fix, exact expiry/freshness boundaries, explicit stopping, iOS coordinate-free starts, fractional epoch timestamps, and large sequence numbers. These checks do not exercise GPS, Android permissions, foreground-service delivery, map rendering, or network transport; those still need two-device testing.
