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
# Config variables for sending backup to a remote location using sftp
REMOTEHOST=
REMOTEPORT=
REMOTEUSER=
RSAPATH=
REMOTEDIR=

send_slack() {
    if [ -n "$SLACKWEBHOOK" ]; then
        ./slack-notifier.py -w "$SLACKWEBHOOK" -m "$1"
    fi
}

run_sftp_command() {
    sftp -P $REMOTEPORT -i $RSAPATH $REMOTEUSER@$REMOTEHOST <<EOF
    $1
    exit
EOF
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
timeout 3 $JUJU status --model="$JUJUCONTROLLER":admin/controller > /dev/null 2>&1
if ! [ $? -eq 0 ]; then
    msg="Backup of $JUJUCONTROLLER FAILED!
    Cannot check status of controller model on $JUJUCONTROLLER"
    echo $msg
    send_slack "$msg"
    exit 1 
fi

mkdir -p "$DESTDIR"
FILEPATH="$DESTDIR"/juju-backup_"$JUJUCONTROLLER"_"$NOW".tar.gz

"$JUJU" create-backup --model="$JUJUCONTROLLER":admin/controller \
    --filename=$FILEPATH \
    2>&1 | tee $FILEPATH.out
BACKUPRET=$?

# Get backup result
backup_result=$(cat "$DESTDIR"/juju-backup_"$JUJUCONTROLLER"_"$NOW".tar.gz.out)

# Always append the result to the log
echo $backup_result >> $LOGFILE

if [ $BACKUPRET -ne 0 ] ; then
    msg="Backup of $JUJUCONTROLLER FAILED!
    $backup_result"
    echo $msg
    send_slack "$msg"
    exit 1
fi

echo Backup was successfully created in $DESTDIR

if [ -n "$REMOTEHOST" ]; then
    # Create remote directory for backup
    run_sftp_command "mkdir $REMOTEDIR/$DESTDIR"

    # Send backup to remote server
    run_sftp_command "put $FILEPATH* $REMOTEDIR/$DESTDIR"
    BACKUPRET=$?
    if [ $BACKUPRET -ne 0 ] ; then
        msg="Backup of $JUJUCONTROLLER to remote FAILED!"
        echo $msg
        send_slack "$msg"
        exit 1
    fi
    echo Backup was successfully sent to remote server.
fi

for i in $(find "$DESTDIR" -type f -name '*.tar.gz' | sort | head -n -$KEEPCOUNT | xargs) ; do
    if [ -f "$i" ] ; then
        echo Removing old backup "$i" in local destination
        rm -f "$i" "$i".out
        if [ -n "$REMOTEHOST" ]; then
            echo Removing old backup "$i" in remote destination
            run_sftp_command "rm $REMOTEDIR/$i $REMOTEDIR/$i.out"
        fi
    fi
done

send_slack "Backup of $JUJUCONTROLLER SUCCEEDED!
$backup_result"
echo "$0" exiting.
