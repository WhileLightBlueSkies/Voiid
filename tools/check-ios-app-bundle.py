#!/usr/bin/env python3
"""Check required Firebase startup resources in an actual built app, without printing credentials."""
import argparse
from pathlib import Path
import plistlib

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('app', type=Path, help='Built Voiid.app directory')
args = parser.parse_args()
try:
    with (args.app / 'Info.plist').open('rb') as stream:
        info = plistlib.load(stream)
    with (args.app / 'GoogleService-Info.plist').open('rb') as stream:
        firebase = plistlib.load(stream)
except (OSError, plistlib.InvalidFileException) as error:
    parser.exit(1, f'App cannot be installed: required startup plist missing or unreadable ({type(error).__name__}).\n')
if not info.get('CFBundleIdentifier') or firebase.get('BUNDLE_ID') != info['CFBundleIdentifier']:
    parser.exit(1, 'App cannot be installed: Firebase configuration does not match the app bundle.\n')
if not all(isinstance(firebase.get(key), str) and firebase[key].strip() for key in ('GOOGLE_APP_ID', 'API_KEY', 'PROJECT_ID', 'GCM_SENDER_ID')):
    parser.exit(1, 'App cannot be installed: Firebase configuration is incomplete.\n')
print('iOS app startup resources: Firebase configuration present and matches the app bundle.')
