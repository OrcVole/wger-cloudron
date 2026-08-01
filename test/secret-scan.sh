#!/bin/bash
# secret-scan.sh: the pre-publish secret and anonymity release gate for io.github.orcvole.wger.
# Derived from the Laminar package's scanner.
#
# Scans TWO surfaces and exits non-zero on ANY hit:
#   1. the publishable repo file set, meaning what a `git push` would expose
#      (tracked union untracked-but-not-ignored), and
#   2. the built container image filesystem, which is the artefact already public on GHCR.
# Run before every publish, and before flipping any image to public.
#
# Why two surfaces: .dockerignore SHOULD keep secrets out of the build context, but "should" is a
# claim. Scanning the actual image is the proof, and the image is what the world pulls.
#
# THE DENYLIST PATTERN. Box-specific, identity-specific and session-specific strings live in the
# GITIGNORED .anonymize-list, so this published script never itself leaks the very strings it hunts
# for. That is the mistake the naive "patterns inline in the tracked script" approach makes. Only
# generic credential SHAPES are inlined here. These are already in .gitignore:
#
#     .anonymize-list
#     *token*.txt
#     .env
#     .env.*
#     phase-notes/
#     .claude/
#
# .anonymize-list holds one extended-regular-expression per line, blank lines and # comments
# ignored. Populated with: the box FQDN and any subdomain of it, the private mirror host, sibling
# app names, real email addresses, the operator's usernames, and any session-specific identifier.
# If the file is absent the scan still runs but proves far less, and says so loudly.
#
# Usage: test/secret-scan.sh [IMAGE]
#   IMAGE defaults to $SCAN_IMAGE, else the dockerImage in CloudronManifest.json, else repo-only.
#   SCAN_INFISICAL_NAMES="NAME1 NAME2" additionally fetches those exact token values from Infisical
#   into a mode-600 scratch file for fixed-string matching. Off by default: it puts real secret
#   values on disk for the duration of the scan, which is a deliberate trade, not a default.
set -uo pipefail
cd "$(dirname "$0")/.." || exit 2
REPO="$PWD"
SELF="test/secret-scan.sh"

IMAGE="${1:-${SCAN_IMAGE:-}}"
if [[ -z "$IMAGE" ]]; then
  IMAGE="$(grep -oE '"dockerImage"[[:space:]]*:[[:space:]]*"[^"]+"' CloudronManifest.json 2>/dev/null \
           | grep -oE '"[^"]+"$' | tr -d '"')"
fi
CRI="$(command -v podman || command -v docker || true)"   # build host is rootless podman

umask 077
SCRATCH="$(mktemp -d)"; trap 'rm -rf "$SCRATCH"' EXIT
ANON="$SCRATCH/anon.ere"     # box, identity and session patterns, from .anonymize-list
SHAPE="$SCRATCH/shape.ere"   # generic credential shapes, inlined below
FIXED="$SCRATCH/fixed.txt"   # exact token strings, optional, never written into the repo tree

# --- generic credential shapes (safe to publish: they contain no box specifics) ---
cat > "$SHAPE" <<'ERE'
ghp_[A-Za-z0-9]{20,}
github_pat_[A-Za-z0-9_]{20,}
gho_[A-Za-z0-9]{20,}
ghs_[A-Za-z0-9]{20,}
ghr_[A-Za-z0-9]{20,}
glpat-[A-Za-z0-9_-]{20,}
xox[baprs]-[A-Za-z0-9-]{10,}
AKIA[0-9A-Z]{16}
ASIA[0-9A-Z]{16}
AIza[0-9A-Za-z_-]{35}
sk-ant-[A-Za-z0-9_-]{20,}
sk-proj-[A-Za-z0-9_-]{20,}
-----BEGIN [A-Z ]*PRIVATE KEY-----
ERE

# --- box, identity and session patterns, from the gitignored denylist ---
if [[ -f .anonymize-list ]]; then
  grep -vE '^[[:space:]]*(#|$)' .anonymize-list > "$ANON"
else
  : > "$ANON"
  echo "WARN: .anonymize-list absent. Box, identity and session strings are NOT scanned (shapes only)."
fi

# --- exact token values, opt-in, from Infisical; scratch only, never committed ---
: > "$FIXED"
if [[ -n "${SCAN_INFISICAL_NAMES:-}" ]] && command -v secret >/dev/null 2>&1; then
  for n in $SCAN_INFISICAL_NAMES; do
    secret "$n" 2>/dev/null >> "$FIXED" || echo "WARN: could not fetch $n from Infisical" >&2
  done
fi
sed -i '/^[[:space:]]*$/d' "$ANON" "$SHAPE" "$FIXED" 2>/dev/null   # a blank line matches everything

echo "patterns: $(wc -l < "$ANON") box/identity/session, $(wc -l < "$SHAPE") shapes, $(wc -l < "$FIXED") exact tokens"

fail=0
emit() {  # $1=tag  $2=grep output
  [[ -z "${2:-}" ]] && return 0
  printf '%s\n' "$2" | sed "s/^/  [$1] /"
  fail=1
}

