# Changelog

## 0.0.3-beta1 - 2026-08-23

- Routes download progress and completion through one terminal, session-scoped callback.
- Validates YouTube IDs, partial files, response lengths, writes, and the 24 MiB bridge limit.
- Splits command, status, and payload pasteboards with versioned tokens and cancellation acknowledgement.
- Polls for cancellation throughout the active Music import and does not persist abandoned bridge commands across a reboot.
- Constrains Music matching and placeholder cleanup to the TubePod album and read-only database results now report failures.
- Checks private API signatures centrally and records retry outcomes in the Music-side transaction ledger.
- Keeps the existing **Download Again** choice as an intentional duplicate instead of treating it as an automatic retry.

## 0.0.2-beta2 - 2026-08-23

- Removes old location-less TubePod placeholders when Music starts.
- Keeps checking for late StoreServices duplicates for several seconds after a successful import.
- Never removes the completed copy or an existing library item during this cleanup.
- Reloads MediaPlayer's library cache after deleting a placeholder so Music does not keep a dead row on screen.

Known issue: Music's existing playback queue can retain a deleted placeholder ID after the library is clean. The valid song plays when it is queued directly, but the stale queue item skips to the next track.

## 0.0.1 - 2026-08-23

First beta release. This is the first version confirmed to complete the full workflow on an iPod touch 4 running iOS 6.1.6.

- Adds **Save Audio** to the YouTube 1.4.0 action menu.
- Downloads direct media streams and resumes partial downloads.
- Extracts M4A audio from MP4 files when needed.
- Transfers the completed M4A to Music through a named pasteboard.
- Stages and validates the file inside the Music process before import.
- Imports through Apple's StoreServices using a local file URL.
- Repairs the sample rate, duration in samples, and bitrate required for playback.
- Removes new empty StoreServices placeholders after a failed or completed import.
- Cancels stale TubePod StoreServices jobs before starting another import.
- Keeps source and partial files when an operation fails.

The alpha13 build was the working development baseline for this release.
