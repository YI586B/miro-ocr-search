# Miro-ocr-search — releases

This branch holds the latest built disk image only. The source is on
[`main`](https://github.com/YI586B/miro-ocr-search/tree/main).

## Miro-ocr-search-1.3.2.dmg

| | |
|---|---|
| Version | 1.3.2 (build 8) |
| Requires | macOS 12 Monterey or later, Apple Silicon |
| Size | 4.0M |
| SHA-256 | `5e76a2273ba90e62319fe69fef4f731a6ae79e87a91584e1ffa41d1866d00660` |

What's new in build 8:

- **Export size** (Settings ▸ Export): exported images can be made larger for larger displays —
  100%, 112.4% (the default), 124.8%, 150.6% or a custom percentage. The highlights are drawn at
  the new size so they stay sharp; the watermark stays the same size. The save panels and Miro
  sheet show the size.
- **Move the image**: click and drag in the preview to move an image within its frame. The space
  it leaves is black, the highlights move with it, and the position is saved for that image and
  used in its exports. Reset ▸ Position puts it back.
- Exporting a folder of images or to Miro now uses each image's own look, as its preview shows it.
- Font matching is on by default, the default box colour is red, and the preview window opens
  wide enough for all its toolbar buttons.

Also in 1.3.2:

- The style panel and Settings are laid out the same way, in two sections: **Text Highlight**
  and **Box Highlight**, each with a switch to turn it on or off.
- Every automatic setting, text colour and background included, has the same **Auto** button.
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
