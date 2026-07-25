# Miro-ocr-search — guide

A macOS app that reads the text in a folder of screenshots, lets you search it, and can redraw a
match on the image in a font matched to the original — then export the result to files or to a
Miro board.

---

## Getting started

    ./build-app.sh        # compiles and assembles Miro-ocr-search.app
    open "Miro-ocr-search.app"

Or double-click `run-app.command`, which does both.

Then: **Choose folder…** in the toolbar, wait while it reads the images, and type a search.

---

## How searching works

There is **no index and no database**. Opening a folder reads every image in it once with Apple's
Vision OCR, keeps the text in memory, and searches that. What is listed always comes from the
folder named in the toolbar, as it is right now.

The consequence worth knowing: reading is the slow part and it happens per session — about 11
seconds for 21 screenshots. Searching afterwards is instant, because it is a substring scan over a
few dozen strings.

The folder menu also offers **Reload** (pick up files added or changed since), **Reveal in
Finder**, and **Add files…** for pulling in individual images from elsewhere.

### Phrase vs Any word

- **Phrase** — the whole query matched together, in order. "Screen Active" finds that phrase.
- **Any word** — every word must appear somewhere, in any order.

The same rule decides what gets highlighted on the image, so the list and the overlay always agree.

---

## The preview window

Double-click a result, or press **View**.

| | |
|---|---|
| ⌘[ / ⌘] | previous / next result |
| ⌘− / ⌘+ | zoom out / in |
| ⌘0 / ⌘1 | fit to window / actual size |
| ⌘⇧O | overlay on/off |
| ⌘R | recalculate (see below) |
| ⌘S | save the image as shown |
| Esc | close |

Zoom is purely a view control. It changes what you can see of a full-resolution image; it never
changes what is drawn into it.

The line under the image gives the resolution and the folder. The `@2x` marker matters: screenshots
are saved at either 72 or 144 dpi, and on a 144 dpi one a point is two pixels. Sizes in the app are
in points, so this tells you what a point is worth here.

### Boxes or Text

- **Boxes** draws a translucent rectangle over each match.
- **Text** covers each match with a patch matching the background and redraws the word on top.

Text mode is where the matching work happens.

### The hover card

Hover the glyphs of a match — the letters themselves, not a margin around them — and a card
describes that one instance: which match it is, its size, the font, its colours and spacing.

---

## How the overlay matches the image

Everything is measured off the image rather than assumed. For each match the app scans the pixels
inside the match and works out:

- **where the glyphs actually are** — Vision's bounding box is not a tight wrap; measured, it runs
  8–11% taller than the ink inside it and starts several pixels to the left
- **the ink colour** — the most common colour among the solid interior of the strokes, not an
  average that would drag white text toward grey
- **the background colour** — sampled immediately around the match
- **how soft the edges are** — the distance a stroke takes to climb from 20% to 80% of its contrast

From those:

| what | how it is decided |
|---|---|
| **Font** | every candidate family is scored against the whole page, not just the matched words, and the best fit wins. If that turns out to be the system font, Noto Sans is used instead. |
| **Size** | scaled so the string's glyph outlines match the measured ink height. |
| **Spacing** | letter spacing set so the redrawn word spans the measured ink width. This is what stops a substitute font drifting across a word — on Verdana it is the difference between +8.7% too wide and −0.4%. |
| **Smoothness** | blurred to the softness measured on the original, and left alone when the original is already the crisper of the two, since sharpening is not possible. |
| **Colours** | the sampled ink and background, with the pickers as fallbacks. |

Change the font and size, spacing and smoothness are all refitted for it. That is the point: a
different typeface needs different numbers to sit in the same space.

**Alignment** is to the ink, not to Vision's box — left edge to left edge, lowest ink to lowest
ink, which is what keeps descenders from sitting low. Measured across nine matches, placement lands
within 1px horizontally and vertically.

---

## Adjusting it

The **palette button** in the preview toolbar opens the style panel.

Each automatic value has a switch. Turn it off and the field becomes yours; turn it back on and the
measured value returns:

