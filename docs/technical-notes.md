# TubePod technical notes

This file records what we learned from testing TubePod on real hardware. Keep it updated when the import path changes. Alpha13 was the first build to complete the whole cycle and produce a playable song without manual repair.

## Supported setup

TubePod currently targets one narrow setup:

- iPod touch 4 with iOS 6.0 through 6.1.6
- armv7
- a rootful jailbreak with MobileSubstrate
- YouTube 1.4.0 with bundle ID `com.google.ios.youtube`
- the iOS Music app with bundle ID `com.apple.mobileipod`

Do not assume that private APIs behave the same on another iOS release. Selector-check private calls and fail with a useful message when an API is missing.

The build uses Theos, the official Apple iOS 6.1 SDK from Xcode 4.6.3, and Apple's system frameworks. Do not add downloaded private framework binaries or random patched libraries to the project. StoreServices and MusicLibrary are loaded from the device at runtime.

## How the feature is attached

`Sources/Tweak.xm` hooks `UIActionSheet showInView:` inside YouTube. It adds **Save Audio** to the action sheet used by the video action controller. The visible action button is the share-style arrow over the video.

Do not add the button to every action sheet. Check the delegate and make sure the current object exposes a usable video ID and stream first. Forward all normal button actions to YouTube's original delegate.

YouTube 1.4.0 normally exposes old `YTStream` objects. These often contain a URL and numeric format instead of a modern MIME type. TubePod supports both shapes. It only accepts direct HTTPS media URLs already supplied by the app. It has no signature solver, YouTube API client, manifest assembler, backend, or DRM bypass.

## Download and conversion path

`Sources/TPDownloader.m` owns the download in the YouTube process.

Files live in YouTube's `Documents/TubePod` directory. A running download uses `<video ID>.part`. HTTP range requests allow a partial download to resume. If the server ignores the range and sends a complete response, the old partial file is truncated first.

Redirects must stay on HTTPS. Accept only audio, MP4, or an octet-stream response that came from the selected media URL. A 403 normally means the temporary stream URL expired. The user should reopen the video and retry.

The initial free-space check requires 20 MB. This is a safety margin, not the expected song size. Once the response size is known, the downloader checks the required bytes again and keeps another 5 MB free.

An audio-only MP4 stream can be renamed to `.m4a`. A combined video stream must first be renamed from `.part` to `.mp4`, then passed through `AVAssetExportSession` with `AVAssetExportPresetAppleM4A`. On iOS 6, AVFoundation uses the filename extension when detecting a local container. Passing a complete MP4 to AVFoundation while it still has a `.part` extension can falsely report that it has no audio track.

Keep partial files and converted M4A files when an operation fails. Delete the YouTube-side M4A only after Music confirms a complete and repaired import. `state.plist` records download state by video ID.

## Cover artwork

TubePod asks YouTube's image host for `maxresdefault.jpg` after the audio is ready. It falls back to `hqdefault.jpg` when the larger image is missing or too small. The image is center-cropped to a 600 by 600 square and saved as a JPEG no larger than 512 KiB. This matches the square album-cover shape used by Music. The cached JPEG stays beside the retained M4A after a failed import and is removed after a confirmed success.

Artwork is optional. A thumbnail or artwork error must never reject an otherwise playable song. The Music process uses `AVAssetExportPresetPassthrough` to add `AVMetadataCommonKeyArtwork`, then checks that the exported file still has audio and readable artwork metadata. If that check fails, it deletes the tagged attempt and imports the original staged M4A.

Embedded M4A artwork is not enough on iOS 6. StoreServices preserves the `covr` atom but does not populate Music's separate artwork cache. After the completed track is found and its audio fields are repaired, call `ML3Track populateArtworkCacheWithArtworkData:` through the checked private-API facade. Then notify MusicLibrary and reload MediaPlayer's library cache. The Ogdens' Nut Gone Flake device test proved this path: the purchase file kept its 181,552-byte cover and Music created two `artwork_info` formats only after the cache method ran. Do not write `artwork_info` or the artwork files directly.

