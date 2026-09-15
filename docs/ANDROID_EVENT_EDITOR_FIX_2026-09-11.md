# Android event editor follow-up

Implemented saved draft/step state across configuration changes; explicit discard confirmation; per-step scroll reset and keyboard dismissal; keyboard-aware footer; clearer publish/draft/edit action labels; numeric capacity keyboard with range feedback; future start validation for new events; normalized initial minutes; readable date labels; system 24-hour time picker preference; and automatic end-time adjustment when the start moves past it. Submission busy state is set before launching the request to prevent rapid double taps.

Build passed. Existing Android regression suite run; updated APK replaces build/share/Voiid-Android-2026-09-11-latest.apk and passes signature verification. No device installation during the conference test. Interactive phone validation remains pending. Paid event setup remains unavailable.

## Concurrent API connection investigation

User reported both iOS and Android fail to connect to api-dev.voiid.app, on different networks, with “after 1500ms”. Current Android API connect timeout is 15 seconds; iOS request timeout is 20 seconds. No matching 1500 ms limit found in these clients. At investigation time public health returned HTTP 200, TLS verification passed, local API/DB/Redis and all PM2 processes were healthy. Public DNS resolvers agreed on 139.84.218.192, no AAAA record; HTTPS listened publicly and host firewall allowed 443. These checks do not establish phone reachability. User asked to open the health endpoint in a phone browser; result pending. No speculative timeout or TLS relaxation applied.

Server log capture started privately for a bounded 30-minute conference test. The discovered wireless Android was not the Voiid test phone; disconnected it and removed its diagnostic snapshot. No live Android Voiid logs or iPhone console stream captured yet.
