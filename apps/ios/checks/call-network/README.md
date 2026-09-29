# call-network

Every case behind the call screen's "Your network is weak" warning — whose network is at
fault, today's real call measurements, and the no-flicker hold.

The logic lives in `Voiid/Networking/CallNetworkVerdict.swift`, which has no WebRTC or UI
dependency so it compiles on its own here, and the app uses the same file.

```
swiftc -o /tmp/cnc apps/ios/Voiid/Voiid/Networking/CallNetworkVerdict.swift \
       apps/ios/checks/call-network/main.swift && /tmp/cnc
```
