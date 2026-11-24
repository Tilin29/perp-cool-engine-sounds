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

# A secret pasted with a space or a line break around it fails the login while it looks right
# (the server refused the password with the right one typed in FileZilla): trimmed off, and
# noted for the failure report (lengths and what was trimmed only, never the values)
trimmed() { local value="$1"; value="${value#"${value%%[![:space:]]*}"}"; printf '%s' "${value%"${value##*[![:space:]]}"}"; }
describe() {
	local name="$1" raw="$2" clean="$3" note=""
	[ "$raw" = "$clean" ] || note=", $(( ${#raw} - ${#clean} )) space / line break character(s) trimmed off"
	case "$clean" in *[[:space:]]*) note="$note, has a space inside" ;; esac
	printf '%s: %d characters%s' "$name" "${#clean}" "$note"
}
userNote=$(describe TEST_SFTP_USER "$SFTP_USER" "$(trimmed "$SFTP_USER")")
passwordNote=$(describe TEST_SFTP_PASSWORD "$SFTP_PASSWORD" "$(trimmed "$SFTP_PASSWORD")")
SFTP_USER=$(trimmed "$SFTP_USER")
SFTP_PASSWORD=$(trimmed "$SFTP_PASSWORD")
case "$SFTP_USER" in *@*|*:*|*/*) userNote="$userNote, has @ : or / in it (the username alone, not user@host)" ;; esac

work=$(mktemp -d)
changes="$work/changes.txt"
# (a push that changes the deploy itself uploads everything: the way to try a fix of it)
if [ -z "$BEFORE" ] || [ "$BEFORE" = "0000000000000000000000000000000000000000" ] || ! git cat-file -e "$BEFORE^{commit}" 2>/dev/null 	|| git diff --name-only "$BEFORE" "$AFTER" | grep -qE '^\.github/(scripts/deploy_test\.sh|workflows/deploy-test\.yml)$'; then
	echo "Full upload (a manual run, no previous commit to compare with, or the deploy changed)"
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
printf '%s\n' "$SFTP_HOST_KEY" > "$knownHosts"
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
	while IFS=$'\t' read -r file target folder; do echo "put \"$file\" \"$target\""; done < "$uploads"
	echo "bye"
} > "$batch"

# what went wrong, when it does (nothing printed here holds the password)
explain() {
	local code=$1
	case "$code" in
		5) echo "::error::sshpass: the server refused the password (exit 5). Check TEST_SFTP_PASSWORD / TEST_SFTP_USER." ;;
		6) echo "::error::sshpass: the server's host key isn't the pinned one (exit 6)." ;;
		4) echo "::error::sshpass: ssh said something it didn't expect (exit 4): see the lines below." ;;
		*) echo "::error::The upload failed (exit $code): see the lines below." ;;
	esac
	# (as an annotation too: readable on the run's page without the log)
	if grep -q "Permission denied" "$work/sftp.log"; then
		echo "::error::The server refused the login. Secrets as received: $userNote; $passwordNote"
	fi
	echo "--- sftp's last lines:"
	tail -n 25 "$work/sftp.log" | sed 's/^/  /'
	echo "--- the key the server shows now (pinned: ${SFTP_HOST_KEY##* ssh-})"
	ssh-keyscan -p "$SFTP_PORT" -T 15 "$SFTP_HOST" 2>/dev/null | sed 's/^/  /' || true
	echo "--- a verbose login (pwd only):"
	printf 'pwd\nbye\n' > "$work/probe.sftp"
	sshpass -e sftp -v "${sshOptions[@]}" -b "$work/probe.sftp" "$SFTP_USER@$SFTP_HOST" 2>&1 | grep -v '^debug1: Reading configuration' | sed 's/^/  /' || true
}

if [ -n "${SFTP_COMMAND:-}" ]; then
	"$SFTP_COMMAND" "$batch"
else
	status=0
	sshpass -e sftp "${sshOptions[@]}" -b "$batch" "$SFTP_USER@$SFTP_HOST" > "$work/sftp.log" 2>&1 || status=$?
	if [ "$status" -ne 0 ]; then explain "$status"; exit 1; fi
fi
echo "Done: $uploadCount uploaded, $deleteCount deleted"
cut -f1 "$uploads" | head -50 | sed 's/^/  /'
[ "$uploadCount" -le 50 ] || echo "  ... and $((uploadCount - 50)) more"
