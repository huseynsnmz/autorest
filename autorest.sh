#!/usr/bin/env bash

# Uncomment for debug this script:
#set -x

################################################################################
#
# Bash script that helps to automaticly restores pgBackRest backups and
# tests if latest backup is valid or not.
#
# It creates unit file for specified stanza then it changes Description and PGDATA
# variable, it changes certain PostgreSQL parameters to run in minimum
# hardware requirements because we don't need any performance. It is a test :)
#
#################################################################################

LOGGER=1
PROCESSMAX=1
LOGDETAIL='warn'
PGPORT=5432
ERROR_USAGE_STRING=$"Try $0 '--help' for more information."
MAIN_USAGE_STRING=$"
Usage: $0 [options] [mode]

Available operation mode (you can't specify remote and backup together):

-r, --remote                    remote server for restore
-b, --backup                    backup server for restore

Available remote mode options:

-s, --stanza NAME               stanza name for restore test (required)
-d, --data DIRECTORY            data directory to restore (required)
-p, --pg-port PORT		          port for starting PostgreSQL (Default: $PGPORT)
-i, --pg-bin DIRECTORY          binary directory to use pg_ctl
-H, --repo-host HOSTNAME        database server host (required)
-D, --repo-path DIRECTORY       repository directory for backup files (required)
-U, --repo-host-user NAME       repository user for ssh connection (required)
-P, --process-max NUMBER        max processes to use for uncompress/transfer (Default: $PROCESSMAX)
-l, --log-detail NAME           specifies log detail. Available options are 'off','error','warn','info','detail' 'debug','trace'. (Default: $LOGDETAIL)
-L, --loggeroff									disables redirecting syslog

Available backup mode options:

-s, --stanza NAME               stanza name for restore test (required)
-d, --data DIRECTORY            data directory to restore (required)
-p, --pg-port PORT		          port for starting PostgreSQL (Default: $PGPORT)
-i, --pg-bin DIRECTORY          binary directory to use pg_ctl
-P, --process-max NUMBER        max processes to use for uncompress/transfer (Default: $PROCESSMAX)
-l, --log-detail NAME           specifies log detail. Available options are 'off','error','warn','info','detail' 'debug','trace'. (Default: $LOGDETAIL)
-L, --loggeroff									disables redirecting syslog

Other options:

-V, --version                   output version information, then exit
--help, --usage                 show this help, then exit"





# Function that help to write information and error messages to syslog.
syslogger() {
	if [ $LOGGER -eq 1 ]; then
		exec 1> >(logger -p user.notice -s -t "$(basename "$0")")
		exec 2> >(logger -p user.error -s -t "$(basename "$0")")
	fi
}

	# Function that performs restore depends an operation mode.
	perform_restore() {
		echo "[STARTING] ($STANZA): Restore test beginning..." >&1
		if [ ! -f "$PGPATH" ]; then
			mkdir -p -m 700 "$PGPATH"
		fi
		case "$1" in
			backup)
				if [[ -z "$STANZA" || -z "$PGPATH" ]]; then
					echo "ERROR [001] ($STANZA): Some parameters is missing for backup mode. $ERROR_USAGE_STRING" >&2
					exit 1;
				fi
				pgbackrest --stanza="$STANZA" --reset-pg1-host --pg1-path="$PGPATH" --log-level-console="$LOGDETAIL" --process-max="$PROCESSMAX" --delta restore
				STATUS=$?
				if [ $STATUS -eq 0 ]; then
					echo "INFO [002] ($STANZA): Restoring from latest backup is finished successfully." >&1
					return 0;
				elif [ $STATUS -eq 38 ]; then
					echo "ERROR [002] ($STANZA): Unable to restore while PostgreSQL is running!" >&2
					exit 2;
				else
					echo "ERROR [002] ($STANZA) : Failed to restore latest backup!" >&2
					exit 2;
				fi
				;;

			remote)
				if [[ -z "$STANZA" || -z "$PGPATH" || -z "$REPOHOST" || -z "$REPOPATH" || -z "$REPOHOSTUSER" ]]; then
					echo "ERROR [001] ($STANZA): Some parameters is missing for remote mode. $ERROR_USAGE_STRING" >&2
					exit 1;
				fi
				pgbackrest --stanza="$STANZA" --repo1-host="$REPOHOST" --repo1-host-user="$REPOHOSTUSER" --repo1-path="$REPOPATH" --pg1-path="$PGPATH" --log-level-console="$LOGDETAIL" --process-max="$PROCESSMAX" --delta restore
				STATUS=$?
				if [ $STATUS -eq ]; then
					echo "INFO [002] ($STANZA): Restoring latest backup is finished successfully." >&1
					return 0;
				elif [ $STATUS -eq 38 ]; then
					echo "ERROR [002] ($STANZA): Unable to restore while PostgreSQL is running!" >&2
					exit 2;
				else
					echo "ERROR [002] ($STANZA): Failed to restore latest backup!" >&2
					exit 2;
				fi
				;;
		esac
	}


	# Function that change "postgresql.conf" files for minimum hardware requirements.
	change_conf() {
		if [ -e "$PGPATH/postgresql.auto.conf" ]; then
			{
				echo "hot_standby" = 'off'
				echo "cluster_name = '$STANZA'"
				echo "port = '$PGPORT'"
				echo "listen_addresses = 'localhost'"
				echo "shared_preload_libraries = ''"
				echo "shared_buffers = 128MB"
				echo "work_mem = 4MB"
				echo "maintenance_work_mem = 64MB"
				echo "wal_buffers = -1"
				echo "effective_cache_size = 4GB"
				echo "archive_mode = off"
				echo "wal_keep_segments = 0"
				echo "hba_file = '$PGPATH/pg_hba.conf'"
				echo "ident_file = '$PGPATH/pg_ident.conf'"
				echo "data_directory = '$PGPATH'"
				echo "ssl = off"
				echo "log_destination = 'stderr'"
				echo "log_filename = 'postgresql-%a.log'"
				echo "logging_collector = on"
			} >> "$PGPATH"/postgresql.auto.conf

		# These options for if pg_hba.conf or pg_ident.conf file is not in PostgreSQL's setup directory
		# and resetting them for security reasons.
		{
			echo 'local all postgres peer'
			echo 'host all all 0.0.0.0/0 reject'
			echo 'host all all ::/0 reject'
		} > "$PGPATH/pg_hba.conf"
	echo '' > "$PGPATH/pg_ident.conf"
	chmod 600 "$PGPATH/pg_hba.conf" "$PGPATH/pg_ident.conf" "$PGPATH/postgresql.conf" "$PGPATH/postgresql.auto.conf"
	chown postgres:postgres "$PGPATH/pg_hba.conf" "$PGPATH/pg_ident.conf" "$PGPATH/postgresql.conf" "$PGPATH/postgresql.auto.conf"
	echo "INFO [003] ($STANZA): Changed PostgreSQL parameters." >&1
	return 0;
elif [ -e "$PGPATH/postgresql.auto.conf" ]; then
	echo "ERROR [003] ($STANZA): $PGPATH/postgresql.auto.conf is not exists!" >&2
	exit 3;
else
	echo "ERROR [003] ($STANZA): There were some error when changing configurations!" >&2
	exit 3;
		fi
	}


	# Function that starts and stops service when restore finished successfully.
	start_service() {
		LATESTWAL=$(pgbackrest --stanza="$STANZA" info | grep 'wal archive' | awk '{print $5}' | awk -F '/' '{print $2}')
		PGVERSION=$(cat "$PGPATH"/PG_VERSION)
		PGBINDIR="/usr/pgsql-$PGVERSION/bin"
		if "$PGBINDIR"/pg_ctl -s -D "$PGPATH" start 1>/dev/null; then
			echo "INFO [005] ($STANZA): PostgreSQL started successfully." >&1
			if [ "$PGVERSION" -ge 12 ]; then
				if [ ! -f "$PGPATH"/recovery.signal ]; then
					echo "INFO [006] ($STANZA): recovery.signal file is not found. Exiting.." >&1
					exit 6;
				elif [ -f "$PGPATH"/recovery.signal ]; then
					echo "INFO [006] ($STANZA): recovery.signal file is found. Waiting for archive recovery to complete." >&1
					until [ ! -f "$PGPATH"/recovery.signal ]; do
						sleep 60
					done
				fi
			elif [ "$PGVERSION" -le 11 ]; then
				if [ ! -f "$PGPATH"/recovery.conf ]; then
					echo "INFO [006] ($STANZA): recovery.conf file is not found. Exiting.." >&1
					exit 6;
				elif [ -f "$PGPATH"/recovery.conf ]; then
					echo "INFO [006] ($STANZA): recovery.conf file is found. Waiting for archive recovery to complete." >&1
					until [ -f "$PGPATH"/recovery.done ]; do
						sleep 60
					done
				fi
			fi

			if [[ $(grep -c 'archive recovery complete' "$PGPATH"/log/postgresql-"$(date +%a)".log) -eq 1 ]]; then
				if [[ $(grep -c "unable to find $LATESTWAL" "$PGPATH"/log/postgresql-"$(date +%a)".log) -ne 0 ]]; then
					echo "ERROR [007] ($STANZA): There is a problem with WAL archive! Check the logs for more detail." >&2
					if "$PGBINDIR"/pg_ctl -s -D "$PGPATH" stop; then
						echo "INFO [008] ($STANZA): PostgreSQL stopped successfully." >&1
						return 0;
					else
						echo "ERROR [008] ($STANZA): Failed to stop PostgreSQL!" >&2
						exit 8;
					fi
				else
					echo "INFO [007] ($STANZA): PITR is completed successfully for $STANZA stanza." >&1
					if "$PGBINDIR"/pg_ctl -s -D "$PGPATH" stop; then
						echo "INFO [008] ($STANZA): PostgreSQL stopped successfully." >&1
						return 0;
					else
						echo "ERROR [008] ($STANZA): Failed to stop PostgreSQL!" >&2
						exit 8;
					fi
				fi
			fi
		else
			echo "ERROR [005] ($STANZA): Failed to start PostgreSQL!" >&2
			exit 5;
		fi
	}


	# Parameter for what to be parsed in input parameters.
	TEMP=$(getopt -o rbs:d:p:i:H:D:U:P:l:LV --long remote,backup,stanza:,data:,pg-port:,pg-bindir:,repo-host:,repo-path:,repo-host-user:,process-max:,log-detail:,loggeroff,version,help,usage -- "$@")
	eval set -- "$TEMP"

	# Loop for parsing statements
	while true ; do
		case "$1" in
			-r|--remote)
				syslogger
				perform_restore remote
				change_conf
				if start_service; then
					exit 0;
				else
					exit 1;
					fi ;;
				-b|--backup)
					syslogger
					perform_restore backup
					change_conf
					if start_service; then
						exit 0;
					else
						exit 1;
						fi ;;
					-s|--stanza)
						STANZA=$2
						shift 2 ;;
					-d|--data)
						PGPATH=$2
						shift 2 ;;
					-p|--pg-port)
						PGPORT=$2
						shift 2 ;;
					-H|--repo-host)
						REPOHOST=$2
						shift 2 ;;
					-D|--repo-path)
						REPOPATH=$2
						shift 2 ;;
					-U|--repo-host-user)
						REPOHOSTUSER=$2
						shift 2 ;;
					-i|--pg-bindir)
						PGBINDIR=$2
						shift 2 ;;
					-P|--process-max)
						PROCESSMAX=$2
						shift 2 ;;
					-l|--log-detail)
						LOGDETAIL=$2
						shift 2 ;;
					-L|--loggeroff)
						LOGGER=0
						shift;;
					-V|--version)
						echo '2.0'
						exit 0 ;;
					--help|--usage)
						echo "$MAIN_USAGE_STRING" >&1
						exit 0 ;;
					*)
						echo "$MAIN_USAGE_STRING" >&1
						exit 1 ;;
				esac
			done
