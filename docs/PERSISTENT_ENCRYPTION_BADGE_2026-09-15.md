# Encryption badge at the start of chat history

The centered encryption capsule is the first item in the transcript on iOS and Android, above the first date and message. It scrolls with the history and remains part of the transcript at every message count. Note to Self remains excluded. This supersedes the earlier fixed placement below the header.

The iOS transcript explicitly applies softTopEdgeEffect(), which selects the native soft top scroll edge on supported iOS versions. The capsule opens the existing direct security-number screen or group member verification picker. Direct chats use the resolved peer from ChatStore. Android retains its existing direct verification action; group verification picker parity remains separate outstanding work.

Android notification scroll-to-message indices and bottom-scroll targets include the leading badge item. Neither platform hides the badge after six messages.
