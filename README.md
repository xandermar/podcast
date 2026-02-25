# The 50 Shades of Beer Podcast

The 50 Shades of Beer Podcast is a conversational show covering current events, trending topics, opinions, and reviews. Episodes are published as a standard RSS feed with associated audio files and artwork.

This repo builds a static site + podcast RSS feed using [build.sh](build.sh) and a small set of templates.

## Prerequisites

Required:
- Bash (macOS default is fine)
- Ruby (used for YAML parsing and template substitution)

Optional (improves output, but the build still works without them):
- `xmllint` (prettifies RSS XML)
- `python3` (fallback prettifier if `xmllint` is not installed)
- `ffprobe` (from ffmpeg; computes audio duration)
- `file` (best-effort MIME detection for unknown extensions)

## Quick start

1) Edit global podcast metadata in [config.yml](config.yml)

2) Add at least one episode under [podcast](podcast), e.g. [podcast/s1e1](podcast/s1e1):
- [podcast/s1e1/meta.yml](podcast/s1e1/meta.yml)
- [podcast/s1e1/audio.mp3](podcast/s1e1/audio.mp3)

3) Build:

```sh
./build.sh
```

Generated files:
- [docs/podcast.xml](docs/podcast.xml)
- [docs/chapters](docs/chapters)
- [docs/episodes](docs/episodes)

## Repository layout

- [config.yml](config.yml): global variables used across the feed
- [podcast_global.xml](podcast_global.xml): RSS channel/feed template
- [podcast_item.xml](podcast_item.xml): per-episode `<item>` template
- [podcast_chapters.json](podcast_chapters.json): chapters JSON template (uses `{{VARNAME}}` placeholders)
- [podcast](podcast): episode source directories (one per episode)
- [docs](docs): build output (static site root)

## How the build works

[build.sh](build.sh) does two main passes:

1) Per-episode loop (`podcast/*`)
- Loads [config.yml](config.yml) + `podcast/<episode>/meta.yml`
- Derives missing item fields from the file system (see “Derived fields” below)
- Renders [podcast_item.xml](podcast_item.xml) and accumulates each `<item>` into an `ITEMS` variable
- (Executed mode only) writes chapters JSON and placeholder HTML pages

2) Global feed render
- Renders [podcast_global.xml](podcast_global.xml)
- Injects `[ITEMS]`
- Injects `[LASTBUILDDATE]` computed at runtime
- (Executed mode only) writes and prettifies [docs/podcast.xml](docs/podcast.xml)

## Executed vs sourced behavior

This script is designed to be used in two ways:

Executed:
```sh
./build.sh
```
- Writes files under [docs](docs)
- Clears and recreates [docs/episodes](docs/episodes) on each run

Sourced:
```sh
source ./build.sh
```
- Silent: prints nothing
- No file writes/deletes
- Exposes variables in your shell (notably `ITEMS` and `PODCAST_XML`)

## Episode authoring

### Episode directory naming

Episode directories should be named like `s1e1`, `s1e2`, etc under [podcast](podcast). The script uses this to derive:
- `ITEM_SEASON`
- `ITEM_EPISODE`

### Required episode files

Each episode directory should contain:
- `audio.mp3` (the script currently expects the filename `audio.mp3`)
- `meta.yml`

### Episode meta.yml format

The build supports a “flat” meta schema where keys map directly to placeholders used by [podcast_item.xml](podcast_item.xml).

Common fields:
- `ITEM_TITLE`
- `ITEM_SUBTITLE`
- `ITEM_DESCRIPTION`
- `ITEM_AUTHOR`
- `ITEM_EXPLICIT`
- `ITEM_KEYWORDS`
- `CATEGORIES` (array or string; see below)

Categories formats accepted:

YAML list:
```yml
CATEGORIES:
	- Technology
	- Travel
```

Comma-separated string:
```yml
CATEGORIES: Technology, Travel
```

Chapter marker fields:
- The chapters generator substitutes any `{{VARNAME}}` placeholders present in [podcast_chapters.json](podcast_chapters.json).
- If you add a new `{{SOME_KEY}}` placeholder to the chapters template, add `SOME_KEY` to your episode `meta.yml`.

## Derived fields

If these are not present in an episode `meta.yml`, [build.sh](build.sh) derives them:

- `ITEM_LINK`
	- Generated as `[PODCAST_LINK]/episodes/<slugified ITEM_TITLE>.html`
	- (Executed mode only) ensures a placeholder HTML file exists in [docs/episodes](docs/episodes)

- `ITEM_PUBDATE`
	- Derived from the birth/creation time of `podcast/<episode>/audio.mp3` when available

- `ITEM_PATH`
	- Always set to `<episode>/audio.mp3` (used for enclosure URL building in templates)

- `ITEM_ENCLOSURE_LENGTH`
	- File size of `audio.mp3` in bytes

- `ITEM_ENCLOSURE_TYPE`
	- MIME type derived from the file extension (fallback: `file --mime-type`)

- `ITEM_DURATION`
	- Duration from `ffprobe` (fallback: `00:00:00` for empty/missing files)

- `ITEM_ITUNES_IMAGE_HREF`
	- Defaults to `[PODCAST_LINK]/images/cover.jpg`

- `ITEM_PODCAST_CHAPTERS_URL`
	- Defaults to `[PODCAST_LINK]/chapters/<episode>.json`
	- (Executed mode only) writes JSON to [docs/chapters](docs/chapters)

## Templates and placeholders

### XML templates

[podcast_global.xml](podcast_global.xml) uses `[VARNAME]` placeholders, notably:
- `[ITEMS]` (injected raw as rendered `<item>` blocks)
- `[LASTBUILDDATE]` (computed at build time)

[podcast_item.xml](podcast_item.xml) uses `[ITEM_*]` placeholders.

Placeholder substitution rules:
- Most values are XML-escaped automatically.
- `[ITEM_CONTENT_ENCODED]` is inserted without escaping (intended to be wrapped in CDATA in the template).
- `[ITEM_CATEGORIES]` is inserted as raw XML (a block of repeated `<category>…</category>` tags).

### Chapters JSON template

[podcast_chapters.json](podcast_chapters.json) uses `{{VARNAME}}` placeholders.

Substitution rules:
- Values are JSON-escaped (safe inside JSON string contexts).
- Output is validated and pretty-printed.

## Troubleshooting

- Duration is always `00:00:00`
	- Install `ffprobe` (ffmpeg) and re-run the build.

- XML looks “minified”
	- Install `xmllint` to prettify [docs/podcast.xml](docs/podcast.xml), or ensure `python3` is available for the fallback formatter.

- Episode link points to a missing page
	- In executed mode, [build.sh](build.sh) auto-creates placeholder pages under [docs/episodes](docs/episodes).
	- If you want real pages, replace the generated placeholders with your own content.
