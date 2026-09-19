# Carrom checks

Carrom was ported from Voiid UI into the main iOS app, then limited to bot play.
The top HUD assigns white to the player and black to the bot. Both sides clear
nine pieces; the queen must be covered by either side before a finish.

Validation in this change: Swift source parsing and asset/catalog checks only.
The app build attempt ended during dependency resolution; no app was launched.
At the user's request, no further app builds or runtime checks were performed.
The regression harness below is prepared but **not executed**.

The harness exercises the actual controller, physics, and bot source files;
`Support.swift` replaces only haptic output. Once running checks is desired, from
repository root:

```sh
xcrun -sdk macosx swiftc -module-cache-path /tmp/voiid-carrom-module-cache \
  apps/ios/checks/carrom/Support.swift \
  apps/ios/checks/carrom/CarromCheck.swift \
  apps/ios/Voiid/Voiid/Games/Carrom/CarromTheme.swift \
  apps/ios/Voiid/Voiid/Games/Carrom/CarromPhysics.swift \
  apps/ios/Voiid/Voiid/Games/Carrom/CarromEngine.swift \
  apps/ios/Voiid/Voiid/Games/Carrom/CarromGame.swift \
  apps/ios/Voiid/Voiid/Games/Snake/SnakeCore.swift \
  apps/ios/Voiid/Voiid/Games/Ludo/LudoTheme.swift \
  -o /tmp/voiid-carrom-check
/tmp/voiid-carrom-check
```

Device verification still needed: open Games → Carrom → Play vs Bot, check banner
crops and colour labels in light/dark mode and small/landscape layouts, aim and
strike, let the bot complete turns, restart during bot aiming, pause/background
mid-shot, check queen covering/fouls, then leave and confirm the tab bar returns.
