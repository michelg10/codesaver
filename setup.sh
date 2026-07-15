#!/bin/zsh
# Interactive setup for CodeSaver. Run once after cloning; writes setup.conf
# (gitignored), which ingest.py, build.sh, and appex/install.sh all read.
set -euo pipefail
cd "$(dirname "$0")"

echo "CodeSaver setup"
echo "───────────────"

# ── GitHub username (whose repos to sample code from) ────────────────────────
gh_default=$(gh api user --jq .login 2>/dev/null || true)
read "owner?GitHub username to ingest code from${gh_default:+ [$gh_default]}: "
owner=${owner:-$gh_default}
if [[ -z $owner ]]; then
  echo "A GitHub username is required (and \`gh auth login\` must work)." >&2
  exit 1
fi

# ── Spinner verbs ─────────────────────────────────────────────────────────────
echo
echo "Spinner verbs file: tab-delimited lines of \"Gerund<TAB>Past\" (e.g. \"Reticulating<TAB>Reticulated\")."
echo "Leave empty to use the bundled list."
read "verbs?Path to your verbs file []: "
verbs=${verbs/#\~/$HOME}
if [[ -n $verbs && ! -f $verbs ]]; then
  echo "No file at $verbs" >&2
  exit 1
fi

# ── Code signing ──────────────────────────────────────────────────────────────
echo
# `|| true`: without it, pipefail+errexit silently kills the script on
# machines with no signing certificate.
team_default=$(security find-certificate -c "Apple Development" -p 2>/dev/null \
  | openssl x509 -noout -subject 2>/dev/null \
  | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p' || true)
read "team?Apple team ID for signing${team_default:+ [detected: $team_default]}: "
team=${team:-$team_default}
if [[ -z $team ]]; then
  echo "No team ID — signing will fail. Get one from an 'Apple Development'" >&2
  echo "certificate in Keychain (free Apple ID works via Xcode → Accounts)." >&2
  exit 1
fi

# setup.conf is source'd by the build scripts, so reject characters that
# would break parsing or execute at source time.
for value in "$owner" "$team" "$verbs"; do
  if [[ $value == *[\"\`\$]* ]]; then
    echo "Values may not contain \", \`, or \$ — got: $value" >&2
    exit 1
  fi
done

cat > setup.conf <<EOF
OWNER="$owner"
TEAM_ID="$team"
VERBS="$verbs"
EOF
echo
echo "Wrote setup.conf. Next:"
echo "  ./ingest.py           # mirror your GitHub source"
echo "  ./appex/install.sh    # build + install the screensaver"
