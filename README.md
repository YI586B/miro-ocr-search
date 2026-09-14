# Miro-ocr-search — releases

This branch holds the latest built disk image only. The source is on
[`main`](https://github.com/YI586B/miro-ocr-search/tree/main).

## Miro-ocr-search-1.3.dmg

| | |
|---|---|
| Version | 1.3 |
| Requires | macOS 13 Ventura or later, Apple Silicon |
| Size | 3.9M |
| SHA-256 | `aeb557d5616ddd8201e324d31966b5273be4d3bb7b767629161afbbe7965bb6d` |

What's new since 1.2:

- Redrawn words keep their colours: dark text on a light background is no longer redrawn light.
- No more blurred words, and words inside a URL or with punctuation attached stay in place.
- Bold words are redrawn bold: the weight of each word is matched from the image.
- The original letters are taken out on their own, so the new word blends into photos and
  gradients instead of sitting on a coloured block, and a colon after the word stays.
- Font detection knows more fonts, and a block set in a clearly different face (a condensed
  headline, say) gets its own font.
- The style panel says when a font picked by hand, or an image's own saved look, is in effect, with
  a way back to detection; Settings can clear every image's saved look.

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
