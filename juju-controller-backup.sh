#!/bin/bash

# vim:set filetype=sh expandtab tabstop=4 softtabstop=4 shiftwidth=4 autoindent smartindent:

# johan.hallbaeck@ibeo-as.com 2022-04-27
# erik.lonroth@gmail.com 2022-05-21

# Configurables
JUJU=/snap/bin/juju
LOGFILE=/tmp/juju-controller-backup.log
KEEPCOUNT=10
DESTDIR=.
NOW=$(date +%Y%m%d-%H%M%S)
SLACKWEBHOOK=

send_slack() {
    if [ -n "$SLACKWEBHOOK" ]; then
        ./slack-notifier.py -w "$SLACKWEBHOOK" -m "$1"
    fi
}

# Logging function, courtesy of cdarke:
# https://stackoverflow.com/questions/49851882/how-to-log-echo-statement-with-timestamp-in-shell-script/
logit() {
    while read -r
    do
        echo "$(date +%F-%H:%M:%S) $REPLY" >> ${LOGFILE}
    done
}

# Set up the logging
touch $LOGFILE || { echo No write access to $LOGFILE, cannot continue; exit 1 ; }

# Redirect stdout & stderr to logit(), saving the old file descriptors
exec 3>&1 4>&2 1>> >(logit) 2>&1

echo "$0" starting.

# Verify that the controller argument only contains letters etc
if ! echo "$1" | grep -Eq '^([A-Za-z0-9-]+)$' ; then
    msg="Controller argument is invalid, exiting"
    echo $msg
    send_slack "$msg"
    exit 1
fi

JUJUCONTROLLER="$1"
DESTDIR="$DESTDIR"/"$JUJUCONTROLLER"

# Check access
timeout 10 $JUJU status --model="$JUJUCONTROLLER":admin/controller > /dev/null 2>&1
if ! [ $? -eq 0 ]; then
    msg="Cannot check status of controller model on "$JUJUCONTROLLER", exiting"
    echo $msg
    send_slack "$msg"
    exit 1 
fi

mkdir -p "$DESTDIR"

"$JUJU" create-backup --model="$JUJUCONTROLLER":admin/controller \
    --filename="$DESTDIR"/juju-backup_"$JUJUCONTROLLER"_"$NOW".tar.gz \
    > "$DESTDIR"/juju-backup_"$JUJUCONTROLLER"_"$NOW".tar.gz.out 2>&1
BACKUPRET=$?

# Get backup result
backup_result=$(cat "$DESTDIR"/juju-backup_"$JUJUCONTROLLER"_"$NOW".tar.gz.out)

# Always append the result to the log
echo $backup_result >> $LOGFILE

if [ $BACKUPRET -ne 0 ] ; then
    msg="Backup failed, exiting"
    echo $msg
    send_slack "$msg"
    send_slack "$backup_result"
    exit 1
fi

echo Backup was successfully created in "$DESTDIR"/"$JUJUCONTROLLER"

for i in $(find "$DESTDIR" -type f -name '*.tar.gz' | sort | head -n -$KEEPCOUNT | xargs) ; do
    if [ -f "$i" ] ; then
        echo Removing old backup "$i" in destination
        rm -f "$i" "$i".out
    fi
done

send_slack "Backup success!"
send_slack "$backup_result"
echo "$0" exiting.
