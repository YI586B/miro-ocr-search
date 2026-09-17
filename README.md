# Miro-ocr-search — releases

This branch holds the latest built disk image only. The source is on
[`main`](https://github.com/YI586B/miro-ocr-search/tree/main).

## Miro-ocr-search-1.3.2.dmg

| | |
|---|---|
| Version | 1.3.2 (build 7) |
| Requires | macOS 12 Monterey or later, Apple Silicon |
| Size | 4.0M |
| SHA-256 | `9dd0e4b98a1a5c727a96b16a51a660f1b9dd48ff418a53965807036f0af071cf` |

What's new:

- The style panel and Settings are laid out the same way, in two sections: **Text Highlight**
  and **Box Highlight**, each with a switch to turn it on or off. A section that is off stays in
  place, dimmed.
- Every automatic setting, text colour and background included, has the same **Auto** button.
- Weight is Auto, Regular or Bold; Edges is a slider from Crisper to Softer.
- The top of the panel shows whether the image follows the defaults or has its own look.
- Runs on macOS 12 Monterey as well as later versions (no hover card on macOS 12).

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

    shasum -a 256 ~/Downloads/Miro-ocr-search-1.3.2.dmg

Building from source avoids the quarantine entirely; see the
[guide](https://github.com/YI586B/miro-ocr-search/blob/main/GUIDE.md).
