#!/usr/bin/env bash
# Read a single field for a tool from tools/tools.yaml.
#
# Usage: manifest-get.sh <tool> <field> [host]
#
# Tool-level fields (no host): version, license, source, kind, image, note.
# Host-level fields (host required): url, sha256, archive, path.
# <host> is one of: darwin/arm64, linux/amd64, linux/arm64.
#
# tools.yaml is hand-authored with a fixed 2-space indent: a tool is at indent 2
# ("  name:"), an artifact host at indent 6 ('      "host":'), a field at
# indent 4 (tool-level) or 8 (host-level). This script is a small, reviewable
# reader for that exact shape, not a YAML parser. If the manifest structure
# changes, update this reader.
#
# Prints the value (empty when absent); exits 2 on usage error.

set -euo pipefail

if [[ $# -lt 2 ]]; then
	echo "usage: $0 <tool> <field> [host]" >&2
	exit 2
fi

tool=$1
field=$2
host=${3:-}
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
manifest="$root/tools/tools.yaml"

if [[ ! -f "$manifest" ]]; then
	echo "manifest-get: missing $manifest" >&2
	exit 2
fi

awk -v tool="$tool" -v field="$field" -v host="$host" '
function leading(s,   i, c) {
	for (i = 1; i <= length(s); i++) {
		c = substr(s, i, 1)
		if (c != " ") return i - 1
	}
	return length(s)
}
function clean(s) {
	sub(/#.*/, "", s)
	gsub(/[ \t]+$/, "", s)
	gsub(/^[ \t]+/, "", s)
	if (length(s) >= 2 && substr(s, 1, 1) == "\"" && substr(s, length(s), 1) == "\"")
		s = substr(s, 2, length(s) - 2)
	return s
}
{
	ind = leading($0)
	rest = $0
	sub(/^ +/, "", rest)
}
# Tool boundary at exactly 2 spaces ends the previous scope and may open ours.
ind == 2 {
	intool = (rest ~ "^" tool ":") ? 1 : 0
	inhost = 0
	next
}
!intool { next }
# Artifact host block at 6 spaces.
ind == 6 {
	inhost = (host != "" && rest ~ "^\"" host "\":") ? 1 : 0
	next
}
# Host-level field at 8 spaces.
host != "" {
	if (inhost && ind == 8 && rest ~ "^" field ":") {
		val = rest
		sub("^" field ":", "", val)
		print clean(val)
		exit
	}
	next
}
# Tool-level field at 4 spaces.
{
	if (ind == 4 && rest ~ "^" field ":") {
		val = rest
		sub("^" field ":", "", val)
		print clean(val)
		exit
	}
}
' "$manifest"
