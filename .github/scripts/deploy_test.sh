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
# Environment: SFTP_HOST, SFTP_PORT, SFTP_HOST_KEY (a known_hosts line), SFTP_USER, SFTP_PASSWORD,
# ADDON_DIR, SL65_DIR, BEFORE, AFTER. SFTP_COMMAND: a stand-in for the upload, to dry-run it.
#
# OpenSSH's sftp in batch mode, the password through sshpass. (lftp, the first version, failed with
# "Login incorrect" where FileZilla logged in with the same details: it drives ssh's password prompt
# itself.) A failed upload runs a verbose login probe, so the log shows what the server said.
set -euo pipefail
: "${SFTP_HOST:?}" "${SFTP_PORT:?}" "${SFTP_HOST_KEY:?}" "${SFTP_USER:?}" "${SFTP_PASSWORD:?}" "${ADDON_DIR:?}" "${SL65_DIR:?}"
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

# only the pinned host key is accepted; the password only (the runner has no keys to offer)
knownHosts="$work/known_hosts"
printf '%s
' "$SFTP_HOST_KEY" > "$knownHosts"
sshOptions=(-oBatchMode=no -oStrictHostKeyChecking=yes "-oUserKnownHostsFile=$knownHosts" -oPubkeyAuthentication=no
	-oPreferredAuthentications=password,keyboard-interactive -oNumberOfPasswordPrompts=1 -oConnectTimeout=30 -P "$SFTP_PORT")
export SSHPASS="$SFTP_PASSWORD"

# sftp batch: a leading "-" lets a command fail (a folder that exists, a file already gone).
# sftp's mkdir makes one level: every folder on the way is made, parents first (sorted)
batch="$work/commands.sftp"
{
	awk '{ path = ""; count = split($0, parts, "/"); for (i = 2; i <= count; i++) { path = path "/" parts[i]; print path } }' "$folders" | sort -u |
		while IFS= read -r folder; do echo "-mkdir \"$folder\""; done
	while IFS= read -r target; do echo "-rm \"$target\""; done < "$deletes"
	while IFS=$'	' read -r file target folder; do echo "put \"$file\" \"$target\""; done < "$uploads"
	echo "bye"
} > "$batch"

if [ -n "${SFTP_COMMAND:-}" ]; then
	"$SFTP_COMMAND" "$batch"
elif ! sshpass -e sftp "${sshOptions[@]}" -b "$batch" "$SFTP_USER@$SFTP_HOST"; then
	echo "::error::The upload failed. A verbose login follows (what the server offered and answered):"
	printf 'pwd
bye
' > "$work/probe.sftp"
	sshpass -e sftp -v "${sshOptions[@]}" -b "$work/probe.sftp" "$SFTP_USER@$SFTP_HOST" 2>&1 |
		grep -Ei "authenticat|permission|denied|password|connected|remote working|closed|error" || true
	exit 1
fi
echo "Done: $uploadCount uploaded, $deleteCount deleted"
cut -f1 "$uploads" | head -50 | sed 's/^/  /'
[ "$uploadCount" -le 50 ] || echo "  ... and $((uploadCount - 50)) more"
