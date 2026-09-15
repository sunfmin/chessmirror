# The library is a folder in iCloud Drive

The games directory is the app's iCloud ubiquity container's `Documents` folder, published to
the Files app as 棋镜, with the local `Documents/Games` folder kept as the fallback for a device
with no iCloud account and as the folder the app lists at launch before iCloud has answered.
Games saved before there was an iCloud are moved up into it once, on the first launch that finds
one. The one setting the app has — 音效 — travels separately, in `NSUbiquitousKeyValueStore`.

This follows from PGN files being the storage format (docs/adr/0010): a library that is a
directory of text files is a library that syncs by being put in a directory that syncs. CloudKit
was the alternative, rejected because it would make records a second representation of a Game
reachable only through a conversion layer — the same reason SwiftData was rejected in 0010 — and
because nothing about it is readable from the Files app.

Conflicts are resolved by last writer wins. Two devices moving in the same game within the same
seconds is the only way to lose a move, and conflict versions plus a UI to reconcile them is a
great deal of machinery for one person drilling puzzles.

## Consequences

- A file in the library is a name before it is bytes. Anything that reads one has to be able to
  answer "not here yet" — `GameFolder.isHere` — rather than "unreadable", and to ask for it.
- A game that has not arrived is listed but cannot be opened, renamed or filed. Opening one
  would give an empty board wearing a real game's file name, and the autosave after the first
  move would write it over the game that was on its way.
- Reads and writes go through `NSFileCoordinator` when the folder is iCloud's, so that a file
  being written by the sync daemon is never read halfway through. A coordinated read of a file
  that has not arrived blocks until it does, so a read is only ever attempted on a file this
  device already has.
- Finding the container blocks on the account, so it happens off the main thread and after the
  first listing: the app opens on the local folder and swaps under itself. Everything above
  `GameFolder` sees one directory that occasionally changes.
- The photograph filed beside a recognised game goes to iCloud with it, so the camera and photo
  library usage strings can no longer say 不会上传. They say where the pictures go instead.
- `NSUbiquitousContainers` in the Info.plist is read by iOS once, when the container is first
  created. Renaming the folder shown in the Files app needs `CFBundleVersion` to go up.
- The app now has an entitlement that names a container, so the container has to exist in the
  developer account before a build can be signed for a device.
