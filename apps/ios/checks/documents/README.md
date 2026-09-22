# Chat document checks

Run `python3 apps/ios/checks/documents/check.py` from the repository root. This
extracts and compiles the actual file-import helper and media envelope, then checks
real file reads, filename/MIME preservation, unsafe filename sanitization, directory
and oversized-file rejection, missing files, old envelopes, and filename/key round trips.
It uses temporary files only. macOS file coordination requires access outside the
restricted tool sandbox. All 13 checks passed.

The document bubble and file helper also passed an isolated iOS SDK type check using
stubs for app services. Changed Swift files passed parsing. No app build or launch.

Implementation: Files picker (one file, up to 50 MiB), encrypted attachment pipeline,
optional filename inside the existing encrypted envelope, direct/group iOS decoding,
document bubbles, Quick Look preview/sharing, and the Shared Media Documents tab.
Preview files live inside the existing media cache, cleared at account sign-out.

Device checks remain: iCloud/third-party Files providers, direct and group exchange
between updated iOS clients, preview/share of PDF/Office/text/archive files, failed
upload/download, and reopening cached documents offline. Other platforms/older app
versions still need document UI and group-envelope compatibility verification; this
change implements the iOS client. No backend migration is required.
