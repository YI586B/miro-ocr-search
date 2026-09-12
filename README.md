# Miro-ocr-search — releases

This branch holds built disk images only. The source is on
[`main`](https://github.com/YI586B/miro-ocr-search/tree/main).

## Miro-ocr-search-1.1.dmg (latest)

| | |
|---|---|
| Version | 1.1 |
| Requires | macOS 13 Ventura or later, Apple Silicon |
| Size | 3.9M |
| SHA-256 | `8bcaf8dba1f47124d3154b112202f5d8d16799626cfb4389134a84a525657424` |

What's new:

- Boxes and Text are two separate switches, both on by default, also in the View menu.
- The preview window has its own search field, menu-bar commands, pinch zoom and a style panel
  beside the image.
- Font detection compares letter shapes and recognises SF text reliably; each image is read once.
- The watermark scales with the image, 20px from the right and bottom.
- The watermark artwork and the Noto Sans font now ship inside the app.

## Miro-ocr-search-1.0.dmg

| | |
|---|---|
| Version | 1.0 |
| Requires | macOS 13 Ventura or later, Apple Silicon |
| Size | 1.1M |
| SHA-256 | `805ea957807c5ce9275ec47519aec461fbf26a68c0fd557f86e536550bf82d58` |

### Installing

1. Download the `.dmg` above and open it.
2. Drag **Miro-ocr-search** into **Applications**.
3. Clear the quarantine flag, then open it:

       xattr -dr com.apple.quarantine /Applications/Miro-ocr-search.app

Step 3 is needed because the app is ad-hoc signed rather than notarised — that requires a paid
Apple Developer account. Without it macOS refuses the first launch, reporting either that the
developer cannot be verified or that the app is damaged. Neither means the download is faulty.

Verify what you downloaded:

    shasum -a 256 ~/Downloads/Miro-ocr-search-1.1.dmg

Building from source avoids the quarantine entirely; see the
[guide](https://github.com/YI586B/miro-ocr-search/blob/main/GUIDE.md).
