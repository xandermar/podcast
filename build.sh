## Tasks:
# 1. Generate /docs/podcast.xml
# 2. Generate episode chapters (ex: /docs/chapters/s1e1.json)
# 3. Sync audio to Cloudflare R2 (/podcast/s1e1/audio.mp3 > [cloudflare-r2]/podcast/s1e1/audio.mp3)

########################


###
# Generate /docs/podcast.xml
###

# Step 1: Generate LastBuildDate
LAST_BUILD_DATE="$(date -u +"%a, %d %b %Y %H:%M:%S GMT")"

# Step 2: Generate ITEMS
ITEMS=


###
# Render <item> XML for each episode
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
		ruby -ryaml - "config.yml" "$meta_path" "$ITEM_TEMPLATE_PATH" "$episode_dir" <<'RUBY'
config_path, meta_path, template_path, item_path = ARGV

require 'open3'

def xml_escape(value)
	value.to_s
			 .gsub('&', '&amp;')
			 .gsub('<', '&lt;')
			 .gsub('>', '&gt;')
			 .gsub('"', '&quot;')
			 .gsub("'", '&apos;')
end

def normalize_categories(value)
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

# Support nested meta schema by deriving common ITEM_* keys when absent.
replacements['ITEM_TITLE'] = meta['title'] || dig_hash(meta, 'itunes', 'title') if blank?(replacements['ITEM_TITLE'])
replacements['ITEM_SUBTITLE'] = dig_hash(meta, 'itunes', 'subtitle') if blank?(replacements['ITEM_SUBTITLE'])
replacements['ITEM_LINK'] = meta['link'] if blank?(replacements['ITEM_LINK'])

if blank?(replacements['ITEM_LINK'])
	base = replacements['PODCAST_LINK'].to_s.sub(%r{/*\z}, '')
	slug = machine_name(replacements['ITEM_TITLE'])
	replacements['ITEM_LINK'] = "#{base}/#{slug}.html" unless blank?(base) || blank?(slug)
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
		# Leave as placeholder if birthtime isn't available.
	end
end
replacements['ITEM_DESCRIPTION'] = meta['description'] if blank?(replacements['ITEM_DESCRIPTION'])

if blank?(replacements['ITEM_GUID_ISPERMALINK'])
	is_permalink = dig_hash(meta, 'guid', 'isPermaLink')
	unless is_permalink.nil?
		replacements['ITEM_GUID_ISPERMALINK'] = (is_permalink == true ? 'true' : (is_permalink == false ? 'false' : is_permalink.to_s))
	end
end

replacements['ITEM_CONTENT_ENCODED'] = meta['content_html'] || meta['content_encoded'] || meta['content'] if blank?(replacements['ITEM_CONTENT_ENCODED'])
replacements['ITEM_ENCLOSURE_LENGTH'] = dig_hash(meta, 'enclosure', 'length') if blank?(replacements['ITEM_ENCLOSURE_LENGTH'])
replacements['ITEM_ENCLOSURE_TYPE'] = dig_hash(meta, 'enclosure', 'type') if blank?(replacements['ITEM_ENCLOSURE_TYPE'])

if blank?(replacements['ITEM_ENCLOSURE_LENGTH'])
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
	base = replacements['PODCAST_LINK'].to_s.sub(%r{/*\z}, '')
	replacements['ITEM_ITUNES_IMAGE_HREF'] = "#{base}/images/cover.jpg" unless blank?(base)
end

replacements['ITEM_PODCAST_CHAPTERS_URL'] = dig_hash(meta, 'podcast', 'chapters', 'url') if blank?(replacements['ITEM_PODCAST_CHAPTERS_URL'])

if blank?(replacements['ITEM_PODCAST_CHAPTERS_URL'])
	base = replacements['PODCAST_LINK'].to_s.sub(%r{/*\z}, '')
	replacements['ITEM_PODCAST_CHAPTERS_URL'] = "#{base}/chapters/#{episode_slug}.json" unless blank?(base) || blank?(episode_slug)
end

replacements['ITEM_PODCAST_CHAPTERS_TYPE'] = dig_hash(meta, 'podcast', 'chapters', 'type') if blank?(replacements['ITEM_PODCAST_CHAPTERS_TYPE'])
replacements['ITEM_PODCAST_TRANSCRIPT_URL'] = dig_hash(meta, 'podcast', 'transcript', 'url') if blank?(replacements['ITEM_PODCAST_TRANSCRIPT_URL'])
replacements['ITEM_PODCAST_TRANSCRIPT_TYPE'] = dig_hash(meta, 'podcast', 'transcript', 'type') if blank?(replacements['ITEM_PODCAST_TRANSCRIPT_TYPE'])

# Categories
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
	mkdir -p docs
	printf '%s\n' "$PODCAST_XML" > docs/podcast.xml

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