- *Match text colour from image* / *Match background from image*
- *Match font from image* — picking a font from the menu turns this off by itself, since choosing a
  font is the opposite of matching one. Choosing **Auto** turns it back on.
- *Fit size to the text in the image*
- *Fit spacing to the text in the image*, with **Kerning** beside it
- *Fit smoothness to the text in the image*

**⌘R Recalculate** re-reads the image and works every automatic value out again, discarding the
manual ones. Use it if an image changed on disk or a scan went wrong.

### What is per image and what is not

| per image | app-wide |
|---|---|
| font, size, spacing, smoothness, kerning, bold, italic, colours | overlay on/off |
| | Boxes vs Text |
| | the watermark |

Style is per image because each screenshot has its own type sizes and colours, so tuning one should
not restyle the rest. The three app-wide ones describe how you are looking at whatever is open, and
following each image would mean paging through results kept changing the view under you.

The panel ends with **Reset to defaults** (forget this image's settings) and **Save as default**
(make this look the starting point for images that have none).

---

## The watermark

A 63×34 badge, 20px in from the right and bottom. **View ▸ Watermark** switches it off, and asks
for a password to do so. It shows only when the overlay is on as well — with the overlay off you
are looking at the plain image, and a badge would contradict that.

Being straight about the gate: a password compiled into an app can be recovered from it. The hash
is stored rather than the text, so it is not in `strings`, but anyone determined can patch the check
out. It stops the badge being switched off in passing, which is what a gate like this can do.

---

## Exporting

Tick the box on each result you want, then:

- **Export to file ▸ CSV** — path, filename and full OCR text per image
- **Export to file ▸ Markdown** — the same, as a readable document
- **Export to file ▸ Images to directory…** — the images with their overlays and watermark
  composited in, written as PNGs into a folder you choose
- **Export … to Miro** — uploads the composited images to a board, each with its OCR snippet as a
  sticky note. Needs a token with `boards:read` and `boards:write`; it is kept in your Keychain.

**⌘S Save Image** in the preview writes just the one you are looking at.

Exports are always PNG, whatever the source was. The overlay is hard-edged text on flat colour,
which is exactly what JPEG artefacts ruin.

They are also rendered at the image's own resolution rather than captured from the screen, and the
text is re-laid-out at the size that fits in real pixels. Subpixel quantisation is off, subpixel
positioning on, and LCD font smoothing off — that last one bakes colour fringing into a file that
only looks right on the display it was tuned for.

---

## The command line

`ocrsearch` is a separate tool and still keeps an index, unlike the app.

    .build/release/ocrsearch index miro-files
    .build/release/ocrsearch search "Screen Active"
    .build/release/ocrsearch search "invoice AND 2026" --words

The index lives at `~/Library/Application Support/ocrsearch/index.db`. The app does not use it.

---

## Where things are kept

| what | where |
|---|---|
| per-image styles | `com.sir.ocr-search` defaults, key `imageStyles` (most recent 300) |
| app-wide settings | the same defaults, keys beginning `highlight` |
| Miro token | Keychain |
| CLI index | `~/Library/Application Support/ocrsearch/index.db` |

Per-image styles are keyed by **file path**, so moving or renaming an image loses its settings.

---

## Scripts

    ./make-icons.sh                                  # rebuild the app icon from watermark.svg
    swift Scripts/verify-watermark.swift <rendered> <sources>

`verify-watermark.swift` checks exported images against their originals: badge exactly 63×34, 20px
margins, wordmark centred. It finds the badge by diffing against the source rather than hunting for
it by colour, which fails on dark-mode screenshots.

---

## Known issues

- **Letter fit.** Width and height match, but a substitute font distributes that width differently,
  so individual letters do not land on the originals. Spacing fitting reduces this; it does not
  remove it.
- **Per-image settings are path-keyed**, so moving a file loses them.
- **File panels can hang.** Rare, and not reproduced since the panels were moved to being built at
  launch. If the app stops responding after choosing a folder, `sample OCRSearchApp 3` and look for
  `_initBridgeAndStuff`.
- **Miro export is untested against the live API** — the client is written but has never run
  against a real token.
