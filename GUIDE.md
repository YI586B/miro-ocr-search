# Miro-ocr-search — guide

**Search the text in your pictures, images and screenshots, locally on your Mac.**

Miro-ocr-search is a Mac app that turns messy folders of documents, images, photos and screenshots into something you can search like a document. Using Apple's OCR technology and libraries from Miro, it lets you find any image by the text inside it.

It reads the text in a folder of images, lets you search it, and can redraw a match on the image in
a font matched to the original — then export the result to files or to a Miro board.

It is a search tool, not an image editor: it finds text in your images and shows where it is.
Images it outputs carry a Miro watermark, because the app uses Miro's libraries.

---

## Requirements

| | |
|---|---|
| macOS | 12 Monterey or later |
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

Releases live on the **`release` branch**, not in the main line of the repository. It holds only
the latest disk image; older ones are removed when a new release goes up.

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

    shasum -a 256 ~/Downloads/Miro-ocr-search-1.3.2.dmg

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

Double-click a result, or press **View**. It opens 830 × 900 points, wide enough for every toolbar
button to show with a screenshot's name as its title (a very long file name can push one into the
» menu); after that macOS remembers the size you last left one at.

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

**Moving the image.** Click and drag the image to move it within its own frame. The frame keeps
its size: what is pushed past an edge is cut off, and the space the image leaves is black. The
highlights move with it; the watermark stays in the corner. The position is saved for that image
and used by every export of it. The style panel says how far it has moved, and **Reset ▸ Position**
puts it back.

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

- **Boxes** draws an outline around each match. Its fill starts at 0%; the style panel's **Fill** adds a translucent fill.
- **Text** covers each match with a patch matching the background and redraws the word on top.

With both on, the box is drawn behind the redrawn text, so the text stays on top. Text is where the matching work happens.

### The hover card

