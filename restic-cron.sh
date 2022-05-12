#!/bin/bash
PATH=/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin
SSH_REMOTE_PATH=$HOSTNAME
CONFIG_FILE="/etc/restic-cron.conf"
EXCLUDE_TMP="$(mktemp)"
SSH_KEY_TMP="$(mktemp)"
MODE=ssh

#echo $SSH_REMOTE_PATH
#exit
handle_errors () {
  if [ "$?" != "0" ]; then
    rm $EXCLUDE_TMP
    rm $SSH_KEY_TMP
    (>&2 echo "error: '$1'")
    exit 1
  fi
}

trap ctrl_c INT TERM
function ctrl_c() {
  false
  handle_errors "crtl+c pressed, temp files removed"
}

if [ $(stat -c "%a" "$CONFIG_FILE") != "600" ]; then
  false
  handle_errors "wrong permissions on $CONFIG_FILE. 600 required."
fi

if ! [[ "$MODE" =~ ^(ssh|backblaze)$ ]]; then
  false
  handle_errors "unknown or missing mode. supported: ssh, backblaze"
fi

source $CONFIG_FILE
handle_errors "missing config file $CONFIG_FILE"

if [ "$MODE" == "ssh" ]; then
  [ ! -z "$SSH_REMOTE_USER" ] || handle_errors "missing SSH_REMOTE_USER in conf";
  [ ! -z "$SSH_REMOTE_SERVER" ] || handle_errors "missing SSH_REMOTE_SERVER in conf";
  [ ! -z "$SSH_REMOTE_PATH" ] || handle_errors "missing SSH_REMOTE_PATH in conf";
  [ ! -z "$SSH_PORT" ] || SSH_PORT="22";

  export RESTIC_REPOSITORY="sftp:$SSH_REMOTE_USER@$SSH_REMOTE_SERVER:$SSH_REMOTE_PATH"

#  RESTIC_SFTP="-o sftp.command=ssh -i $SSH_KEY_TMP $SSH_REMOTE_USER@$SSH_REMOTE_SERVER -p $SSH_PORT -o StrictHostKeyChecking=no -s sftp"
  RESTIC_SFTP="-o sftp.command=ssh $SSH_REMOTE_USER@$SSH_REMOTE_SERVER -p $SSH_PORT -o StrictHostKeyChecking=no -s sftp"
fi

if [ "$MODE" == "backblaze" ]; then
  [ ! -z "$B2_ACCOUNT_ID" ] || handle_errors "missing B2_ACCOUNT_ID in conf";
  [ ! -z "$B2_ACCOUNT_KEY" ] || handle_errors "missing B2_ACCOUNT_KEY in conf";
  [ ! -z "$B2_BUCKET" ] || handle_errors "missing B2_BUCKET in conf";

  export RESTIC_REPOSITORY="b2:$B2_BUCKET:backup"
  # RESTIC_SFTP=""
fi

if [ -z "$RESTIC_PASSWORD" ]; then
  false
  handle_errors "missing RESTIC_PASSWORD in conf"
fi

function join_by { local IFS="$1"; shift; echo "$*"; }
join_by $'\n' "${exclude[@]}" > $EXCLUDE_TMP

type restic > /dev/null
handle_errors "restic not found"

if ! restic snapshots "$RESTIC_SFTP"; then
  echo "---------- init"
  restic init "$RESTIC_SFTP"
  handle_errors "running init"
fi
#echo $RESTIC_SFTP
echo "---------- backup files"
restic backup "$RESTIC_SFTP" \
  --tag $(hostname) \
  --one-file-system \
  --exclude-file $EXCLUDE_TMP \
  ${include[*]}
handle_errors "running backup"

echo "---------- forget files"
restic forget "$RESTIC_SFTP" \
  --tag $(hostname) \
  --keep-daily $KEEP_DAYS \
  --keep-weekly $KEEP_WEEKS \
  --keep-monthly $KEEP_MONTHS \
  --keep-yearly $KEEP_YEARS \
  --prune
handle_errors "forget"

echo "---------- backup mysql"
if [ ! -z "$mysqldumps" ]; then
  for item in ${mysqldumps[*]}
    do
      if [ "$MODE" == "ssh" ]; then
        mysqldump $item | restic backup "$RESTIC_SFTP" --tag mysql_$item --stdin --stdin-filename $item.sql
      else
        mysqldump $item | restic backup --tag mysql_$item --stdin --stdin-filename $item.sql
      fi
    done
fi
handle_errors "running mysqldump"

echo "---------- forget mysql"
restic forget "$RESTIC_SFTP" \
  --tag mysql_$item \
  --keep-daily $KEEP_DAYS \
  --keep-weekly $KEEP_WEEKS \
  --keep-monthly $KEEP_MONTHS \
  --keep-yearly $KEEP_YEARS \
  --prune
handle_errors "running mysql backup"

# echo "---------- prune"
# restic prune "$RESTIC_SFTP"

rm $EXCLUDE_TMP
rm $SSH_KEY_TMP
