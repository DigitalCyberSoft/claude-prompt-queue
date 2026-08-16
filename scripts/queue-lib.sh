# Shared helpers for the prompt-queue hooks. Pure bash/awk/sed — no jq.

# Queue file: tasks separated by the ASCII record-separator byte, so tasks
# may contain newlines. Each task is followed by one separator.
PQ_RS=$'\x1e'

pq_queue_dir() {
  printf '%s' "${CLAUDE_PLUGIN_DATA:-/tmp}/queue"
}

# Extracts the JSON-escaped "prompt" string from hook input on stdin and
# unescapes it. \uXXXX sequences are kept literally: they only ever encode
# control characters here (Claude Code emits other text as raw UTF-8), and
# leaving them as plain ASCII keeps them safe to re-emit. Physical newlines
# only occur between JSON tokens, so dropping them is safe.
pq_extract_prompt() {
  awk '
  { doc = doc $0 }
  END {
    if (!match(doc, /"prompt"[ \t]*:[ \t]*"/)) exit
    s = substr(doc, RSTART + RLENGTH)
    n = length(s); out = ""
    for (j = 1; j <= n; j++) {
      c = substr(s, j, 1)
      if (c == "\\") {
        j++; e = substr(s, j, 1)
        if (e == "n") out = out "\n"
        else if (e == "t") out = out "\t"
        else if (e == "r") out = out "\r"
        else if (e == "\"") out = out "\""
        else if (e == "\\") out = out "\\"
        else if (e == "/") out = out "/"
        else if (e == "b" || e == "f") { }
        else out = out "\\" e
      } else if (c == "\"") break
      else out = out c
    }
    printf "%s", out
  }'
}

# Session ids are UUIDs, so a plain field grab is enough
pq_extract_session_id() {
  tr -d '\n' | sed -nE 's/.*"session_id"[[:space:]]*:[[:space:]]*"([^"]*)".*/\1/p'
}

# JSON-encodes a string, including the surrounding quotes
pq_json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  printf '"%s"' "$s"
}

# Loads the session queue into PQ_ITEMS
pq_load_queue() {
  local file="$1" item
  PQ_ITEMS=()
  if [ -s "$file" ]; then
    while IFS= read -r -d "$PQ_RS" item; do
      [ -n "$item" ] && PQ_ITEMS+=("$item")
    done < "$file"
  fi
}

# Rewrites the queue file from the given tasks; no tasks removes it
pq_save_queue() {
  local file="$1" item
  shift
  if [ "$#" -eq 0 ]; then
    rm -f "$file"
    return 0
  fi
  mkdir -p "$(dirname "$file")"
  {
    for item in "$@"; do
      printf '%s%s' "$item" "$PQ_RS"
    done
  } > "$file.tmp" && mv "$file.tmp" "$file"
}