All tracks still use the album name `TubePod`. This keeps duplicate cleanup and ownership checks safe. Music may show one representative image for the whole TubePod album even though each track has its own embedded cover. Giving every track a separate visible album requires replacing the album-name ownership marker first.

## Moving the file into Music

The import crosses two processes. YouTube does not have the private entitlement needed to complete a StoreServices music import. The Music app does.

The working flow is:

1. YouTube reads the completed M4A, writes it to the owned payload channel, and writes a versioned request with a token and optional square artwork to the owned command channel.
2. YouTube opens the Music app and keeps a background task alive.
3. The TubePod code loaded inside Music validates the request, token, protocol version, and exact media length.
4. The Music process writes the payload into `/var/mobile/Media/TubePod`, checks it with AVFoundation, optionally adds the artwork with a passthrough export, and clears the payload channel immediately after validation.
5. Music gives the local `file://` URL and song metadata to Apple's StoreServices classes.
6. StoreServices copies the file into `/var/mobile/Media/Purchases` and creates the Music library entry.
7. TubePod repairs the missing audio fields and registers any embedded cover in Music's artwork cache through MusicLibrary.
8. Music publishes processing, cancellation, success, or error on the separate status channel. Only then does YouTube report success.

Repeated commands for a token are idempotent. YouTube publishes a cancel command when its timeout or background task expires. Music cancels StoreServices and removes only new empty TubePod placeholders until a repaired playable record has been committed; a committed success wins over a late cancel.

Bridge pasteboards are not persistent across a reboot. Music polls the command channel while an import is active, so it can see cancellation without waiting for another app activation. A normal retry uses the Music-side ledger to return an already completed result. Choosing **Download Again** explicitly bypasses that retry shortcut and permits another copy.

Once the file is downloaded, the YouTube alert must change from a percentage to **Adding to Music**. It must not keep showing 0%, and it must not offer Cancel during the Music phase. Music shows its own progress alert and tells the user to stay there until the final Saved or Error message. The Music process also holds a background task so a quick app switch does not immediately suspend the import.

The request contains a random token, protocol version, validated video ID, expected media length, and optional artwork. Music must reject missing, stale, incomplete, or oversized data. The converted M4A is limited to 24 MiB and is checked against the filesystem both before and after loading. Artwork is limited to 512 KiB.

StoreServices completion is detected by watching its download queue. A download must first be observed in the queue and then disappear from it. Check `failureError` while polling. A disappearing queue item is not the final success condition. The Music database repair must also succeed.

StoreServices keeps its queue across Music app launches. Removing a bad Music database row does not cancel the matching queue job. Before a new import, cancel old downloads whose collection metadata is exactly `TubePod`. If the current import fails or times out, cancel its StoreServices download before releasing the queue. Otherwise an orphaned job can block later songs.

Do not give a loopback HTTP URL directly to StoreServices. Testing showed that StoreServices creates a placeholder for it but never makes the HTTP request. A separate attempt to make Music fetch from a live YouTube loopback server also failed because iOS suspended or isolated the listener during the app switch. The log contained only the listening line and no request. StoreServices does start correctly with a local `file://` URL. The named pasteboard removes the live-process timing dependency.

## Failed approaches that must stay retired

Do not restore one of these paths without new device evidence:

- Direct `ML3TrackImporter`: it can report success while creating only a stray `item_stats` row. `importationEnabled` is disabled on iOS 6.1.6.
- StoreServices with an HTTP loopback URL: it creates a visible placeholder but never requests the file.
- Music fetching from a live YouTube loopback server: the app switch suspends or isolates the listener. Music reports that the network connection was interrupted.
- Treating a visible song title as success: StoreServices creates the title before it has a usable file.
- Treating queue removal as final success: the copied track still needs its audio fields repaired and verified.
- Setting only the millisecond duration: Music also needs sample rate, duration in samples, and bitrate.
- Deleting every row with the same title: repeated songs and existing library items make title-only deletion unsafe.

