#!/usr/bin/env bash

## build.sh
#
# Purpose
# - Generates a complete podcast RSS feed XML using a global template + per-episode templates.
# - Generates per-episode Podcasting 2.0 chapters JSON files.
# - Creates placeholder episode HTML pages ("Coming soon!") for episode links.
#
# Key behaviors
# - When executed (./build.sh): writes files under docs/ (site output) and prints nothing unless a later step prints.
# - When sourced (source ./build.sh): produces NO output and does NOT write files; it only sets variables (ITEMS, PODCAST_XML, etc)
#   so a larger pipeline can reuse them.
#
# Inputs
# - config.yml: global podcast metadata used for [PODCAST_*] placeholders.
# - podcast/*/meta.yml: per-episode metadata and chapter markers.
# - podcast_global.xml: global feed template with placeholders like [PODCAST_NAME], [LASTBUILDDATE], [ITEMS].
# - podcast_item.xml: per-episode <item> template with placeholders like [ITEM_TITLE], [ITEM_LINK], etc.
# - podcast_chapters.json: chapters JSON template using {{VARS}} placeholders.
#
# Outputs (executed mode)
# - docs/podcast.xml: final formatted RSS feed.
# - docs/chapters/*.json: per-episode chapters files (path derived from ITEM_PODCAST_CHAPTERS_URL).
# - docs/episodes/*.html: placeholder episode pages when the generated episode link does not already exist.
#
# Notes
# - This script intentionally avoids "set -e" so it can be embedded into larger pipelines without unexpected exits.
# - Values are derived where possible (pubDate from audio file birthtime, enclosure length from file size, etc.).

########################


###
# Compute top-level derived values
###

# RSS-friendly lastBuildDate (RFC 822-ish, GMT). This is injected into the global template.
LAST_BUILD_DATE="$(date -u +"%a, %d %b %Y %H:%M:%S GMT")"

# Holds the concatenated rendered <item> blocks.
ITEMS=

# Side-effect gating:
# - When sourced: BUILD_WRITE_FILES=0 means *no* file creation/deletion.
# - When executed: BUILD_WRITE_FILES=1 allows writing outputs under docs/.
BUILD_WRITE_FILES=0
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	BUILD_WRITE_FILES=1
fi
export BUILD_WRITE_FILES

# Episode pages are regenerated each run.
# Clearing the directory guarantees no stale pages remain after renames.
if [[ "$BUILD_WRITE_FILES" == "1" ]]; then
	rm -rf docs/episodes
	mkdir -p docs/episodes
fi


###
# Render <item> XML for each episode
#
# This loop:
# - reads each podcast/*/meta.yml
# - merges it with config.yml
# - derives missing fields (link, pubDate, enclosure type/length, duration, season/episode)
# - optionally writes docs/episodes/*.html and docs/chapters/*.json (executed mode only)
# - renders podcast_item.xml and accumulates it into ITEMS
###

ITEM_TEMPLATE_PATH="podcast_item.xml"

if [[ ! -f "$ITEM_TEMPLATE_PATH" ]]; then
	echo "Missing item template: $ITEM_TEMPLATE_PATH" >&2
	exit 1
fi

