<p align="center">
  <img src="assets/tubepod-icon.png" width="220" alt="TubePod icon">
</p>

# TubePod

TubePod brings audio from the classic YouTube app into the Music app on iOS 6. Open a video, tap **Save Audio**, and let TubePod handle the rest.

## Dependencies

- A jailbroken armv7 device running iOS 6.0–6.1.6
- MobileSubstrate
- YouTube 1.4.0 (`com.google.ios.youtube`)
- A way to install a `.deb`, such as iFile or OpenSSH

## Installation

There is no Cydia repository yet. For now, download the latest `.deb` directly from [Releases](https://github.com/pruefsumme/TubePod/releases) and install it with iFile or as root over SSH:

```sh
dpkg -i /path/to/TubePod.deb
killall YouTube 2>/dev/null || true
```

Open YouTube, choose a video, tap the share-style action button, and select **Save Audio**. Keep YouTube open while it downloads, then stay in Music until the import finishes.

## Building

Building requires Theos and the official iOS 6.1 SDK from Xcode 4.6.3.

```sh
make package FINALPACKAGE=1
```

## Notes

TubePod is made for YouTube 1.4.0 and iOS 6. Other versions are not supported yet. If Music skips a newly added song, select it again or rebuild the current Music queue.

The development notes and device findings are in [docs/technical-notes.md](docs/technical-notes.md).

Only download audio you own or have permission to save.

## License

TubePod is licensed under GPL-3.0. See [LICENSE](LICENSE).