The alpha13 handoff is the baseline: put the completed M4A and request on the named pasteboard, let Music write and validate its staging file, then give StoreServices a local file URL. Keep this order unless a replacement has completed the same real-device playback test.

## The silent-track bug

StoreServices accepts these local M4A files and copies them without changing their bytes. The files themselves are valid. `AVAudioPlayer` and AVFoundation can read them on the iPod.

The problem is the Music database record. StoreServices fills the visible duration in milliseconds but leaves these `item_extra` fields at zero:

- sample rate
- duration in audio samples
- bitrate

This creates a track that can show a normal length while playing no sound or ending immediately. One bad entry can also upset Music's playback queue and make good songs stop playing until the bad entry is removed.

After StoreServices finishes, `Sources/TPImporter.m` finds the new completed track and reads its copied file with AVFoundation. It then sets:

- `ML3TrackPropertySampleRate`
- `ML3TrackPropertyDurationInSamples`
- `ML3TrackPropertyBitRate`

The duration value is a sample count, not milliseconds. Convert the asset duration to the detected sample-rate timescale with `CMTimeConvertScale`. Store bitrate in kilobits per second. Call `updateIntegrity`, notify the shared library that its contents changed, and report success only if every write succeeds.

Known working examples were 44,100 Hz, 36,864 samples, and 118 kbps for a short system tone, and 44,100 Hz, 13,632,512 samples, and 128 kbps for the five-minute TubePod probe.

Do not use `ML3TrackImporter` as a replacement for StoreServices on iOS 6.1.6. `ML3MusicLibrary importationEnabled` is disabled on this build. The direct importer can return a success-looking persistent ID while creating only a stray `item_stats` row and no playable track.

Do not write the Music SQLite database directly. TubePod opens it read-only to identify the new StoreServices record. All changes go through `ML3Track setValue:forProperty:`, `updateIntegrity`, and `deleteFromLibrary`.

## Duplicate and broken records

StoreServices may create two records for one local import:

- a completed record with a location under `Purchases` and `is_downloading=0`
- an empty placeholder with no location and `is_downloading=1`

Before an import starts, remember every existing persistent ID with the same title. After completion, only consider new IDs. Repair the new completed record, then remove only the new empty duplicate through `ML3Track deleteFromLibrary`.

StoreServices can create or recreate the empty duplicate after the completed track has already been repaired. One immediate cleanup query is not enough. Keep polling for several seconds after repair and require consecutive clean checks before reporting success. Also remove old rows only when all three facts are true: the album is `TubePod`, the location is empty, and `is_downloading=1`.

Music can keep a deleted placeholder in its on-screen song list. Tapping that stale row jumps straight to the next real song. This does not mean the next song or the remaining file-backed copy is corrupt. Re-read the database first. After deletion, call MediaPlayer's contents-change reload and post `MPMediaLibraryDidChangeNotification`. If only completed records remain but the row is still visible, restart `Music~iphone` to refresh the view.

The playback queue is a separate cache. It can keep the deleted placeholder's persistent ID even after the database is clean, the library is reloaded, and Music is restarted. Selecting that dead queue item makes Music skip to the next song. The Shotgun test proved this: SQLite contained one valid record, AVAudioPlayer decoded its purchase file, and MediaPlayer resolved the correct asset URL. Explicitly queueing the valid persistent ID with `MPMusicPlayerController` played the song and advanced its playback time.

Do not reimport or rewrite a song after that result. The file and repaired track are good. Replace or rebuild the playback queue. A library-change notification alone is not a complete queue reset.

If the current import fails or times out, remove any new empty placeholder created by that attempt. Do not remove placeholders that existed before the attempt. This cleanup uses the same pre-import persistent ID set.

Never delete records only because their titles match. Never delete a source M4A while diagnosing an old import. First prove that the target record has no location and is still marked as downloading. Pentagon and Portal Radio Tune from older builds were confirmed to be empty placeholders with all audio fields at zero. Removing those placeholder rows fixed the dangerous queue entries while preserving their TubePod source files.

