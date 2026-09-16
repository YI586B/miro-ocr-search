# Miro-ocr-search — releases

This branch holds the latest built disk image only. The source is on
[`main`](https://github.com/YI586B/miro-ocr-search/tree/main).

## Miro-ocr-search-1.3.dmg

| | |
|---|---|
| Version | 1.3 (build 6) |
| Requires | macOS 12 Monterey or later, Apple Silicon |
| Size | 3.9M |
| SHA-256 | `1eb171d532e0b96b2714cf7e4812fb978c75d390858625797b0e5176df6b9b9f` |

What's new:

- Runs on macOS 12 Monterey as well as later versions.
- On macOS 12 the hover card is not shown, because macOS 12 cannot report where the pointer is
  over the image; ⌥⌘] and ⌥⌘[ still step through the matches with their card. The preview's
  Phrase / Any Word choice is a small toolbar menu there.
- On macOS 13 and later everything works as in the previous build.

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

    shasum -a 256 ~/Downloads/Miro-ocr-search-1.3.dmg

Building from source avoids the quarantine entirely; see the
[guide](https://github.com/YI586B/miro-ocr-search/blob/main/GUIDE.md).
