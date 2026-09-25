# Miro-ocr-search

A macOS app that reads the text in a folder of screenshots with Apple Vision, searches it, and can
redraw a match on the image in a font matched to the original — then export the result to files or
to a Miro board.

**[Download a release](https://github.com/YI586B/miro-ocr-search/tree/release)** — macOS 13+,
Apple Silicon. The app is ad-hoc signed rather than notarised, so the first launch needs
`xattr -dr com.apple.quarantine /Applications/Miro-ocr-search.app`; the guide explains why.

Or build it:

    ./build-app.sh
    open "Miro-ocr-search.app"

Either way: choose a folder, wait while it reads the images, and search.

**[User guide (website) →](https://yi586b.github.io/miro-ocr-search/)** — a one-page, non-technical
introduction: what it is, installing, using it, reporting bugs, contributing, Q&A.

**[Full guide →](GUIDE.md)** — searching, the preview window, how the overlay is matched to the
image, per-image settings, the watermark, exporting, and the command line.

## What is in here

| | |
|---|---|
| `Sources/OCRSearchApp` | the app: search window, preview, overlay rendering, export |
| `Sources/OCRSearchCore` | Vision OCR, the Miro client, and the SQLite index the CLI uses |
| `Sources/ocrsearch` | the command line tool, which keeps its own index |
| `Sources/assets` | logo, icon, watermark, bundled Noto Sans |
| `Scripts` | icon generation, watermark verification |
| `docs` | the user guide website, served by GitHub Pages from `main` /docs |
| `make-release.sh` | builds the installable disk image into `dist/` |

Test screenshots live in a local `miro-files/` folder, which is not tracked — point the app at any
folder of images instead.

## Command line

Separate from the app, and it does keep an index.

    .build/release/ocrsearch index ~/Pictures/Screenshots
    .build/release/ocrsearch search "invoice AND 2026"
    MIRO_TOKEN=... .build/release/ocrsearch export "invoice" --name "Invoices Q3"

Index at `~/Library/Application Support/ocrsearch/index.db`; re-running `index` only re-reads new
or modified files. The app does not use it.
