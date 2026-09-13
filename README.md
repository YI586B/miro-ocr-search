# Miro-ocr-search — releases

This branch holds the latest built disk image only. The source is on
[`main`](https://github.com/YI586B/miro-ocr-search/tree/main).

## Miro-ocr-search-1.2.dmg

| | |
|---|---|
| Version | 1.2 |
| Requires | macOS 13 Ventura or later, Apple Silicon |
| Size | 3.9M |
| SHA-256 | `3e01c6599af614de6fdd2741cf3674fe6ae149d10b80cb128f93273950964707` |

What's new since 1.1:

- Boxes are an outline by default: the fill starts at 0%, and the style panel's Fill opacity
  adds one.
- Where the app stands in Noto Sans for Apple's system font, the redrawn text is drawn heavier, so
  it matches the weight of the original more closely.

It is a search tool, not an image editor: it finds text in your images and shows where it is.
Images it outputs carry a Miro watermark, because the app uses Miro's libraries.

### Installing

1. Download the `.dmg` above and open it.
2. Drag **Miro-ocr-search** into **Applications**.
3. Clear the quarantine flag, then open it:

       xattr -dr com.apple.quarantine /Applications/Miro-ocr-search.app

Step 3 is needed because the app is ad-hoc signed rather than notarised — that requires a paid
Apple Developer account. Without it macOS refuses the first launch, reporting either that the
developer cannot be verified or that the app is damaged. Neither means the download is faulty.

Verify what you downloaded:

    shasum -a 256 ~/Downloads/Miro-ocr-search-1.2.dmg

Building from source avoids the quarantine entirely; see the
[guide](https://github.com/YI586B/miro-ocr-search/blob/main/GUIDE.md).
