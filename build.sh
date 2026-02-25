#!/usr/bin/env bash

## build.sh
#
# Purpose
# - Generates a complete podcast RSS feed XML using a global template + per-episode templates.
# - Generates per-episode Podcasting 2.0 chapters JSON files.
# - Creates episode HTML pages under docs/episodes/.
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
# - docs/episodes/*.html: per-episode detail pages.
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

def xml_escape(value)
	value.to_s
			 .gsub('&', '&amp;')
			 .gsub('<', '&lt;')
			 .gsub('>', '&gt;')
			 .gsub('"', '&quot;')
			 .gsub("'", '&apos;')
end

def html_escape(value)
	value.to_s
			 .gsub('&', '&amp;')
			 .gsub('<', '&lt;')
			 .gsub('>', '&gt;')
			 .gsub('"', '&quot;')
			 .gsub("'", '&#39;')
end

def normalize_categories(value)
	case value
	when Array
		value.map(&:to_s)
	when String
		value.split(/[\,\n]/)
	else
		[]
	end.map { |c| c.strip }.reject(&:empty?)
end

def dig_hash(hash, *keys)
	keys.reduce(hash) { |acc, key| acc.is_a?(Hash) ? acc[key] : nil }
end

def machine_name(value)
	value.to_s
		 .downcase
		 .gsub(/[^a-z0-9]+/, '-')
		 .gsub(/\A-+|-+\z/, '')
end

def rss_date_gmt(time)
	time.utc.strftime('%a, %d %b %Y %H:%M:%S GMT')
end

def format_hhmmss(total_seconds)
	total_seconds = total_seconds.to_i
	hours = total_seconds / 3600
	minutes = (total_seconds % 3600) / 60
	seconds = total_seconds % 60
	format('%02d:%02d:%02d', hours, minutes, seconds)
end

def command_exists?(cmd)
	system("command -v #{cmd} >/dev/null 2>&1")
end

def execution_mode?
	ENV.fetch('BUILD_WRITE_FILES', '0').to_s == '1'
end

def human_date_for_audio(audio_path)
	return nil unless File.exist?(audio_path)

	time = begin
		File.birthtime(audio_path)
	rescue StandardError
		begin
			File.mtime(audio_path)
		rescue StandardError
			nil
		end
	end

	return nil unless time
	time.strftime('%-d %b %Y').upcase
end

def parse_chapters(meta)
	chapters = []
	meta.each do |key, value|
		key = key.to_s
		m = key.match(/\A(?<prefix>PODCAST_(?:COMMERCIAL_)?BLOCK_\d+)_START_TIME\z/)
		next unless m

		prefix = m[:prefix]
		title_key = "#{prefix}_TITLE"
		title = meta[title_key] || meta[title_key.to_sym]
		next if title.to_s.strip.empty?

		start_seconds = begin
			Integer(value)
		rescue StandardError
			nil
		end
		next if start_seconds.nil?

		chapters << { start: start_seconds, title: title.to_s }
	end
	chapters.sort_by { |c| c[:start] }
end

def json_escape_fragment(value)
	JSON.generate(value.to_s)[1..-2]
end

def render_chapters_json(chapters_template, replacements)
	rendered = chapters_template.dup

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

	JSON.pretty_generate(JSON.parse(rendered)) + "\n"
end

def ensure_chapters_json_exists(chapters_url, chapters_template_path, replacements)
	return unless execution_mode?
	return if chapters_url.nil? || chapters_url.to_s.strip.empty?
	return unless File.file?(chapters_template_path)

	path = begin
		uri = URI.parse(chapters_url.to_s)
		uri.path
	rescue URI::InvalidURIError
		chapters_url.to_s
	end

	path = '/' + path unless path.start_with?('/')
	rel = path.sub(%r{\A/+}, '')
	file_path = File.join('docs', rel)

	FileUtils.mkdir_p(File.dirname(file_path))
	chapters_template = File.read(chapters_template_path)
	json = render_chapters_json(chapters_template, replacements)
	File.write(file_path, json)
