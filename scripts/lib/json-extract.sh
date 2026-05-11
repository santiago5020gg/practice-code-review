#!/usr/bin/env bash
# scripts/lib/json-extract.sh

set -euo pipefail

extract_json() {
  local raw_file="$1"
  local out_file="$2"

  # Strategy 1: Direct JSON — entire file is valid JSON with "verdict" or top-level array
  if jq -e 'if type == "array" then true elif .verdict then true else false end' "$raw_file" > /dev/null 2>&1; then
    cp "$raw_file" "$out_file"
    return 0
  fi

  # Strategy 2: Envelope with .result field
  if jq -e '.result' "$raw_file" > /dev/null 2>&1; then
    local result_type
    result_type=$(jq -r '.result | type' "$raw_file")
    if [[ "$result_type" == "string" ]]; then
      local result_text
      result_text=$(jq -r '.result' "$raw_file")
      # Try direct parse first
      echo "$result_text" | jq '.' > "$out_file" 2>/dev/null && return 0
      # Strip markdown code fences and retry
      local stripped
      stripped=$(echo "$result_text" | sed -n '/^```json/,/^```$/p' | sed '1d;$d')
      if [[ -n "$stripped" ]]; then
        echo "$stripped" | jq '.' > "$out_file" 2>/dev/null && return 0
      fi
      # Try stripping any ``` fences (not just ```json)
      stripped=$(echo "$result_text" | sed -n '/^```/,/^```$/p' | sed '1d;$d')
      if [[ -n "$stripped" ]]; then
        echo "$stripped" | jq '.' > "$out_file" 2>/dev/null && return 0
      fi
    else
      jq '.result' "$raw_file" > "$out_file"
      return 0
    fi
  fi

  # Strategy 3: Content blocks array (messages API format)
  if jq -e '.content[0].text' "$raw_file" > /dev/null 2>&1; then
    local text
    text=$(jq -r '.content[0].text' "$raw_file")
    echo "$text" | jq '.' > "$out_file" 2>/dev/null && return 0
    local fenced
    fenced=$(echo "$text" | sed -n '/^```json/,/^```$/p' | sed '1d;$d')
    if [[ -n "$fenced" ]]; then
      echo "$fenced" | jq '.' > "$out_file" 2>/dev/null && return 0
    fi
  fi

  # Strategy 4: Embedded JSON in text (find first { or [ that parses)
  local content
  content=$(cat "$raw_file")
  local fenced
  fenced=$(echo "$content" | sed -n '/^```json/,/^```$/p' | sed '1d;$d')
  if [[ -n "$fenced" ]]; then
    echo "$fenced" | jq '.' > "$out_file" 2>/dev/null && return 0
  fi
  local first_brace first_bracket start
  first_brace=$(echo "$content" | grep -n '{' | head -1 | cut -d: -f1)
  first_bracket=$(echo "$content" | grep -n '\[' | head -1 | cut -d: -f1)
  if [[ -n "$first_brace" && -n "$first_bracket" ]]; then
    start=$((first_brace < first_bracket ? first_brace : first_bracket))
  elif [[ -n "$first_brace" ]]; then
    start=$first_brace
  elif [[ -n "$first_bracket" ]]; then
    start=$first_bracket
  else
    return 1
  fi
  echo "$content" | tail -n +"$start" | jq '.' > "$out_file" 2>/dev/null && return 0

  return 1
}
