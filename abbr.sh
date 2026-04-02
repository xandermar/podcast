#!/usr/bin/env bash

set -euo pipefail

expand_tilde() {
  local p="$1"

  if [[ "$p" == "~" ]]; then
    printf '%s\n' "$HOME"
  elif [[ "$p" == "~/"* ]]; then
    printf '%s\n' "$HOME/${p:2}"
  else
    printf '%s\n' "$p"
  fi
}

prompt_for_file() {
  local input_file

  # -e enables readline editing and tab completion.
  read -e -p "Select file: " input_file
  echo "$input_file"
}

main() {
  local input_file abs_input dir filename base output_file

  if [[ ${1:-} != "" ]]; then
    input_file="$1"
  else
    input_file="$(prompt_for_file)"
  fi

  input_file="$(expand_tilde "$input_file")"

  if [[ -z "$input_file" ]]; then
    echo "No file selected."
    exit 1
  fi

  if [[ ! -f "$input_file" ]]; then
    echo "Error: File does not exist: $input_file"
    exit 1
  fi

  case "$input_file" in
    *.[mM][pP]3) ;;
    *)
      echo "Error: Input file must be an MP3."
      exit 1
      ;;
  esac

  if ! command -v ffmpeg >/dev/null 2>&1; then
    echo "Error: ffmpeg is not installed or not in PATH."
    exit 1
  fi

  if command -v realpath >/dev/null 2>&1; then
    abs_input="$(realpath "$input_file")"
  else
    abs_input="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$input_file")"
  fi
  dir="$(dirname "$abs_input")"
  filename="$(basename "$abs_input")"
  base="${filename%.*}"
  output_file="$dir/${base}-abbr.mp3"

  ffmpeg -i "$abs_input" \
    -af "silenceremove=start_periods=1:start_silence=0.3:start_threshold=-38dB:stop_periods=-1:stop_silence=0.3:stop_threshold=-38dB" \
    -codec:a libmp3lame \
    -q:a 2 \
    "$output_file"

  echo "Created: $output_file"
}

main "$@"