echo "=== REPO scan: publishable file set ==="
mapfile -t FILES < <( { git ls-files; git status --short --untracked-files=all 2>/dev/null | sed -n 's/^?? //p'; } \
                      | sort -u | grep -vx "$SELF" )
if [[ ${#FILES[@]} -eq 0 ]]; then
  echo "  (no publishable files found)"
else
  echo "  ${#FILES[@]} files"
  [[ -s "$ANON"  ]] && emit anon  "$(grep -IEnHf "$ANON"  "${FILES[@]}" 2>/dev/null)"
  [[ -s "$SHAPE" ]] && emit shape "$(grep -IEnHf "$SHAPE" "${FILES[@]}" 2>/dev/null)"
  [[ -s "$FIXED" ]] && emit token "$(grep -IFnHf "$FIXED" "${FILES[@]}" 2>/dev/null)"
fi

echo "=== IMAGE scan: ${IMAGE:-<none>} ==="
if   [[ -z "$IMAGE" ]]; then echo "  (no image given; pass one as \$1 or set SCAN_IMAGE)"
elif [[ -z "$CRI"   ]]; then echo "  (no podman or docker found; skipped)"
elif ! "$CRI" image exists "$IMAGE" 2>/dev/null && ! "$CRI" image inspect "$IMAGE" >/dev/null 2>&1; then
  echo "  ($IMAGE not present locally; pull it to scan)"
else
  # grep INSIDE the image; patterns arrive on stdin. node_modules and .git pruned (upstream noise).
  img() {  # $1=E|F  $2=pattern file  $3..=dirs
    local mode="$1" pf="$2"; shift 2
    [[ -s "$pf" ]] || return 0
    "$CRI" run --rm -i --user 0 --entrypoint /bin/bash "$IMAGE" \
      -c "grep -rIn${mode}H --exclude-dir=node_modules --exclude-dir=.git -f - $* 2>/dev/null" < "$pf"
  }
  CRIT_DIRS="/app /etc /root /home /usr/local /opt"
  emit anon  "$(img E "$ANON"  $CRIT_DIRS)"
  emit token "$(img F "$FIXED" $CRIT_DIRS)"
  shp="$(img E "$SHAPE" $CRIT_DIRS)"

  # --- the inert /etc/ssh host keys: whitelist BY EXACT PATH, with a VISIBLE COUNT ---
  # cloudron/base ships three inert SSH host keys. No sshd runs in the app and the Dockerfile never
  # touches ssh, so they are noise, not a leak. Allow ONLY these exact paths, pinned by sha256, and
  # print how many key files were found versus how many are pinned. A glob such as ssh_host_*_key
  # would silently pass a real future leak; a count that does not match fails loudly. Re-verify the
  # hashes whenever the base image digest changes.
  declare -A PINNED_SSH=(
    [/etc/ssh/ssh_host_ecdsa_key]=677458f83d985da3fd7cdd208e90e4eac09da5be205425a5f96a6242dc985c33
    [/etc/ssh/ssh_host_ed25519_key]=0c575ce8d9ba487b05cc473fad4b0650fb950181028e6ac19796f86f56f22a7a
    [/etc/ssh/ssh_host_rsa_key]=ae0ea8087e90baf138d277ca52b6cf47b5010adc0e5bd84236713eee1b85de85
  )
  ssh_listing="$("$CRI" run --rm --user 0 --entrypoint /bin/bash "$IMAGE" \
                  -c 'for f in /etc/ssh/ssh_host_*_key; do [ -e "$f" ] && sha256sum "$f"; done' 2>/dev/null)"
  found=0; pinned_ok=0
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    found=$((found + 1))
    h="${line%% *}"; f="${line##* }"
    if [[ "${PINNED_SSH[$f]:-}" == "$h" ]]; then
      pinned_ok=$((pinned_ok + 1))
      echo "  (pinned-ok: $f matches the base image's inert host key)"
      shp="$(printf '%s\n' "$shp" | grep -vF "$f:" || true)"   # drop ONLY this verified exact path
    else
      emit ssh-key "$f sha256=$h is NOT a pinned base host key (new, changed or extra: treat as a leak)"
    fi
  done <<< "$ssh_listing"
  echo "  host keys: $found found, $pinned_ok pinned-ok, ${#PINNED_SSH[@]} expected"
  [[ "$found" -eq "${#PINNED_SSH[@]}" && "$pinned_ok" -eq "${#PINNED_SSH[@]}" ]] \
    || emit ssh-key "host key count mismatch: $found found, $pinned_ok pinned-ok, ${#PINNED_SSH[@]} expected"

  emit shape "$shp"
fi

echo "==================================================="
if [[ $fail -ne 0 ]]; then
  echo "secret-scan FAILED. Anonymise and rebuild before publishing (see the hits above)."
  exit 1
fi
echo "secret-scan OK: no box specifics, identities, session secrets or credential shapes found."
