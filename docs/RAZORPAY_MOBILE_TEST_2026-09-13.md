# Razorpay mobile checkout test

Implemented in the real Voiid apps, not the UI prototype.

- iOS: Razorpay Checkout 1.5.8, Voiid booking summary and themed native checkout.
- Android: Razorpay Checkout 1.6.40, matching booking flow and internal checkout activity.
- The backend creates the order and determines the price. A mobile success callback is only a hint to refresh; only the backend's paid status confirms the booking.
- Reopening a pending order returns checkout details for that same provider order. It does not create a second order.
- Test credentials remain on the backend. Only the publishable key ID and checkout order details reach the apps.

## Test listing

- Community: DBoss Shed
- Event: `[TEST] Razorpay checkout — ₹1`
- Event ID: `c7290a71-0505-4a64-a1d9-9035e4624026`
- Price: INR 100 minor units per person; capacity 10.
- This is a sandbox listing, not a real event. Razorpay test mode is configured.

## Verification completed

- iOS device build passed, including the Razorpay frameworks.
- Android debug APK build and APK signature verification passed.
- Backend TypeScript build passed locally and on the server.
- All 12 Razorpay verification/resume tests passed.
- API restarted; health returned HTTP 200. An unsigned Razorpay webhook returned HTTP 400.

## Device acceptance test still required

1. Sign in as a member rather than the event host/manager.
2. Open DBoss Shed, then the test event. Select the number of people and continue to payment.
3. Use Razorpay sandbox payment details. Confirm that a verified payment produces one group ticket with the correct headcount.
4. Cancel checkout and reopen it. Check that the existing order is reused.
5. Test a declined payment, delayed webhook and network interruption. A pending payment must never display a confirmed ticket.

No device payment has yet been confirmed in this implementation session. Build and unit-test success do not establish end-to-end payment success. Organizer settlements through Razorpay Route remain dependent on Route activation. Razorpay/bank branding can still appear within Standard Checkout.

Android share file: `build/share/Voiid-Android-2026-09-11-latest.apk` (refreshed September 13).