Old completed tracks with a real file location can usually be repaired. Read the file with AVFoundation and fill the three missing fields. An old record with no file location cannot be repaired; remove only that record and import the preserved M4A again.

## Source layout

- `Sources/Tweak.xm` is the YouTube integration/UI area: it finds video metadata, adds the action-sheet button, and owns user-facing alerts and session routing.
- `Sources/TPDownloader.h/.m` is the download pipeline: it downloads, resumes, validates, converts, and preserves files on failure.
- `Sources/TPBridge.h/.m` is the shared bridge protocol: typed command/status messages, ownership, validation, serialization, tokens, and size limits.
- `Sources/TPImporter.h/.m` is the Music import pipeline: staging, transaction orchestration, cancellation, repair, cleanup, and the atomic retry ledger.
- `Sources/TPPrivateAPI.h/.m` and `Sources/TPMusicDatabase.h/.m` contain checked StoreServices, MusicLibrary, MediaPlayer calls, and read-only SQLite queries.
- The loopback server experiment is deliberately excluded from the repository. Its failure is documented above so it is not accidentally rebuilt.
- `TubePod.plist` limits MobileSubstrate injection to YouTube and Music.

Keep UI work on the main thread. Run network and file transfer work away from it. There must be only one active TubePod download and one active Music import at a time.

## Build and install

The deployment target must remain iOS 6.0 and the architecture must remain armv7 unless support is deliberately expanded.

```sh
make clean package FINALPACKAGE=1
```

Check the resulting dylib for `LC_VERSION_MIN_IPHONEOS 6.0` before installing it. Install the rootful package with `dpkg -i`, then restart both YouTube and `Music~iphone`.

Version `0.0.1` was the first beta release and the first build confirmed to complete the full download, handoff, StoreServices import, metadata repair, and playback cycle. `0.0.2~beta2` added delayed placeholder cleanup and refreshed MediaPlayer's current library cache. The prepared hardening package is `0.0.3~beta1`, adding session routing, the owned three-channel bridge, checked runtime signatures, album-constrained queries, the 24 MiB limit, and persistent retry idempotency. Device acceptance still requires the complete regression below. Alpha9 added the post-import MusicLibrary repair. Alpha10 added clear download/import phases, background time, and placeholder cleanup. Alpha11 added StoreServices queue cancellation and local handoff logging. Alpha12 proved that the live loopback handoff was unreliable. Alpha13 introduced the working named-pasteboard handoff. Alpha8's direct MusicLibrary importer experiment must not be restored.

The first `0.0.3~beta1` device regression completed on 2026-08-23. A fresh download of “Revenge” imported as one completed record with a purchase-file location, 44,100 Hz sample rate, 11,665,408 audio samples, and 128 kbps bitrate. The TubePod placeholder count was zero. Playback from the start, seeking, and playing another known-good song afterward all worked.

## Real-device regression check

A build is not proven by a successful compilation, a StoreServices acceptance result, or a title appearing in Music. Test this whole sequence on the iPod:

1. Start with a song that is not already in Music.
2. Use **Save Audio** and confirm that the percentage changes to **Adding to Music**.
3. Stay in Music until TubePod shows its final Saved message.
4. Confirm that exactly one completed song exists and no empty duplicate remains.
5. Play from the start and seek into the middle.
6. Confirm that sound plays and the track does not close immediately.
7. Confirm that the square cover appears in Now Playing. Check the album view too, but remember that Music may choose one image for the shared TubePod album.
8. Play a different known-good song afterward. This catches a malformed entry that poisons Music's playback queue.
9. Repeat once with an already-downloaded M4A to cover the no-download path.
10. If a song skips but has one valid database row, test its persistent ID through `MPMusicPlayerController`. Playback there means the remaining bug is the Music app's saved queue.

If a test fails, preserve the source M4A. Check whether the record has a real location before changing or deleting anything.

Use TubePod only for audio the user owns or has permission to download. Do not add tracking, a remote service, credentials, or unrelated network traffic.