end

def write_episode_page(replacements, meta, item_path:, page_slug:)
	return unless execution_mode?
	return if page_slug.to_s.strip.empty?

	title = replacements['ITEM_TITLE'].to_s
	subtitle = replacements['ITEM_SUBTITLE'].to_s
	description = replacements['ITEM_DESCRIPTION'].to_s
	duration = replacements['ITEM_DURATION'].to_s
	season = replacements['ITEM_SEASON'].to_s
	episode_number = replacements['ITEM_EPISODE'].to_s

	podcast_name = replacements['PODCAST_NAME'].to_s
	podcast_name = 'The 50 Shades of Beer Podcast' if podcast_name.strip.empty?

	audio_rel = replacements['ITEM_PATH'].to_s
	audio_url = audio_rel.strip.empty? ? '' : "https://media.xandist.site/#{audio_rel}"
	chapters_url = replacements['ITEM_PODCAST_CHAPTERS_URL'].to_s

	audio_path = File.join(item_path.to_s, 'audio.mp3')
	posted = human_date_for_audio(audio_path)

	categories = normalize_categories(meta['CATEGORIES'] || meta['categories'] || meta['Categories'])
	chapters = parse_chapters(meta)

	FileUtils.mkdir_p(File.join('docs', 'episodes'))
	file_path = File.join('docs', 'episodes', "#{page_slug}.html")

	html = +''
	html << "<!doctype html>\n"
	html << "<html lang=\"en\">\n"
	html << "\t<head>\n"
	html << "\t\t<meta charset=\"utf-8\" />\n"
	html << "\t\t<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />\n"
	html << "\t\t<meta name=\"description\" content=\"#{html_escape(description.empty? ? title : description)}\" />\n"
	html << "\t\t<title>#{html_escape(title)} • #{html_escape(podcast_name)}</title>\n"
	html << "\n"
	html << "\t\t<link rel=\"preconnect\" href=\"https://cdn.jsdelivr.net\" />\n"
	html << "\t\t<link\n"
	html << "\t\t\thref=\"https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css\"\n"
	html << "\t\t\trel=\"stylesheet\"\n"
	html << "\t\t\tintegrity=\"sha384-QWTKZyjpPEjISv5WaRU9OFeRpok6YctnYmDr5pNlyT2bRjXh0JMhjY6hW+ALEwIH\"\n"
	html << "\t\t\tcrossorigin=\"anonymous\"\n"
	html << "\t\t/>\n"
	html << "\t\t<link\n"
	html << "\t\t\trel=\"stylesheet\"\n"
	html << "\t\t\thref=\"https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.min.css\"\n"
	html << "\t\t/>\n"
	html << "\n"
	html << "\t\t<style>\n"
	html << "\t\t\t:root { color-scheme: dark; }\n"
	html << "\t\t\t.hero {\n"
	html << "\t\t\t\tbackground: radial-gradient(1200px circle at 20% 10%, rgba(13,110,253,0.20), transparent 55%),\n"
	html << "\t\t\t\t\t\t\t\t\tradial-gradient(900px circle at 70% 40%, rgba(111,66,193,0.20), transparent 55%);\n"
	html << "\t\t\t}\n"
	html << "\t\t\t.glass {\n"
	html << "\t\t\t\tbackground: rgba(255,255,255,0.06);\n"
	html << "\t\t\t\tborder: 1px solid rgba(255,255,255,0.10);\n"
	html << "\t\t\t\tbackdrop-filter: blur(10px);\n"
	html << "\t\t\t}\n"
	html << "\t\t\t.text-muted-2 { color: rgba(255,255,255,0.70) !important; }\n"
	html << "\t\t</style>\n"
	html << "\t</head>\n"
	html << "\t<body class=\"text-bg-dark\">\n"

	html << "\t\t<nav class=\"navbar navbar-expand-lg navbar-dark border-bottom border-secondary-subtle\">\n"
	html << "\t\t\t<div class=\"container\">\n"
	html << "\t\t\t\t<a class=\"navbar-brand fw-semibold\" href=\"../index.html\">\n"
	html << "\t\t\t\t\t<span class=\"me-2\"><i class=\"bi bi-mic-fill\"></i></span>\n"
	html << "\t\t\t\t\tThe 50 Shades of Beer Podcast\n"
	html << "\t\t\t\t</a>\n"
	html << "\t\t\t\t<button\n"
	html << "\t\t\t\t\tclass=\"navbar-toggler\"\n"
	html << "\t\t\t\t\ttype=\"button\"\n"
	html << "\t\t\t\t\tdata-bs-toggle=\"collapse\"\n"
	html << "\t\t\t\t\tdata-bs-target=\"#navMain\"\n"
	html << "\t\t\t\t\taria-controls=\"navMain\"\n"
	html << "\t\t\t\t\taria-expanded=\"false\"\n"
	html << "\t\t\t\t\taria-label=\"Toggle navigation\"\n"
	html << "\t\t\t\t>\n"
	html << "\t\t\t\t\t<span class=\"navbar-toggler-icon\"></span>\n"
	html << "\t\t\t\t</button>\n"
	html << "\t\t\t\t<div class=\"collapse navbar-collapse\" id=\"navMain\">\n"
	html << "\t\t\t\t\t<ul class=\"navbar-nav ms-auto mb-2 mb-lg-0\">\n"
	html << "\t\t\t\t\t\t<li class=\"nav-item\"><a class=\"nav-link\" href=\"../index.html\">Home</a></li>\n"
	html << "\t\t\t\t\t\t<li class=\"nav-item\"><a class=\"nav-link\" href=\"../about.html\">About</a></li>\n"
	html << "\t\t\t\t\t\t<li class=\"nav-item\"><a class=\"nav-link\" href=\"../support.html\">Support</a></li>\n"
	html << "\t\t\t\t\t\t<li class=\"nav-item\"><a class=\"nav-link\" href=\"../podcast.xml\">RSS</a></li>\n"
	html << "\t\t\t\t\t\t<li class=\"nav-item\"><a class=\"nav-link active\" aria-current=\"page\" href=\"index.html\">Episodes</a></li>\n"
	html << "\t\t\t\t\t</ul>\n"
	html << "\t\t\t\t</div>\n"
	html << "\t\t\t</div>\n"
	html << "\t\t</nav>\n"

	html << "\n"
	html << "\t\t<header class=\"hero py-5\">\n"
	html << "\t\t\t<div class=\"container py-4\">\n"
	html << "\t\t\t\t<div class=\"mb-3\"><a class=\"link-light text-decoration-none\" href=\"index.html\"><i class=\"bi bi-arrow-left me-2\"></i>All episodes</a></div>\n"
	html << "\t\t\t\t<h1 class=\"display-6 fw-bold mb-2\">#{html_escape(title)}</h1>\n"
	unless subtitle.strip.empty?
		html << "\t\t\t\t<p class=\"lead text-muted-2 mb-0\">#{html_escape(subtitle)}</p>\n"
	end
	html << "\t\t\t</div>\n"
	html << "\t\t</header>\n"

	meta_bits = []
	meta_bits << "S#{season}E#{episode_number}" unless season.strip.empty? || episode_number.strip.empty?
	meta_bits << posted if posted
	meta_bits << duration unless duration.strip.empty?

	html << "\n"
	html << "\t\t<main class=\"py-5\">\n"
	html << "\t\t\t<div class=\"container\">\n"
	unless meta_bits.empty?
		html << "\t\t\t\t<p class=\"small text-muted-2\">#{html_escape(meta_bits.join(' • '))}</p>\n"
	end

	html << "\t\t\t\t<div class=\"d-flex flex-wrap gap-2 mb-4\">\n"
	html << "\t\t\t\t\t<a class=\"btn btn-primary\" href=\"#{html_escape(audio_url)}\"#{audio_url.empty? ? ' aria-disabled=\"true\" tabindex=\"-1\"' : ''}><i class=\"bi bi-play-circle me-2\"></i>Audio</a>\n"
	unless chapters_url.strip.empty?
		html << "\t\t\t\t\t<a class=\"btn btn-outline-light\" href=\"#{html_escape(chapters_url)}\"><i class=\"bi bi-list-ol me-2\"></i>Chapters JSON</a>\n"
	end
	html << "\t\t\t\t</div>\n"

	html << "\t\t\t\t<div class=\"card text-bg-dark border-secondary-subtle mb-4\"><div class=\"card-body p-4\">\n"
	html << "\t\t\t\t\t<h2 class=\"h5 fw-semibold\">Description</h2>\n"
	html << "\t\t\t\t\t<p class=\"text-muted-2 mb-0\">#{html_escape(description)}</p>\n"
	html << "\t\t\t\t</div></div>\n"

	unless chapters.empty?
		html << "\t\t\t\t<div class=\"card text-bg-dark border-secondary-subtle mb-4\"><div class=\"card-body p-4\">\n"
		html << "\t\t\t\t\t<h2 class=\"h5 fw-semibold\">Chapters</h2>\n"
		html << "\t\t\t\t\t<div class=\"list-group list-group-flush\">\n"
		chapters.each do |c|
			html << "\t\t\t\t\t\t<div class=\"list-group-item bg-transparent text-light border-secondary-subtle d-flex justify-content-between align-items-start\">\n"
			html << "\t\t\t\t\t\t\t<div class=\"me-3\">#{html_escape(c[:title])}</div>\n"
			html << "\t\t\t\t\t\t\t<div class=\"text-muted-2 small\">#{html_escape(format_hhmmss(c[:start]))}</div>\n"
			html << "\t\t\t\t\t\t</div>\n"
		end
		html << "\t\t\t\t\t</div>\n"
		html << "\t\t\t\t</div></div>\n"
	end

	unless categories.empty?
		html << "\t\t\t\t<div class=\"card text-bg-dark border-secondary-subtle\"><div class=\"card-body p-4\">\n"
		html << "\t\t\t\t\t<h2 class=\"h5 fw-semibold\">Categories</h2>\n"
		html << "\t\t\t\t\t<div class=\"d-flex flex-wrap gap-2\">\n"
		categories.each do |c|
			html << "\t\t\t\t\t\t<span class=\"badge text-bg-secondary\">#{html_escape(c)}</span>\n"
		end
		html << "\t\t\t\t\t</div>\n"
		html << "\t\t\t\t</div></div>\n"
	end

	html << "\t\t\t</div>\n"
	html << "\t\t</main>\n"

	html << "\n"
	html << "\t\t<script\n"
	html << "\t\t\tsrc=\"https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js\"\n"
	html << "\t\t\tintegrity=\"sha384-YvpcrYf0tY3lHB60NNkmXc5s9fDVZLESaAA55NDzOxhy9GkcIdslK1eN7N6jIeHz\"\n"
	html << "\t\t\tcrossorigin=\"anonymous\"\n"
	html << "\t\t></script>\n"
	html << "\t</body>\n"
	html << "</html>\n"

	File.write(file_path, html)
