# The Gibson and Friends Podcast

The Gibson and Friends Podcast is a conversational show covering current events, trending topics, opinions, and reviews. Episodes are published as a standard RSS feed with associated audio files and artwork.

## What's in this repo

This repository is a simple static podcast site + RSS feed.

- `docs/` — Published site content (commonly used with GitHub Pages)
- `docs/index.html` — Landing page (currently a placeholder)
- `docs/season01.xml` — RSS feed for Season 1
- `docs/audio/` — Episode audio files
- `docs/images/` — Cover art and other images
- `docs/CNAME` — Custom domain configuration (if hosting with GitHub Pages)

## RSS feed notes

The feed is in `docs/season01.xml` and contains:

- Channel metadata: title, site link, description, language
- Artwork: `<image>` and `itunes:image`
- One `<item>` per episode (title, description, date, enclosure URL, guid)

When adding a new episode, copy an existing `<item>` and update:

- `<title>`
- `<description>`
- `<pubDate>` (RFC 2822 format)
- `<enclosure url=...>` (must point to the hosted audio file)
- `<enclosure length=...>` (byte size of the audio file)
- `<guid>` (unique per episode)

## Publishing a new episode

1. Add the audio file under `docs/audio/`.
2. Add/update artwork under `docs/images/` if needed.
3. Update `docs/season01.xml` with a new `<item>` entry.
4. If the website landing page should reference the new episode, update `docs/index.html`.

## Hosting

This repo is structured to serve everything from `docs/` (site, feed, audio, images). Ensure your hosting setup serves the `docs/` folder as the web root so URLs in the RSS feed resolve correctly.
