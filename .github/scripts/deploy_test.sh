#!/usr/bin/env bash
# Uploads this addon to the test server over SFTP (run by .github/workflows/deploy-test.yml).
#
# A push uploads the files it changed and deletes the ones it removed; a manual run (or a push
# whose previous commit isn't known, e.g. after a force push) uploads every file. Files a full
# upload doesn't know about (an old bake's sound folders left on the server) stay there.
#
# Mapping (repo path -> server):
#   addons/sl65amg_rtu/<path>   -> $SL65_DIR/<path>   (its own GMod addon on the server)
#   other addons/*, dev/*, .github/*, .claude/*, dist/*, *.md, .gitignore, .gitattributes: not uploaded
#   everything else             -> $ADDON_DIR/<path>
#
# Environment: SFTP_HOST, SFTP_PORT, SFTP_HOST_KEY (a known_hosts line), SFTP_USER,
# LFTP_PASSWORD (read by lftp's --env-password), ADDON_DIR, SL65_DIR, BEFORE, AFTER.
set -euo pipefail
: "${SFTP_HOST:?}" "${SFTP_PORT:?}" "${SFTP_HOST_KEY:?}" "${SFTP_USER:?}" "${LFTP_PASSWORD:?}" "${ADDON_DIR:?}" "${SL65_DIR:?}"
BEFORE="${BEFORE:-}"
AFTER="${AFTER:-HEAD}"

work=$(mktemp -d)
changes="$work/changes.txt"
if [ -z "$BEFORE" ] || [ "$BEFORE" = "0000000000000000000000000000000000000000" ] || ! git cat-file -e "$BEFORE^{commit}" 2>/dev/null; then
	echo "Full upload (no previous commit to compare with)"
	git -c core.quotepath=off ls-files | sed 's/^/M\t/' > "$changes"
else
	echo "Uploading the changes from ${BEFORE:0:7} to ${AFTER:0:7}"
	git -c core.quotepath=off diff --name-status --no-renames "$BEFORE" "$AFTER" > "$changes"
fi

uploads="$work/uploads.txt" deletes="$work/deletes.txt" folders="$work/folders.txt"
# (one awk pass: the repo path -> the server's, as in the header; uploads "file<TAB>target<TAB>folder")
awk -F '\t' -v addon="$ADDON_DIR" -v sl65="$SL65_DIR" -v uploads="$uploads" -v deletes="$deletes" '
	$2 == "" { next }
	$2 ~ /^(dev|\.github|\.claude|dist)\// || $2 ~ /\.md$/ || $2 == ".gitignore" || $2 == ".gitattributes" { next }
	$2 ~ /^addons\/sl65amg_rtu\// { target = sl65 "/" substr($2, length("addons/sl65amg_rtu/") + 1) }
	$2 ~ /^addons\// && $2 !~ /^addons\/sl65amg_rtu\// { next }
	$2 !~ /^addons\// { target = addon "/" $2 }
	{
		if ($1 == "D") { print target > deletes }
		else { folder = target; sub(/\/[^\/]*$/, "", folder); print $2 "\t" target "\t" folder > uploads }
	}' "$changes"
touch "$uploads" "$deletes"
cut -f3 "$uploads" | sort -u > "$folders"

uploadCount=$(wc -l < "$uploads"); deleteCount=$(wc -l < "$deletes")
echo "$uploadCount to upload, $deleteCount to delete"
if [ "$uploadCount" -eq 0 ] && [ "$deleteCount" -eq 0 ]; then echo "Nothing for the server"; exit 0; fi

# only the pinned host key is accepted
knownHosts="$work/known_hosts"
printf '%s\n' "$SFTP_HOST_KEY" > "$knownHosts"

script="$work/commands.lftp"
{
	echo "set sftp:auto-confirm no"
	echo "set sftp:connect-program \"ssh -a -x -o StrictHostKeyChecking=yes -o UserKnownHostsFile=$knownHosts\""
	echo "set net:max-retries 3"
	echo "set net:timeout 30"
	echo "open --env-password -u \"$SFTP_USER\" sftp://$SFTP_HOST:$SFTP_PORT"
	# (folders that exist already and files already gone aren't failures)
	echo "set cmd:fail-exit no"
	while IFS= read -r folder; do echo "mkdir -p -f \"$folder\""; done < "$folders"
	while IFS= read -r target; do echo "rm -f \"$target\""; done < "$deletes"
	echo "set cmd:fail-exit yes"
	while IFS=$'\t' read -r file target folder; do echo "put -O \"$folder\" \"$file\""; done < "$uploads"
	echo "bye"
} > "$script"

"${LFTP:-lftp}" -f "$script"   # (LFTP: a stand-in to dry-run it)
echo "Done: $uploadCount uploaded, $deleteCount deleted"
sed 's/^/  /' "$uploads" | cut -f1 | head -50
[ "$uploadCount" -le 50 ] || echo "  ... and $((uploadCount - 50)) more"