end

config = YAML.load_file(config_path) || {}
meta = YAML.load_file(meta_path) || {}
template = File.read(template_path)

def blank?(value)
	value.nil? || value.to_s.strip.empty?
end

replacements = {}
config.each { |k, v| replacements[k.to_s] = v }
meta.each { |k, v| replacements[k.to_s] = v }

episode_slug = File.basename(item_path.to_s)
replacements['ITEM_PATH'] = File.join(episode_slug, 'audio.mp3')

if (match = episode_slug.match(/\As(?<season>\d+)e(?<episode>\d+)\z/i))
	replacements['ITEM_SEASON'] = match[:season] if blank?(replacements['ITEM_SEASON'])
	replacements['ITEM_EPISODE'] = match[:episode] if blank?(replacements['ITEM_EPISODE'])
end

replacements['ITEM_TITLE'] = meta['title'] || dig_hash(meta, 'itunes', 'title') if blank?(replacements['ITEM_TITLE'])
replacements['ITEM_SUBTITLE'] = dig_hash(meta, 'itunes', 'subtitle') if blank?(replacements['ITEM_SUBTITLE'])
replacements['ITEM_LINK'] = meta['link'] if blank?(replacements['ITEM_LINK'])

page_slug = machine_name(replacements['ITEM_TITLE'])

