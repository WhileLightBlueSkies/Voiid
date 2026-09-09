# iOS photo orientation on Android — 2026-09-09

Android chat image decoding used `BitmapFactory.decodeByteArray` on the decrypted bytes.
That displayed raw pixels without applying EXIF orientation, so iPhone photos could appear
rotated or mirrored. The same behavior affected disk-cached photos and shared-media tiles.

`ChatImageDecoder` uses Android's native ImageDecoder on API 28+ and an EXIF-aware fallback
on API 24–27. The fallback handles all eight rotation/mirror combinations. Every chat image
cache fill uses this decoder; shared-media previews now use the same resolver as chat and
the full-screen viewer. The original attachment bytes are retained, so existing cached
photos can be corrected when decoded again without retransmission.

The native behavior is also covered by Android's own
[ImageDecoder orientation tests](https://android.googlesource.com/platform/cts/+/1134144cdb49ef7350e5ffb2a24f930f188cf6b3/tests/tests/graphics/src/android/graphics/cts/ImageDecoderTest.java).

`ChatImageOrientationTest` generates JPEGs with distinct colored corners and each EXIF
orientation. It checks pixel positions and dimensions through the native and fallback
paths, then verifies that the cached photo and viewer resolve the same upright pixels.
Tests use only synthetic images and do not capture, transmit or inspect user photos.

Validation completed: Android debug and instrumentation builds passed; all 114 unit tests
passed. On the connected CPH2745, all three instrumentation tests passed: eight native
orientations, eight fallback orientations, and cached/viewer consistency. The fallback
code was exercised on the current phone, not separate Android 7/8 hardware. The corrected
app was installed and reopened; the temporary test package was removed afterward.
