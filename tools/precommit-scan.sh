#!/usr/bin/env bash
# precommit-scan.sh — refuse to publish local-machine paths, camera filenames,
# credentials, or named projects/clients, in file content OR in commit messages.
#
#   bash tools/precommit-scan.sh                    # scan what is staged (pre-commit)
#   bash tools/precommit-scan.sh --commit-msg FILE  # scan a commit message
#   bash tools/precommit-scan.sh --all              # audit every tracked file at HEAD
#   bash tools/precommit-scan.sh --install          # wire up both git hooks
#
# Repo-local deny terms (NEVER committed, so they can name what to keep out):
#   $(git rev-parse --git-dir)/info/precommit-terms   — one substring per line, # = comment
# Known-good matches:
#   tools/precommit-allowlist                         — one regex per line, committed
#
# Escape hatch: PRECOMMIT_SCAN_SKIP=1 git commit ...   (say why in the message).
# Why the message is scanned too: the first version of this script missed the commit
# message, which then carried the exact filename the scan existed to keep out.

set -uo pipefail

git rev-parse --git-dir >/dev/null 2>&1 || { echo "not a git repo"; exit 2; }
GITDIR=$(git rev-parse --git-dir)
TERMS="$GITDIR/info/precommit-terms"
ALLOWLIST="tools/precommit-allowlist"
SELF="$(git rev-parse --show-toplevel)/tools/precommit-scan.sh"

# name|regex   (split on the FIRST pipe; the regex may contain pipes)
rules() {
  cat <<'RULES'
home-path|/(Users|home)/[A-Za-z0-9._-]+/
named-volume|/Volumes/[A-Za-z0-9._-]+
camera-filename|\b[A-Z][0-9]{5,}\.(mov|mp4|m4v)
credential-assignment|(api[_-]?key|apikey|access[_-]?token|auth[_-]?token|client[_-]?secret|password|passwd)[[:space:]]*[:=][[:space:]]*["'`]?[A-Za-z0-9_./+:-]{12,}
key-format|\b(sk-[A-Za-z0-9]{12,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[baprs]-[A-Za-z0-9-]{10,}|AIza[0-9A-Za-z_-]{20,}|AKIA[0-9A-Z]{16}|eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{10,})
private-key-block|-----BEGIN [A-Z ]*PRIVATE KEY-----
secret-file-path|(\.claude\.json|brave-keys\.json|\.netrc|\.aws/credentials|\.ssh/id_[a-z0-9]+)
email|\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b
RULES
}

allow_regexes=()
if [[ -f "$ALLOWLIST" ]]; then
  while IFS= read -r line; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    allow_regexes+=("$line")
  done < "$ALLOWLIST"
fi
allowed() {
  local a
  for a in "${allow_regexes[@]+"${allow_regexes[@]}"}"; do
    if printf '%s' "$1" | grep -qEi -- "$a"; then return 0; fi
  done
  return 1
}

findings=0
report() { # label rule matched-line
  allowed "$3" && return
  printf '  %s  [%s]  %s\n' "$1" "$2" "${3:0:160}"
  findings=$((findings + 1))
}

# Scan one blob of text (with optional per-line numbering) against rules + deny terms.
scan_text() { # label content  number?(1|0)
  local label="$1" content="$2" numbering="${3:-0}" name regex line lineno
  while IFS='|' read -r name regex; do
    [[ -z "$name" ]] && continue
    while IFS= read -r line; do
      [[ -z "$line" ]] && continue
      if (( numbering )); then lineno="${line%%:*}"; report "$label:$lineno" "$name" "${line#*:}"
      else report "$label" "$name" "$line"; fi
    done < <(printf '%s\n' "$content" | grep -InEi -- "$regex" 2>/dev/null || true)
  done < <(rules)
  if [[ -f "$TERMS" ]]; then
    local term
    while IFS= read -r term; do
      [[ -z "$term" || "$term" == \#* ]] && continue
      while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if (( numbering )); then lineno="${line%%:*}"; report "$label:$lineno" "deny-term:$term" "${line#*:}"
        else report "$label" "deny-term:$term" "$line"; fi
      done < <(printf '%s\n' "$content" | grep -InF -- "$term" 2>/dev/null || true)
    done < "$TERMS"
  fi
}

if [[ "${1:-}" == "--install" ]]; then
  top="$(git rev-parse --show-toplevel)"
  mkdir -p "$GITDIR/hooks"
  cp "$top/tools/precommit-scan.sh" "$GITDIR/hooks/pre-commit"
  chmod +x "$GITDIR/hooks/pre-commit"
  cat > "$GITDIR/hooks/commit-msg" <<HOOK
#!/usr/bin/env bash
exec bash "$(git rev-parse --show-toplevel)/tools/precommit-scan.sh" --commit-msg "\$1"
HOOK
  chmod +x "$GITDIR/hooks/commit-msg"
  echo "installed: $GITDIR/hooks/pre-commit + commit-msg"
  echo "deny terms (untracked): $TERMS"
  exit 0
fi

if [[ "${1:-}" == "--commit-msg" ]]; then
  [[ -f "${2:-}" ]] || { echo "precommit-scan: no message file"; exit 0; }
  scan_text "commit-message" "$(cat "$2")" 1
  if (( findings )); then
    echo -e "\nBLOCKED: $findings finding(s) in the commit message itself."
    exit 1
  fi
  exit 0
fi

paths=()
if [[ "${1:-}" == "--all" ]]; then
  while IFS= read -r f; do paths+=("$f"); done < <(git ls-files)
else
  while IFS= read -r -d '' f; do paths+=("$f"); done \
    < <(git diff --cached -z --diff-filter=ACM --name-only)
fi
(( ${#paths[@]} )) && printf 'precommit-scan: %s file(s), %s rules%s\n' \
  "${#paths[@]}" "$(rules | wc -l | tr -d ' ')" \
  "$([[ -f "$TERMS" ]] && printf ', %s deny term(s)' "$(grep -cvE '^\s*(#|$)' "$TERMS")")"

for f in "${paths[@]+"${paths[@]}"}"; do
  # 1. the path itself
  scan_text "$f" "$f" 0
  # 2. its content (staged blob, or HEAD blob under --all)
  if [[ "${1:-}" == "--all" ]]; then scan_text "$f" "$(git show "HEAD:$f" 2>/dev/null)" 1
  else scan_text "$f" "$(git show ":$f" 2>/dev/null)" 1; fi
done

if (( findings )); then
  cat <<EOF

BLOCKED: $findings finding(s) that would become public.

Fix by one of:
  • remove/rewrite the value — a property description usually beats a name
    ("8128x4288 HEVC Main 10, 56 min" documents more than a filename ever did),
  • add a regex to $ALLOWLIST if it is genuinely meant to be public
    (placeholders follow the /Volumes/Your… convention),
  • or PRECOMMIT_SCAN_SKIP=1 git commit ... (say why in the message).
EOF
  exit 1
fi
[[ "${#paths[@]}" -gt 0 ]] && echo "precommit-scan: clean"
exit 0