if blank?(replacements['ITEM_LINK'])
	base = replacements['PODCAST_LINK'].to_s.sub(%r{/*\z}, '')
	replacements['ITEM_LINK'] = "#{base}/episodes/#{page_slug}.html" if !blank?(base) && !blank?(page_slug)
end

replacements['ITEM_GUID'] = dig_hash(meta, 'guid', 'value') || meta['guid'] if blank?(replacements['ITEM_GUID'])
replacements['ITEM_PUBDATE'] = meta['pubDate'] if blank?(replacements['ITEM_PUBDATE'])

if blank?(replacements['ITEM_PUBDATE'])
	audio_path = File.join(item_path, 'audio.mp3')
	begin
		if File.exist?(audio_path)
			birth = File.birthtime(audio_path)
			replacements['ITEM_PUBDATE'] = rss_date_gmt(birth)
		end
	rescue StandardError
	end
end

replacements['ITEM_DESCRIPTION'] = meta['description'] if blank?(replacements['ITEM_DESCRIPTION'])

replacements['ITEM_CONTENT_ENCODED'] = meta['content_html'] || meta['content_encoded'] || meta['content'] if blank?(replacements['ITEM_CONTENT_ENCODED'])
replacements['ITEM_ENCLOSURE_LENGTH'] = dig_hash(meta, 'enclosure', 'length') if blank?(replacements['ITEM_ENCLOSURE_LENGTH'])
replacements['ITEM_ENCLOSURE_TYPE'] = dig_hash(meta, 'enclosure', 'type') if blank?(replacements['ITEM_ENCLOSURE_TYPE'])

if blank?(replacements['ITEM_ENCLOSURE_LENGTH'])
	audio_path = File.join(item_path, 'audio.mp3')
	begin
		replacements['ITEM_ENCLOSURE_LENGTH'] = File.size(audio_path).to_s if File.exist?(audio_path)
	rescue StandardError
	end
end

if blank?(replacements['ITEM_ENCLOSURE_TYPE'])
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
	end
end

if blank?(replacements['ITEM_DURATION'])
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
	end
end

replacements['ITEM_DURATION'] = dig_hash(meta, 'itunes', 'duration') if blank?(replacements['ITEM_DURATION'])
replacements['ITEM_EPISODE'] = dig_hash(meta, 'itunes', 'episode') if blank?(replacements['ITEM_EPISODE'])
replacements['ITEM_SEASON'] = dig_hash(meta, 'itunes', 'season') if blank?(replacements['ITEM_SEASON'])
replacements['ITEM_ITUNES_IMAGE_HREF'] = dig_hash(meta, 'itunes', 'image') || dig_hash(meta, 'itunes', 'image_href') if blank?(replacements['ITEM_ITUNES_IMAGE_HREF'])

if blank?(replacements['ITEM_ITUNES_IMAGE_HREF'])
	base = replacements['PODCAST_LINK'].to_s.sub(%r{/*\z}, '')
	replacements['ITEM_ITUNES_IMAGE_HREF'] = "#{base}/images/cover.jpg" unless blank?(base)
end

replacements['ITEM_PODCAST_CHAPTERS_URL'] = dig_hash(meta, 'podcast', 'chapters', 'url') if blank?(replacements['ITEM_PODCAST_CHAPTERS_URL'])

if blank?(replacements['ITEM_PODCAST_CHAPTERS_URL'])
	base = replacements['PODCAST_LINK'].to_s.sub(%r{/*\z}, '')
	replacements['ITEM_PODCAST_CHAPTERS_URL'] = "#{base}/chapters/#{episode_slug}.json" unless blank?(base) || blank?(episode_slug)
end

ensure_chapters_json_exists(replacements['ITEM_PODCAST_CHAPTERS_URL'], chapters_template_path, replacements)
write_episode_page(replacements, meta, item_path: item_path, page_slug: page_slug) unless blank?(page_slug)

categories = normalize_categories(meta['CATEGORIES'] || meta['categories'] || meta['Categories'])

if blank?(replacements['ITEM_CATEGORIES'])
	indent = (template.match(/^(\s*)\[ITEM_CATEGORIES\]/) || [nil, ''])[1]
	tags = categories.map { |c| "<category>#{xml_escape(c)}</category>" }
	replacements['ITEM_CATEGORIES'] = tags.join("\n#{indent}")
end

if blank?(replacements['ITEM_CATEGORY_1'])
	5.times do |i|
		key = "ITEM_CATEGORY_#{i + 1}"
		replacements[key] = categories[i].to_s if blank?(replacements[key]) && categories[i]
	end
end

rendered = template.dup

content_encoded = replacements['ITEM_CONTENT_ENCODED']
rendered.gsub!('[ITEM_CONTENT_ENCODED]', content_encoded.to_s) unless blank?(content_encoded)

item_categories = replacements['ITEM_CATEGORIES']
rendered.gsub!('[ITEM_CATEGORIES]', item_categories.to_s) unless item_categories.nil?

replacements.each do |key, value|
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

items = ENV.fetch('ITEMS', '').to_s
last_build_date = ENV.fetch('LAST_BUILD_DATE', '').to_s

rendered = template.dup

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
		python3 -c "from pathlib import Path; import xml.dom.minidom as minidom; path = Path('docs/podcast.xml'); xml_text = path.read_text(encoding='utf-8'); doc = minidom.parseString(xml_text.encode('utf-8')); pretty = doc.toprettyxml(indent='  ', encoding='utf-8').decode('utf-8'); pretty = '\n'.join(line for line in pretty.splitlines() if line.strip()) + '\n'; path.write_text(pretty, encoding='utf-8')"
	fi

	# Generate docs/episodes/index.html (season-grouped list)
	ruby -ryaml - "config.yml" "podcast" <<'RUBY'
require 'yaml'
require 'fileutils'

config_path, podcast_root = ARGV
podcast_root ||= 'podcast'

def blank?(value)
	value.nil? || value.to_s.strip.empty?
end

def machine_name(value)
	value.to_s
		 .downcase
		 .gsub(/[^a-z0-9]+/, '-')
		 .gsub(/\A-+|-+\z/, '')
end

def html_escape(value)
	value.to_s
			 .gsub('&', '&amp;')
			 .gsub('<', '&lt;')
			 .gsub('>', '&gt;')
			 .gsub('"', '&quot;')
			 .gsub("'", '&#39;')
end

def human_date_for_audio(audio_path)
	return nil unless File.exist?(audio_path)

	time = begin
		File.birthtime(audio_path)
	rescue StandardError
		begin
			File.mtime(audio_path)
		rescue StandardError
			nil
		end
	end

	return nil unless time
	time.strftime('%-d %b %Y').upcase
end

config = (YAML.load_file(config_path) || {})
podcast_name = config['PODCAST_NAME'].to_s
podcast_name = 'The 50 Shades of Beer Podcast' if blank?(podcast_name)

episodes = []
Dir.glob(File.join(podcast_root, '*')).sort.each do |episode_dir|
	next unless File.directory?(episode_dir)

	meta_path = File.join(episode_dir, 'meta.yml')
	next unless File.file?(meta_path)

	meta = (YAML.load_file(meta_path) || {})
	episode_slug = File.basename(episode_dir)

	title = meta['ITEM_TITLE'] || meta['title'] || meta.dig('itunes', 'title')
	title = title.to_s
	next if blank?(title)

	page_slug = machine_name(title)
	next if blank?(page_slug)

	season = 0
	episode_number = 0
	if (m = episode_slug.match(/\As(?<season>\d+)e(?<episode>\d+)\z/i))
		season = m[:season].to_i
		episode_number = m[:episode].to_i
	end

	audio_path = File.join(episode_dir, 'audio.mp3')
	posted = human_date_for_audio(audio_path)

	episodes << {
		season: season,
		episode: episode_number,
		title: title,
		page_slug: page_slug,
		posted: posted
	}
end

episodes.sort_by! { |e| [e[:season], e[:episode]] }
groups = episodes.group_by { |e| e[:season] }

FileUtils.mkdir_p(File.join('docs', 'episodes'))
out_path = File.join('docs', 'episodes', 'index.html')

html = +''
html << "<!doctype html>\n"
html << "<html lang=\"en\">\n"
html << "\t<head>\n"
html << "\t\t<meta charset=\"utf-8\" />\n"
html << "\t\t<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\" />\n"
html << "\t\t<title>Episodes • #{html_escape(podcast_name)}</title>\n"
html << "\n"
html << "\t\t<link rel=\"preconnect\" href=\"https://cdn.jsdelivr.net\" />\n"
html << "\t\t<link\n"
html << "\t\t\thref=\"https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/css/bootstrap.min.css\"\n"
html << "\t\t\trel=\"stylesheet\"\n"
html << "\t\t\tintegrity=\"sha384-QWTKZyjpPEjISv5WaRU9OFeRpok6YctnYmDr5pNlyT2bRjXh0JMhjY6hW+ALEwIH\"\n"
html << "\t\t\tcrossorigin=\"anonymous\"\n"
html << "\t\t/>\n"
html << "\t\t<link\n"
html << "\t\t\trel=\"stylesheet\"\n"
html << "\t\t\thref=\"https://cdn.jsdelivr.net/npm/bootstrap-icons@1.11.3/font/bootstrap-icons.min.css\"\n"
html << "\t\t/>\n"
html << "\n"
html << "\t\t<style>\n"
html << "\t\t\t:root { color-scheme: dark; }\n"
html << "\t\t\t.hero {\n"
html << "\t\t\t\tbackground: radial-gradient(1200px circle at 20% 10%, rgba(13,110,253,0.20), transparent 55%),\n"
html << "\t\t\t\t\t\t\t\t\tradial-gradient(900px circle at 70% 40%, rgba(111,66,193,0.20), transparent 55%);\n"
html << "\t\t\t}\n"
html << "\t\t\t.glass {\n"
html << "\t\t\t\tbackground: rgba(255,255,255,0.06);\n"
html << "\t\t\t\tborder: 1px solid rgba(255,255,255,0.10);\n"
html << "\t\t\t\tbackdrop-filter: blur(10px);\n"
html << "\t\t\t}\n"
html << "\t\t\t.text-muted-2 { color: rgba(255,255,255,0.70) !important; }\n"
html << "\t\t</style>\n"
html << "\t</head>\n"
html << "\t<body class=\"text-bg-dark\">\n"

html << "\t\t<nav class=\"navbar navbar-expand-lg navbar-dark border-bottom border-secondary-subtle\">\n"
html << "\t\t\t<div class=\"container\">\n"
html << "\t\t\t\t<a class=\"navbar-brand fw-semibold\" href=\"../index.html\">\n"
html << "\t\t\t\t\t<span class=\"me-2\"><i class=\"bi bi-mic-fill\"></i></span>\n"
html << "\t\t\t\t\tThe 50 Shades of Beer Podcast\n"
html << "\t\t\t\t</a>\n"
html << "\t\t\t\t<button\n"
html << "\t\t\t\t\tclass=\"navbar-toggler\"\n"
html << "\t\t\t\t\ttype=\"button\"\n"
html << "\t\t\t\t\tdata-bs-toggle=\"collapse\"\n"
html << "\t\t\t\t\tdata-bs-target=\"#navMain\"\n"
html << "\t\t\t\t\taria-controls=\"navMain\"\n"
html << "\t\t\t\t\taria-expanded=\"false\"\n"
html << "\t\t\t\t\taria-label=\"Toggle navigation\"\n"
html << "\t\t\t\t>\n"
html << "\t\t\t\t\t<span class=\"navbar-toggler-icon\"></span>\n"
html << "\t\t\t\t</button>\n"
html << "\t\t\t\t<div class=\"collapse navbar-collapse\" id=\"navMain\">\n"
html << "\t\t\t\t\t<ul class=\"navbar-nav ms-auto mb-2 mb-lg-0\">\n"
html << "\t\t\t\t\t\t<li class=\"nav-item\"><a class=\"nav-link\" href=\"../index.html\">Home</a></li>\n"
html << "\t\t\t\t\t\t<li class=\"nav-item\"><a class=\"nav-link\" href=\"../about.html\">About</a></li>\n"
html << "\t\t\t\t\t\t<li class=\"nav-item\"><a class=\"nav-link\" href=\"../support.html\">Support</a></li>\n"
html << "\t\t\t\t\t\t<li class=\"nav-item\"><a class=\"nav-link\" href=\"../podcast.xml\">RSS</a></li>\n"
html << "\t\t\t\t\t\t<li class=\"nav-item\"><a class=\"nav-link active\" aria-current=\"page\" href=\"index.html\">Episodes</a></li>\n"
html << "\t\t\t\t\t</ul>\n"
html << "\t\t\t\t</div>\n"
html << "\t\t\t</div>\n"
html << "\t\t</nav>\n"

html << "\n"
html << "\t\t<header class=\"hero py-5\">\n"
html << "\t\t\t<div class=\"container py-4\">\n"
html << "\t\t\t\t<h1 class=\"display-6 fw-bold mb-0\">Episodes</h1>\n"
html << "\t\t\t</div>\n"
html << "\t\t</header>\n"

html << "\n"
html << "\t\t<main class=\"py-5\">\n"
html << "\t\t\t<div class=\"container\">\n"

if episodes.empty?
	html << "\t\t\t\t<div class=\"alert alert-secondary\" role=\"alert\">No episodes found.</div>\n"
else
	groups.keys.sort.each do |season|
		season_label = season.to_i > 0 ? "Season #{season}" : 'Season'
		html << "\t\t\t\t<h2 class=\"h5 fw-semibold mt-4\">#{html_escape(season_label)}</h2>\n"
		html << "\t\t\t\t<div class=\"list-group\">\n"
		groups[season].each do |e|
			meta_line = []
			meta_line << "S#{e[:season]}E#{e[:episode]}" if e[:season].to_i > 0 && e[:episode].to_i > 0
			meta_line << e[:posted] if e[:posted]

			html << "\t\t\t\t\t<a class=\"list-group-item list-group-item-action bg-transparent text-light border-secondary-subtle\" href=\"#{html_escape(e[:page_slug])}.html\">\n"
			html << "\t\t\t\t\t\t<div class=\"fw-semibold\">#{html_escape(e[:title])}</div>\n"
			unless meta_line.empty?
				html << "\t\t\t\t\t\t<div class=\"small text-muted-2\">#{html_escape(meta_line.join(' • '))}</div>\n"
			end
			html << "\t\t\t\t\t</a>\n"
		end
		html << "\t\t\t\t</div>\n"
	end
end

html << "\t\t\t</div>\n"
html << "\t\t</main>\n"
html << "\n"
html << "\t\t<script\n"
html << "\t\t\tsrc=\"https://cdn.jsdelivr.net/npm/bootstrap@5.3.3/dist/js/bootstrap.bundle.min.js\"\n"
html << "\t\t\tintegrity=\"sha384-YvpcrYf0tY3lHB60NNkmXc5s9fDVZLESaAA55NDzOxhy9GkcIdslK1eN7N6jIeHz\"\n"
html << "\t\t\tcrossorigin=\"anonymous\"\n"
html << "\t\t></script>\n"
html << "\t</body>\n"
html << "</html>\n"

File.write(out_path, html)
RUBY
fi

# Episode chapters are generated during the per-episode loop above.