shopt -s nullglob
for episode_dir in podcast/*; do
	[[ -d "$episode_dir" ]] || continue

	meta_path="$episode_dir/meta.yml"
	[[ -f "$meta_path" ]] || { echo "Skipping $episode_dir (missing meta.yml)" >&2; continue; }

	rendered_item="$(
		ruby -ryaml - "config.yml" "$meta_path" "$ITEM_TEMPLATE_PATH" "podcast_chapters.json" "$episode_dir" <<'RUBY'
config_path, meta_path, template_path, chapters_template_path, item_path = ARGV

require 'open3'
require 'fileutils'
require 'uri'
require 'json'

# ------------------------------
# Helpers: escaping and parsing
# ------------------------------

def xml_escape(value)
	# Minimal XML escaping for text nodes/attribute values.
	value.to_s
			 .gsub('&', '&amp;')
			 .gsub('<', '&lt;')
			 .gsub('>', '&gt;')
			 .gsub('"', '&quot;')
			 .gsub("'", '&apos;')
end

def normalize_categories(value)
	# Accept categories in a few formats:
	# - YAML array: ["Technology", "Travel"]
	# - comma-separated string: "Technology, Travel"
	# - newline-separated string
	case value
	when Array
		value.map(&:to_s)
	when String
		value.split(/[,\n]/)
	else
		[]
	end.map { |c| c.strip }.reject(&:empty?)
end

def dig_hash(hash, *keys)
	# Safe hash digging for nested YAML structures.
	keys.reduce(hash) { |acc, key| acc.is_a?(Hash) ? acc[key] : nil }
end

def machine_name(value)
	# Slugify into machine-readable text for URLs/filenames.
	value.to_s
		 .downcase
		 .gsub(/[^a-z0-9]+/, '-')
		 .gsub(/\A-+|-+\z/, '')
end

def rss_date_gmt(time)
	# RSS pubDate/lastBuildDate formatting.
	time.utc.strftime('%a, %d %b %Y %H:%M:%S GMT')
end

def format_hhmmss(total_seconds)
	# iTunes duration format: HH:MM:SS
	total_seconds = total_seconds.to_i
	hours = total_seconds / 3600
	minutes = (total_seconds % 3600) / 60
	seconds = total_seconds % 60
	format('%02d:%02d:%02d', hours, minutes, seconds)
end

def command_exists?(cmd)
	# Used for optional tooling (ffprobe).
	system("command -v #{cmd} >/dev/null 2>&1")
end

def execution_mode?
	# When sourced, this is "0" and we avoid writing files.
	ENV['BUILD_WRITE_FILES'].to_s == '1'
end

def ensure_coming_soon_html_exists(item_link, item_slug)
	# Creates docs/episodes/<slug>.html if it doesn't exist.
	# This allows the RSS <link> to always resolve to a real page.
	return unless execution_mode?
	return if item_link.nil? || item_link.to_s.strip.empty?
	return if item_slug.nil? || item_slug.to_s.strip.empty?

	path = nil
	begin
		uri = URI.parse(item_link.to_s)
		path = uri.path
	rescue URI::InvalidURIError
		path = item_link.to_s
	end

	path = '/' + path unless path.start_with?('/')
	path = '/index.html' if path == '/'

	# Always publish episode pages under docs/episodes/
	file_path = File.join('docs', 'episodes', "#{item_slug}.html")

	return if File.exist?(file_path)

	FileUtils.mkdir_p(File.dirname(file_path))
	File.write(
		file_path,
		<<~HTML
			<!doctype html>
			<html lang="en">
			  <head>
			    <meta charset="utf-8" />
			    <meta name="viewport" content="width=device-width, initial-scale=1" />
			    <title>Coming soon</title>
			  </head>
			  <body>
			    Coming soon!
			  </body>
			</html>
		HTML
	)
end

def json_escape_fragment(value)
	# Escapes a value for placement inside an existing JSON string context.
	# JSON.generate wraps in quotes; we strip the leading/trailing quote.
	JSON.generate(value.to_s)[1..-2]
end

def render_chapters_json(chapters_template, replacements)
	# Renders podcast_chapters.json (a JSON template with {{VARS}}) using values from replacements.
	# It returns pretty-printed, validated JSON.
	rendered = chapters_template.dup

	# Replace numeric/bool placeholders even if they are quoted in the template: "{{KEY}}" -> 123
	replacements.each do |key, value|
		placeholder = "{{#{key}}}"
		next unless rendered.include?(placeholder)

		case value
		when Integer, Float
			rendered.gsub!(%Q{"#{placeholder}"}, value.to_s)
			rendered.gsub!(placeholder, value.to_s)
		when TrueClass, FalseClass
			rendered.gsub!(%Q{"#{placeholder}"}, value ? 'true' : 'false')
			rendered.gsub!(placeholder, value ? 'true' : 'false')
		else
			rendered.gsub!(placeholder, json_escape_fragment(value))
		end
	end

	# Validate + pretty-print
	JSON.pretty_generate(JSON.parse(rendered)) + "\n"
end

def ensure_chapters_json_exists(chapters_url, chapters_template_path, replacements)
	# Writes docs/... based on the path portion of ITEM_PODCAST_CHAPTERS_URL.
	# Example:
	#   https://podcast.example.com/chapters/s1e1.json -> docs/chapters/s1e1.json
	return unless execution_mode?
	return if chapters_url.nil? || chapters_url.to_s.strip.empty?
	return unless File.file?(chapters_template_path)

	path = nil
	begin
		uri = URI.parse(chapters_url.to_s)
		path = uri.path
	rescue URI::InvalidURIError
		path = chapters_url.to_s
	end

	path = '/' + path unless path.start_with?('/')
	# We publish site files under docs/
	rel = path.sub(%r{\A/+}, '')
	file_path = File.join('docs', rel)

	FileUtils.mkdir_p(File.dirname(file_path))
	chapters_template = File.read(chapters_template_path)
	json = render_chapters_json(chapters_template, replacements)
	File.write(file_path, json)
end

config = YAML.load_file(config_path) || {}
meta = YAML.load_file(meta_path) || {}
template = File.read(template_path)

def blank?(value)
	# "Blank" means nil/empty/whitespace.
	value.nil? || value.to_s.strip.empty?
end

replacements = {}

# Merge global config and episode meta into one replacement map.
# Episode meta wins if a key appears in both.
config.each { |k, v| replacements[k.to_s] = v }
meta.each { |k, v| replacements[k.to_s] = v }

# Episode directory slug (podcast/s1e12 => s1e12)
episode_slug = File.basename(item_path.to_s)

# ITEM_PATH is used for media URLs and must be "<episode_slug>/audio.mp3".
replacements['ITEM_PATH'] = File.join(episode_slug, 'audio.mp3')

if (match = episode_slug.match(/\As(?<season>\d+)e(?<episode>\d+)\z/i))
	# Derive season/episode from the directory name if not explicitly set.
	replacements['ITEM_SEASON'] = match[:season] if blank?(replacements['ITEM_SEASON'])
	replacements['ITEM_EPISODE'] = match[:episode] if blank?(replacements['ITEM_EPISODE'])
end

# Support nested meta schema by deriving common ITEM_* keys when absent.

# Title/subtitle/description are expected to be authored in meta.yml.
replacements['ITEM_TITLE'] = meta['title'] || dig_hash(meta, 'itunes', 'title') if blank?(replacements['ITEM_TITLE'])
replacements['ITEM_SUBTITLE'] = dig_hash(meta, 'itunes', 'subtitle') if blank?(replacements['ITEM_SUBTITLE'])
replacements['ITEM_LINK'] = meta['link'] if blank?(replacements['ITEM_LINK'])

if blank?(replacements['ITEM_LINK'])
	# If the meta doesn't specify a link, generate one based on PODCAST_LINK and a slugified title.
	# Also ensure a placeholder HTML page exists (executed mode only).
	base = replacements['PODCAST_LINK'].to_s.sub(%r{/*\z}, '')
	slug = machine_name(replacements['ITEM_TITLE'])
	if !blank?(base) && !blank?(slug)
		replacements['ITEM_LINK'] = "#{base}/episodes/#{slug}.html"
		ensure_coming_soon_html_exists(replacements['ITEM_LINK'], slug)
	end
end
replacements['ITEM_GUID'] = dig_hash(meta, 'guid', 'value') || meta['guid'] if blank?(replacements['ITEM_GUID'])
replacements['ITEM_PUBDATE'] = meta['pubDate'] if blank?(replacements['ITEM_PUBDATE'])

if blank?(replacements['ITEM_PUBDATE'])
	# pubDate defaults to the creation/birth time of podcast/<episode>/audio.mp3.
	# On macOS, File.birthtime is available; if not, pubDate stays as a placeholder.
	audio_path = File.join(item_path, 'audio.mp3')
	begin
		if File.exist?(audio_path)
			birth = File.birthtime(audio_path)
			replacements['ITEM_PUBDATE'] = rss_date_gmt(birth)
		end
	rescue StandardError
		# Leave as placeholder if birthtime isn't available.
	end
end
replacements['ITEM_DESCRIPTION'] = meta['description'] if blank?(replacements['ITEM_DESCRIPTION'])

if blank?(replacements['ITEM_GUID_ISPERMALINK'])
	# Only relevant if meta.yml provides a nested guid structure.
	is_permalink = dig_hash(meta, 'guid', 'isPermaLink')
	unless is_permalink.nil?
		replacements['ITEM_GUID_ISPERMALINK'] = (is_permalink == true ? 'true' : (is_permalink == false ? 'false' : is_permalink.to_s))
	end
end

replacements['ITEM_CONTENT_ENCODED'] = meta['content_html'] || meta['content_encoded'] || meta['content'] if blank?(replacements['ITEM_CONTENT_ENCODED'])
replacements['ITEM_ENCLOSURE_LENGTH'] = dig_hash(meta, 'enclosure', 'length') if blank?(replacements['ITEM_ENCLOSURE_LENGTH'])
replacements['ITEM_ENCLOSURE_TYPE'] = dig_hash(meta, 'enclosure', 'type') if blank?(replacements['ITEM_ENCLOSURE_TYPE'])

if blank?(replacements['ITEM_ENCLOSURE_LENGTH'])
	# enclosure length in bytes comes from the file size.
	audio_path = File.join(item_path, 'audio.mp3')
	begin
		if File.exist?(audio_path)
			replacements['ITEM_ENCLOSURE_LENGTH'] = File.size(audio_path).to_s
		end
	rescue StandardError
		# Leave as placeholder if size can't be determined.
	end
end

if blank?(replacements['ITEM_ENCLOSURE_TYPE'])
	# MIME type is primarily derived from the file extension; falls back to `file --mime-type`.
	audio_path = File.join(item_path, 'audio.mp3')
	begin
		if File.exist?(audio_path)
			ext = File.extname(audio_path).downcase
			mime = case ext
					 when '.mp3' then 'audio/mpeg'
					 when '.m4a' then 'audio/mp4'
					 when '.wav' then 'audio/wav'
					 when '.ogg' then 'audio/ogg'
					 else ''
					 end

			if blank?(mime)
				begin
					mime = IO.popen(['file', '-b', '--mime-type', audio_path], &:read).to_s.strip
				rescue StandardError
					mime = ''
				end
			end

			replacements['ITEM_ENCLOSURE_TYPE'] = mime unless blank?(mime)
		end
	rescue StandardError
		# Leave as placeholder if type can't be determined.
	end
end

if blank?(replacements['ITEM_DURATION'])
	# Playback duration is derived via ffprobe when available.
	# For a placeholder empty mp3, we output 00:00:00.
	audio_path = File.join(item_path, 'audio.mp3')
	begin
		if File.exist?(audio_path)
			if File.size(audio_path).to_i == 0
				replacements['ITEM_DURATION'] = '00:00:00'
			elsif command_exists?('ffprobe')
				stdout, _stderr, status = Open3.capture3(
					'ffprobe',
					'-v', 'error',
					'-show_entries', 'format=duration',
					'-of', 'default=nw=1:nk=1',
					audio_path
				)

				if status.success? && !blank?(stdout)
					seconds = stdout.to_f
					replacements['ITEM_DURATION'] = format_hhmmss(seconds.round)
				end
			end
		end
	rescue StandardError
		# Leave as placeholder if duration can't be determined.
	end
end
replacements['ITEM_DURATION'] = dig_hash(meta, 'itunes', 'duration') if blank?(replacements['ITEM_DURATION'])
replacements['ITEM_EPISODE'] = dig_hash(meta, 'itunes', 'episode') if blank?(replacements['ITEM_EPISODE'])
replacements['ITEM_SEASON'] = dig_hash(meta, 'itunes', 'season') if blank?(replacements['ITEM_SEASON'])
replacements['ITEM_ITUNES_IMAGE_HREF'] = dig_hash(meta, 'itunes', 'image') || dig_hash(meta, 'itunes', 'image_href') if blank?(replacements['ITEM_ITUNES_IMAGE_HREF'])

if blank?(replacements['ITEM_ITUNES_IMAGE_HREF'])
	# Default episode image is the global cover.
	base = replacements['PODCAST_LINK'].to_s.sub(%r{/*\z}, '')
	replacements['ITEM_ITUNES_IMAGE_HREF'] = "#{base}/images/cover.jpg" unless blank?(base)
end

replacements['ITEM_PODCAST_CHAPTERS_URL'] = dig_hash(meta, 'podcast', 'chapters', 'url') if blank?(replacements['ITEM_PODCAST_CHAPTERS_URL'])

if blank?(replacements['ITEM_PODCAST_CHAPTERS_URL'])
	# Default chapters URL uses the episode slug.
	base = replacements['PODCAST_LINK'].to_s.sub(%r{/*\z}, '')
	replacements['ITEM_PODCAST_CHAPTERS_URL'] = "#{base}/chapters/#{episode_slug}.json" unless blank?(base) || blank?(episode_slug)
end

ensure_chapters_json_exists(replacements['ITEM_PODCAST_CHAPTERS_URL'], chapters_template_path, replacements)

replacements['ITEM_PODCAST_CHAPTERS_TYPE'] = dig_hash(meta, 'podcast', 'chapters', 'type') if blank?(replacements['ITEM_PODCAST_CHAPTERS_TYPE'])
replacements['ITEM_PODCAST_TRANSCRIPT_URL'] = dig_hash(meta, 'podcast', 'transcript', 'url') if blank?(replacements['ITEM_PODCAST_TRANSCRIPT_URL'])
replacements['ITEM_PODCAST_TRANSCRIPT_TYPE'] = dig_hash(meta, 'podcast', 'transcript', 'type') if blank?(replacements['ITEM_PODCAST_TRANSCRIPT_TYPE'])

# Categories

# ITEM_CATEGORIES injects multiple <category> tags. This keeps the item template clean.
categories = normalize_categories(meta['CATEGORIES'] || meta['categories'] || meta['Categories'])

if blank?(replacements['ITEM_CATEGORIES'])
	indent = (template.match(/^(\s*)\[ITEM_CATEGORIES\]/) || [nil, ''])[1]
	tags = categories.map { |c| "<category>#{xml_escape(c)}</category>" }
	replacements['ITEM_CATEGORIES'] = tags.join("\n#{indent}")
end

# Back-compat: older templates with ITEM_CATEGORY_1..5
if blank?(replacements['ITEM_CATEGORY_1'])
	5.times do |i|
		key = "ITEM_CATEGORY_#{i + 1}"
		replacements[key] = categories[i].to_s if blank?(replacements[key]) && categories[i]
	end
end

rendered = template.dup

# Inside CDATA: do not XML-escape.
content_encoded = replacements['ITEM_CONTENT_ENCODED']
rendered.gsub!('[ITEM_CONTENT_ENCODED]', content_encoded.to_s) unless blank?(content_encoded)

# Pre-render XML snippets that must not be escaped.
item_categories = replacements['ITEM_CATEGORIES']
rendered.gsub!('[ITEM_CATEGORIES]', item_categories.to_s) unless item_categories.nil?

replacements.each do |key, value|
	# Skip placeholders that are injected raw.
	next if key == 'ITEM_CONTENT_ENCODED'
	next if key == 'ITEM_CATEGORIES'
	next if blank?(value)
	rendered.gsub!("[#{key}]", xml_escape(value))
end

puts rendered
puts
RUBY
	)"

	ITEMS+="${rendered_item}"$'\n\n'
done

shopt -u nullglob


###
# Render global podcast feed (podcast_global.xml)
###

GLOBAL_TEMPLATE_PATH="podcast_global.xml"

if [[ ! -f "$GLOBAL_TEMPLATE_PATH" ]]; then
	echo "Missing global template: $GLOBAL_TEMPLATE_PATH" >&2
	exit 1
fi

export ITEMS
export LAST_BUILD_DATE

PODCAST_XML="$(ruby -ryaml - "config.yml" "$GLOBAL_TEMPLATE_PATH" <<'RUBY'
config_path, template_path = ARGV

def xml_escape(value)
	# Minimal XML escaping for the global template substitution.
	value.to_s
		 .gsub('&', '&amp;')
		 .gsub('<', '&lt;')
		 .gsub('>', '&gt;')
		 .gsub('"', '&quot;')
		 .gsub("'", '&apos;')
end

def blank?(value)
	value.nil? || value.to_s.strip.empty?
end

config = YAML.load_file(config_path) || {}
template = File.read(template_path)

items = ENV['ITEMS'].to_s
last_build_date = ENV['LAST_BUILD_DATE'].to_s

rendered = template.dup

# Insert raw XML blocks (no escaping)
rendered.gsub!('[ITEMS]', items) unless blank?(items)

replacements = {}
config.each { |k, v| replacements[k.to_s] = v }
replacements['LASTBUILDDATE'] = last_build_date unless blank?(last_build_date)

replacements.each do |key, value|
	next if blank?(value)
	rendered.gsub!("[#{key}]", xml_escape(value))
end

puts rendered
RUBY
)"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	# Write the output feed to disk.
	mkdir -p docs
	printf '%s\n' "$PODCAST_XML" > docs/podcast.xml

	# Prettify docs/podcast.xml in-place.
	# - xmllint is preferred (fast, stable)
	# - python fallback uses stdlib minidom
	if command -v xmllint >/dev/null 2>&1; then
		xmllint --format docs/podcast.xml > docs/podcast.xml.tmp && mv docs/podcast.xml.tmp docs/podcast.xml
	else
		python3 - <<'PY'
from __future__ import annotations

from pathlib import Path
import xml.dom.minidom as minidom

path = Path('docs/podcast.xml')
xml_text = path.read_text(encoding='utf-8')
doc = minidom.parseString(xml_text.encode('utf-8'))
pretty = doc.toprettyxml(indent='  ', encoding='utf-8').decode('utf-8')

# minidom adds extra blank lines; strip those.
pretty = "\n".join(line for line in pretty.splitlines() if line.strip()) + "\n"

path.write_text(pretty, encoding='utf-8')
PY
	fi
fi

# Episode chapters are generated during the per-episode loop above.