Hover the glyphs of a match — the letters themselves, not a margin around them — and a card
describes that one instance: which match it is, its size, the font, its colours and spacing.
⌥⌘] and ⌥⌘[ step through the matches from the keyboard and show the same card.

On macOS 12 the card does not follow the pointer — macOS 12 cannot report where it is over the
image — so use ⌥⌘] and ⌥⌘[ there. The preview's Phrase / Any Word choice is also a small menu in
the toolbar on macOS 12 rather than sitting under the search field.

---

## How the overlay matches the image

Everything is measured off the image rather than assumed. For each match the app scans the pixels
inside the match and works out:

- **the background colour** — the most common colour in a thin ring just outside the match, so
  neighbouring words and lines do not tint it
- **the ink colour** — the most common colour among the solid interior of the strokes, not an
  average that would drag white text toward grey
- **where the glyphs actually are** — only pixels on the way from the background to the ink colour
  count, so the texture of a photo behind the letters is left out. Vision's bounding box is not a
  tight wrap; measured, it runs 8–11% taller than the ink inside it and starts several pixels to
  the left
- **how soft the edges are** — the distance a stroke takes to climb from 20% to 80% of its contrast

If the letters cannot be told apart from what is behind them (the ink fills Vision's box), the
redrawn word is sized and placed by Vision's box instead and is not blurred. A word inside a long
unbroken string, such as a URL, is placed by its share of the line's width, because Vision gives
it the whole line's box.

From those:

| what | how it is decided |
|---|---|
| **Font** | every candidate family is compared by letter shape against the whole page, not just the matched words: each line is drawn in the candidate over the glyphs measured off the image, and the closest wins. Each match is also checked against its own block — its line and the nearby lines of similar size — and a block set in a clearly different face (a condensed headline over body text) gets that face instead; a block only close to the page's answer keeps the page's, so a page in one face stays consistent. If nothing is close enough (a photo, a custom typeface) there is no match and the Font and Weight settings apply. If the winner is the system font (SF), Noto Sans is used instead; it ships with the app, and in that case only it is drawn 30% heavier (weight 400 → 520; bold 700 → 900, the font's maximum), since it reads lighter than SF. |
| **Weight** | per match, matched to how much of its box the original's letters cover (a bold heading comes out bold, body text regular). A variable font is set to the exact measured weight; other fonts choose regular or bold. Noto Sans standing in for SF keeps its 30% boost and only chooses regular or bold. Choose **Regular** or **Bold** instead of **Auto** under Weight to use one weight for every match. |
| **Size** | scaled so the string's glyph outlines match the measured ink height. |
| **Spacing** | letter spacing set so the redrawn word spans the measured ink width. This is what stops a substitute font drifting across a word — on Verdana it is the difference between +8.7% too wide and −0.4%. |
| **Edges** | each word's edges are measured on the original and on our own drawing of the same word, both to a fraction of a pixel. A softer original is matched with a slight blur; a crisper one by steepening our drawn edges (up to 1.6 times), which is searched for rather than computed, since at a pixel or so wide edges do not narrow in proportion. Differences under 0.05 px are left alone. Where Noto Sans stands in for SF, edges are left at 0 — neither blurred nor sharpened — like its 30% boost, a deliberate exception. |
| **Covering the original** | only the original letters are taken out — their pixels, widened a little for soft edges, including parts that reach past Vision's box — and filled from the pixels around them, so a flat colour stays exact and a photo or gradient carries on through. Neighbouring text, such as a colon after the word, is left alone. Where the letters could not be isolated, or when you pick a Background colour, a flat patch is used instead. |
| **Colours** | the sampled ink and background; the chosen colours are used where sampling fails. |

Change the font and size, spacing and edges are all refitted for it. That is the point: a
different typeface needs different numbers to sit in the same space.

**Alignment** is to the ink, not to Vision's box — left edge to left edge, lowest ink to lowest
ink, which is what keeps descenders from sitting low. Measured across nine matches, placement lands
within 1px horizontally and vertically.

---

## Adjusting it

**Style** in the preview toolbar (⌥⌘I) opens the style panel on the right of the window, so the
image stays in view while you adjust it. From the top:

- **The image's name** and a badge: **Defaults** while it follows the defaults in Settings, **Own
  look** once it has settings of its own (see below). **Reset** sits beside it.
- **Text Highlight**, with a switch that draws it or not (the same setting as the Overlay menu's
  Text): Font, Size, Weight (Auto, Regular or Bold, plus **I** for italic), Colour, Background,
  Spacing, Edges and Kerning.
- **Box Highlight**, with its own switch (the same as Overlay ▸ Boxes): Colour, Fill and Outline.
- **Recalculate** and **Save as Default**.

A highlight that is switched off stays in the panel, dimmed, so nothing moves around.

Each automatic value can be switched off. Do that and the field becomes yours; switch it back on
and the measured value returns:

- **Font**: **Auto** matches it from the image and names what it found. Picking a family turns
  matching off; choosing Auto again turns it back on.
- **Weight**: **Auto** matches each match's weight; **Regular** or **Bold** uses that for every match.
- **Colour** and **Background**: while **Auto** is on, the swatch shows what was picked up from
  the image (the first match's; the hover card shows each match's own). Turn Auto off and the
  swatch becomes a colour picker. The colour you chose is still used where sampling fails.
  With Auto off, Background covers each match with a flat patch in that colour instead of painting
  out just the letters.
- **Auto** beside Size, Spacing and Edges. Typing a value, or moving the Edges slider, turns it off.
  The Edges slider runs from **Crisper** to **Softer** with 0 in the middle; in the field, above 0 is
  a blur in points and below 0 sharpens (-0.3 is 1.3 times steeper). While Auto is on these show
  the first match's fitted value.

**⌘R Recalculate** re-reads the image and works every automatic value out again, discarding the
manual ones. Use it if an image changed on disk or a scan went wrong.

### What is per image and what is not

| per image | app-wide |
|---|---|
| font, size, spacing, edges, kerning, bold, italic, colours, position | overlay on/off |
| | Boxes and Text |
| | the watermark |

Style is per image because each image has its own type sizes and colours, so tuning one should
not restyle the rest. The three app-wide ones describe how you are looking at whatever is open, and
following each image would mean paging through results kept changing the view under you.

An image has a look of its own only once you change something on it; until then it follows the
defaults in Settings, and changing those reaches it. The badge at the top of the panel says which:
**Defaults** or **Own look**. Changing a setting back to the default hands the image back to the
defaults. **Settings ▸ Forget Every Image's Own Look** clears them all, including copies earlier
versions saved just by opening an image, which then stopped following the defaults.

**Settings** (⌘,) holds those defaults, laid out like the style panel: **Show Highlights**,
then **Text Highlight** (Font, Weight, Colour, Background) and **Box Highlight** (Colour, Fill,
Outline), each with its switch, and a sample of the result. Size, spacing and edges are measured
on each image, so they are only in the style panel. **Reset to Original Defaults** puts the page back
to how the app ships:

| setting | as shipped |
|---|---|
| Show Highlights, Text Highlight, Box Highlight | on |
| Font | Auto (matched from the image) |
| Size, Spacing, Edges | Auto (measured per match) |
| Weight | Auto; italic off; kerning on |
| Colour | Auto; black (#000000) where sampling fails |
| Background | Auto (the original letters painted out); white (#FFFFFF) where sampling fails |
| Box colour | red (#FF1400) |
| Fill | 0% |
| Outline | on |
| Export size | 112.4% |

When a font was picked by hand for an image, the panel says so under Font and names what detection
found, with **Use detected font** to switch back; when font matching is off, it says that, with
**Match font from image**. The hover card shows a picked font's detected alternative too.

**Reset**, at the top, offers **Font to Automatic** (font, size, spacing, edges, weight, italic
and kerning back to automatic), **Position** (put a moved image back) and **This Image to
Defaults** (forget this image's settings, position included).
**Save as Default**, at the bottom, makes this look the starting point for images that have none.

---

## The watermark

Every image the app outputs with highlights carries a Miro watermark, because the app uses Miro's
libraries. It also shows at a glance that the image has been changed from the original.

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
  composited in, written as PNGs into a folder you choose. Each image is drawn with its own look
  and position, as its preview shows it.
- **Export … to Miro** — uploads the composited images to a board, each with its OCR snippet as a
  sticky note. Needs a token with `boards:read` and `boards:write`; it is kept in your Keychain.

**⌘S Export as PNG** in the preview writes just the one you are looking at.

Exports are always PNG, whatever the source was. The overlay is hard-edged text on flat colour,
which is exactly what JPEG artefacts ruin.

They are also rendered at the image's own resolution rather than captured from the screen, and the
text is re-laid-out at the size that fits in real pixels. Subpixel quantisation is off, subpixel
positioning on, and LCD font smoothing off — that last one bakes colour fringing into a file that
only looks right on the display it was tuned for.

### Export size

**Settings ▸ Export ▸ Size** makes exported images larger, for showing them on larger displays:
112.4% (the default), 100% (the image's own size), 124.8%, 150.6% or Custom, any percentage from
25% to 400%.
It applies to every export — Export as PNG, Images to directory and Miro — whether highlights are
on or not. The image itself is scaled smoothly, which cannot add detail it never had; the
highlights are drawn at the new size, so their text and boxes stay sharp. The watermark does not
scale: it is the size it is on the original image, 20px in from the export's right and bottom edges. When it is not 100%, the save panel shows the output size
(1206 × 2622 → 1356 × 2947 at 112.4%) and the Miro sheet says so; choose 100% to export at the
image's own size. For crisper results on Retina and
large screens, a Custom 200% is the step that helps.

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
