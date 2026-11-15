# StorageViewer

Bar: WizTree and WinDirStat interaction — rectangles proportional to bytes, click a folder to zoom, breadcrumb back, largest children with both percents, type color, selection shared by the list and the map — checked by child bytes summing to the parent and treemap area matching those bytes. Chrome uses the specified near-black tokens (canvas #0e0e0e, panel #161616, border #2a2a2a, text #ececec, secondary #8b8b8b, one cool blue).

The app is not sandboxed. A chosen folder is read with the user's normal permissions. Full Disk Access is not required. Sizes are logical bytes. Symlinks are not followed. Other volumes are not entered.

Round 1: scanner, treemap, and the SwiftUI shell are in the project. Tests are the measurement.

Verified: `swift test` passed (11). A live scan of this folder reported 230,000,816 bytes, matching an independent walk to the byte. `.build` is 228,893,871 bytes, shown as 218 MB and 99.5% in both the list and the treemap. Zoom, row selection, and the name filter were exercised in the running window. `/cursor/stores/self/media` is not on this Mac; the screenshot is `storageviewer-v1.png` in the project.

Scan speed, release build, warm cache: `/usr` (22,049 files, same 2,143,252,725 bytes) went from about 70 ms to about 38 ms. `~/Library/Application Support` (210,738 files) went from about 1.03 s to about 0.42 s. The walk uses `openat` plus `getattrlistbulk` on four workers.
