# Miro-ocr-search — releases

This branch holds the latest built disk image only. The source is on
[`main`](https://github.com/YI586B/miro-ocr-search/tree/main).

## Miro-ocr-search-1.4.dmg

| | |
|---|---|
| Version | 1.4 |
| Requires | macOS 13 Ventura or later, Apple Silicon |
| Size | 3.9M |
| SHA-256 | `f68dc8e31c4d989ca4e839d664ccfbbebb0c4e01f0f1e9f4566f6d607753bfaa` |

What's new since 1.3:

- The softness of each redrawn word's edges is matched to the original, both ways: a slightly
  blurred original gets a matching blur, a crisper one gets sharper edges. The style panel's
  Smoothness setting is now Edges (above 0 softer, below 0 crisper).
- Where the app draws Noto Sans in place of Apple's system font, edges are left as drawn.
- With Boxes and Text both on, the box now sits behind the redrawn word, so the text stays on top.

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

    shasum -a 256 ~/Downloads/Miro-ocr-search-1.4.dmg

Building from source avoids the quarantine entirely; see the
[guide](https://github.com/YI586B/miro-ocr-search/blob/main/GUIDE.md).
