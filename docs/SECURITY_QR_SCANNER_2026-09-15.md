# Security QR scanning

Verify encryption now offers Scan QR code for each displayed device pair on iOS and Android. The action opens a camera scanner scoped to that pair's displayed safety number. It never routes scans into profile/community navigation.

Comparison requires exactly 60 ASCII digits and compares the entire code. Results distinguish match, mismatch, and invalid QR payload. Match wording is limited to the selected device pair and does not persist a verified identity state. Camera permission denial offers Settings and manual comparison; unavailable cameras retain manual comparison. Backgrounding stops scanning, and dismissal releases the existing camera preview.

The iOS sheet retains its soft top scroll edge. Android uses the existing CameraX scanner; iOS uses the existing AVFoundation scanner. No new camera dependency or QR wire-format change is needed.

Validation includes strict comparison cases on both platforms: exact match, differing last digit, incorrect length, unrelated URL, non-ASCII digits, trailing newline, and missing expected code. Physical cross-device camera scanning remains unverified because neither test phone was reachable.
