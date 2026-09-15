# Earnings refresh handling

The user reported repeated refresh errors without yet confirming platform/error text. Inspection found iOS discarded successful data before each refresh, allowed overlapping loads, and displayed cancelled URLSession/Swift tasks as connection/access errors.

Changes:
- iOS allows one in-flight load, ignores cancellation, preserves successful data on transient failures, and identifies rate-limit/auth/owner errors. Lost owner access clears displayed data.
- Android preserves data during reload, disables refresh while loading, supports explicit refresh and identifies HTTP access/rate errors. Earnings state is keyed to community ID and cancellation is rethrown.
- Both clarify bank setup is pending organiser onboarding integration. Route activation alone does not implement the onboarding screens/APIs. Do not assume Route supports UPI-ID payouts.

Validation: iOS build and Firebase bundle verification passed; Android build and 138 unit tests passed. Actual repeated refresh reproduction still needs user verification. Android disconnected before installation; APK is build/share/Voiid-Android-2026-09-11-earnings-refresh.apk.
