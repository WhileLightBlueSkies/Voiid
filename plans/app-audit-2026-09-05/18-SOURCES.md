# 18 — Official references verified during the audit

Checked 2026-09-05. Repository facts come from the cited source paths; these references support platform/API constraints and verification methods. Recheck dependency versions and release-specific behavior at implementation time.

- [Apple: Applying Liquid Glass to custom views](https://developer.apple.com/documentation/SwiftUI/Applying-Liquid-Glass-to-custom-views) — native glass modifiers, interaction, grouping/container rendering. Supports G01's iOS implementation direction.
- [Android: AGSL](https://developer.android.com/develop/ui/views/graphics/agsl) — RuntimeShader/AGSL availability on Android 13 and later. Supports G01's API 33 tier.
- [Android: RenderEffect](https://developer.android.com/reference/android/graphics/RenderEffect) — API 31 effects, API 33 runtime shader effects, and the content layer supplied as shader input. Supports the distinction between content blur and a deliberately captured backdrop.
- [Android: GraphicsLayer](https://developer.android.com/reference/kotlin/androidx/compose/ui/graphics/layer/GraphicsLayer) — recorded layer/effect behavior. Validate exact available Compose APIs against the project's pinned version before implementation.
- [Android: Java API desugaring](https://developer.android.com/studio/write/java8-support) — compatibility setup for newer library APIs on older Android releases. Supports A03.
- [Android: Macrobenchmark metrics](https://developer.android.com/topic/performance/benchmarking/macrobenchmark-metrics) — startup and frame timing measurement. Supports part 16's methodology, not its project-specific numerical targets.
- [PostgreSQL: Transaction isolation](https://www.postgresql.org/docs/current/transaction-iso.html) — statement snapshots and concurrent transaction behavior. Supports R05's need for explicit serialization of a cross-row capacity invariant.
- [Express: Error handling](https://expressjs.com/en/guide/error-handling/) — asynchronous error forwarding and version-specific behavior. Supports P03's Express 4 audit.

The glass calibration parameters and performance gates are proposed engineering targets derived for this product. They are not Apple's private material constants or externally certified industry thresholds. No third-party library recommendation is required to execute the initial renderer proof; evaluate any new dependency against actual compatibility, maintenance, license and benchmark evidence first.
