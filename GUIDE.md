# Miro-ocr-search — guide

A macOS app that reads the text in a folder of images, lets you search it, and can redraw a
match on the image in a font matched to the original — then export the result to files or to a
Miro board.

It is a search tool, not an image editor: it finds text in your images and shows where it is.
Images it outputs carry a Miro watermark, because the app uses Miro's libraries.

---

## Requirements

| | |
|---|---|
| macOS | 13 Ventura or later |
| Mac | Apple Silicon (M1 or newer) |
| Disk | about 5 MB |

Apple Silicon only. The app is built from source here with the Command Line Tools, which cannot
produce a universal binary — that needs a full Xcode install — so there is no Intel slice. On an
Intel Mac, build from source instead.

Nothing else is needed. OCR runs on the device through Apple's Vision framework, so there is no
account, no network and no API key, and nothing about your images leaves the machine. The one
exception is exporting to Miro, which is an upload and needs a token.

---

## Installing a release

Releases live on the **`release` branch**, not in the main line of the repository.

1. Open the [`release` branch](https://github.com/YI586B/miro-ocr-search/tree/release) and
   download `Miro-ocr-search-<version>.dmg`.
2. Open the disk image and drag **Miro-ocr-search** into **Applications**.
3. The first launch will be refused. See below.

### The first launch is refused — this is expected

macOS will say the app "cannot be opened because the developer cannot be verified", or on newer
versions that it "is damaged and can't be opened". Neither is a fault in the download.

The app is signed, but with an ad-hoc signature rather than a Developer ID, and it is not
notarised. Both require a paid Apple Developer account. macOS quarantines anything downloaded from
the internet and refuses to run it unless it carries a signature it can trace to a registered
developer.

To run it anyway, clear the quarantine flag:

    xattr -dr com.apple.quarantine /Applications/Miro-ocr-search.app

Then open it normally. You only need to do this once per download.

Right-clicking the app and choosing **Open** also works on some macOS versions, and is worth
trying first if you would rather not use the terminal.

If that trade is not one you want to make — and it is a reasonable thing not to want — building
from source avoids it entirely, because a locally built app is never quarantined.

### Verifying a download

Each release commit records the disk image's SHA-256. To check yours matches:

    shasum -a 256 ~/Downloads/Miro-ocr-search-1.1.dmg

---

## Building from source

    git clone git@github.com:YI586B/miro-ocr-search.git
    cd miro-ocr-search
    ./build-app.sh
    open "Miro-ocr-search.app"

Needs Swift 5.9 or later — `xcode-select --install` is enough, full Xcode is not required. The
build takes under a minute from cold.

`./make-release.sh` produces the disk image in `dist/`, reporting its size, architecture, minimum
macOS version and checksum.

---

## Getting started

Install a release (see below) or build from source, then: **Choose folder…** in the toolbar, wait while it reads the images, and type a search.

---

## How searching works

There is **no index and no database**. Opening a folder reads every image in it once with Apple's
Vision OCR, keeps the text in memory, and searches that. What is listed always comes from the
folder named in the toolbar, as it is right now.

The consequence worth knowing: reading is the slow part and it happens per session — about 11
seconds for 21 images. Searching afterwards is instant, because it is a substring scan over a
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
| ⌥⌘[ / ⌥⌘] | previous / next match, with its hover card |
| ⌘− / ⌘+ (or ⌘=), pinch | zoom out / in |
| ⌘0 / ⌘9 | actual size / zoom to fit |
| ⌘⇧O | overlay on/off |
| ⌥⌘I | show / hide the style panel |
| ⌘R | recalculate (see below) |
| ⌘S | export the image as shown, as a PNG |
| Esc | close |

These are all in the menu bar too: **File** (Export as PNG, Reveal in Finder), **View** (overlay,
zoom, style panel, Recalculate) and **Go** (images and matches). The toolbar keeps back/forward on
the left and zoom, **Overlay**, **Style** and **Export** on the right. The file icon in the title
bar works as in any document window: ⌘-click it for the folder, or drag it.

The search field at the top right holds what is being found on the image, starting with the search
the window was opened from. Change it and the matches update as you type — the image is not read
again, so it is quick. While the field is in use, **Phrase** and **Any Word** appear under it, as
in the search window. The new text stays in place as you page to other results in the same window;
the search window's own list is not changed.

Zoom is purely a view control. It changes what you can see of a full-resolution image; it never
changes what is drawn into it.

The line under the image gives the resolution, the folder, and how many matches were found for what. The `@2x` marker matters: images
are saved at either 72 or 144 dpi, and on a 144 dpi one a point is two pixels. Sizes in the app are
in points, so this tells you what a point is worth here.

### Boxes and Text

Two separate switches, both on by default. They are in the preview toolbar's **Overlay** menu
(click the button itself to hide or show the whole overlay; use its arrow for the switches) and in
the **View** menu (**Show Boxes**, **Show Text**).

- **Boxes** draws an outline around each match. Its fill starts at 0%; the style panel's **Fill opacity** adds a translucent fill.
- **Text** covers each match with a patch matching the background and redraws the word on top.

With both on, the box is drawn over the redrawn text. Text is where the matching work happens.

### The hover card

Hover the glyphs of a match — the letters themselves, not a margin around them — and a card
describes that one instance: which match it is, its size, the font, its colours and spacing.
⌥⌘] and ⌥⌘[ step through the matches from the keyboard and show the same card.

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
| **Font** | every candidate family is compared by letter shape against the whole page, not just the matched words: each line is drawn in the candidate over the glyphs measured off the image, and the closest wins. If nothing is close enough (a photo, a custom typeface) there is no match and the Font and Weight settings apply. If the winner is the system font (SF), Noto Sans is used instead; it ships with the app, and in that case only it is drawn 30% heavier (weight 400 → 520; bold 700 → 900, the font's maximum), since it reads lighter than SF. |
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

**Style** in the preview toolbar (⌥⌘I) opens the style panel on the right of the window, so the
image stays in view while you adjust it. It shows the Text settings when Text is on and the Box
settings when Boxes is on.

Each automatic value can be switched off. Do that and the field becomes yours; switch it back on
and the measured value returns:

- *Match text colour from image* / *Match background from image*. While these are on, the colour
  below each is only a fallback, used where sampling fails, and is labelled that way.
- *Match font from image* — picking a font from the menu turns this off by itself, since choosing a
  font is the opposite of matching one. Choosing **Auto** turns it back on.
- **Auto** beside Size, Spacing and Smoothness. Typing a value turns it off.

**B** and **I** sit on the Size row; **Kerning** is below Smoothness.

**⌘R Recalculate** re-reads the image and works every automatic value out again, discarding the
manual ones. Use it if an image changed on disk or a scan went wrong.

### What is per image and what is not

| per image | app-wide |
|---|---|
| font, size, spacing, smoothness, kerning, bold, italic, colours | overlay on/off |
| | Boxes and Text |
| | the watermark |

Style is per image because each image has its own type sizes and colours, so tuning one should
not restyle the rest. The three app-wide ones describe how you are looking at whatever is open, and
following each image would mean paging through results kept changing the view under you.

The panel ends with a **Reset** menu and **Save as Default** (make this look the starting point for
images that have none). Reset offers **Font to Automatic** (font, size, spacing, smoothness, bold,
italic and kerning back to automatic), **This Image to Defaults** (forget this image's settings)
and **Recalculate Everything** (⌘R, above).

---

## The watermark

Every image the app outputs carries a Miro watermark, because the app uses Miro's libraries.

It is a badge 20px in from the right and bottom, sized to the image: it scales with the image's diagonal,
so it is 63×34 on a 1206×2622 iPhone image, 71×38 on a 1356×2948 one and 29×16 on a 1100×735
photo (width = diagonal × 63 / 2886.13028, height = width × 34 / 63, both rounded). **View ▸ Watermark** switches it off, and asks
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

**⌘S Export as PNG** in the preview writes just the one you are looking at.

Exports are always PNG, whatever the source was. The overlay is hard-edged text on flat colour,
which is exactly what JPEG artefacts ruin.

They are also rendered at the image's own resolution rather than captured from the screen, and the
text is re-laid-out at the size that fits in real pixels. Subpixel quantisation is off, subpixel
positioning on, and LCD font smoothing off — that last one bakes colour fringing into a file that
only looks right on the display it was tuned for.

---

## The command line

`ocrsearch` is a separate tool and still keeps an index, unlike the app.

    .build/release/ocrsearch index ~/Pictures/Screenshots
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

`verify-watermark.swift` checks exported images against their originals: badge exactly the size the
formula above gives for that image, 20px margins, wordmark centred. It finds the badge by diffing against the source rather than hunting for
it by colour, which fails on dark-mode images.

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
