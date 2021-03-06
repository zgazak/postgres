#!/bin/bash
set -e

set_listen_addresses() {
	sedEscapedValue="$(echo "$1" | sed 's/[\/&]/\\&/g')"
	sed -ri "s/^#?(listen_addresses\s*=\s*)\S+/\1'$sedEscapedValue'/" "$PGDATA/postgresql.conf"
}

if [ "$1" = 'postgres' ]; then

	## start cron to run backups
	if [ "$PGRES_BCKUP" = 'True' ]; then
		touch backup/backup.log
		echo "###### new session" >> backup/backup.log
		echo "$(date '+%y-%m-%d %H:%M:%S')   initializing sql backups" >> backup/backup.log
		echo "SHELL=/bin/bash" > /etc/cron.d/sql-cron
		echo "PATH=/sbin:/bin:/usr/sbin:/usr/bin" >> /etc/cron.d/sql-cron
		echo "HOME=/" >> /etc/cron.d/sql-cron
		echo "* * * * * root pg_dumpall -h $PGRES_HOST -U $PGRES_USER > backup/${PGRES_DB}_bckup_\$(date '+\%y\%m\%d'-\%H).sql" >> /etc/cron.d/sql-cron
		chmod 0644 /etc/cron.d/sql-cron
		/usr/bin/crontab /etc/cron.d/sql-cron
		cron
	fi
	if [ "$PGRES_BCKUP_REMOTE" = 'True' ]; then
		touch backup/backup.log
		echo "###### new session -const backkup" >> backup/backup.log
		echo "$(date '+%y-%m-%d %H:%M:%S')   initializing sql backups" >> backup/backup.log
		echo "SHELL=/bin/bash" > /etc/cron.d/sql-cron
		echo "PATH=/sbin:/bin:/usr/sbin:/usr/bin" >> /etc/cron.d/sql-cron
		echo "HOME=/" >> /etc/cron.d/sql-cron
		echo "* * * * * root echo $(date '+%y-%m-%d %H:%M:%S') attempting to restore $(ls -tr /backup/*.sql | tail -n 1) >> backup/backup.log" >> /etc/cron.d/sql-cron
		echo "* * * * * root /usr/lib/postgresql/9.5/bin/postgres psql -f $(ls -tr /backup/*.sql | tail -n 1)" >> /etc/cron.d/sql-cron
		chmod 0644 /etc/cron.d/sql-cron
		/usr/bin/crontab /etc/cron.d/sql-cron
		cron
	fi

	mkdir -p "$PGDATA"

	chmod 700 "$PGDATA"
	chown -R postgres "$PGDATA"

	chmod g+s /run/postgresql
	chown -R postgres /run/postgresql
	# look specifically for PG_VERSION, as it is expected in the DB dir
	if [ ! -s "$PGDATA/PG_VERSION" ]; then
		gosu postgres initdb

		# check password first so we can output the warning before postgres
		# messes it up
		if [ "$POSTGRES_PASSWORD" ]; then
			pass="PASSWORD '$POSTGRES_PASSWORD'"
			authMethod=md5
		else
			# The - option suppresses leading tabs but *not* spaces. :)
			cat >&2 <<-'EOWARN'
				****************************************************
				WARNING: No password has been set for the database.
				         This will allow anyone with access to the
				         Postgres port to access your database. In
				         Docker's default configuration, this is
				         effectively any other container on the same
				         system.
				         Use "-e POSTGRES_PASSWORD=password" to set
				         it in "docker run".
				****************************************************
			EOWARN

			pass=
			authMethod=trust
		fi

		{ echo; echo "host all all 0.0.0.0/0 $authMethod"; } >> "$PGDATA/pg_hba.conf"

		# internal start of server in order to allow set-up using psql-client
		# does not listen on TCP/IP and waits until start finishes
		gosu postgres pg_ctl -D "$PGDATA" \
			-o "-c listen_addresses=''" \
			-w start

		: ${POSTGRES_USER:=postgres}
		: ${POSTGRES_DB:=$POSTGRES_USER}
		export POSTGRES_USER POSTGRES_DB

		if [ "$POSTGRES_DB" != 'postgres' ]; then
			psql --username postgres <<-EOSQL
				CREATE DATABASE "$POSTGRES_DB" ;
			EOSQL
			echo
		fi

		if [ "$POSTGRES_USER" = 'postgres' ]; then
			op='ALTER'
		else
			op='CREATE'
		fi

		psql --username postgres <<-EOSQL
			$op USER "$POSTGRES_USER" WITH SUPERUSER $pass ;
		EOSQL
		echo

		echo
		for f in /docker-entrypoint-initdb.d/*; do
			case "$f" in
				*.sh)  echo "$0: running $f"; . "$f" ;;
				*.sql) echo "$0: running $f"; psql --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" < "$f" && echo ;;
				*)     echo "$0: ignoring $f" ;;
			esac
			echo
		done

		gosu postgres pg_ctl -D "$PGDATA" -m fast -w stop
		set_listen_addresses '*'

		echo
		echo 'PostgreSQL init process complete; ready for start up.'
		echo
	fi

	if [ "$load_db" = 'True' ]; then
		if [ -n "$(ls -tr /backup/*.sql | tail -n 1)" ]; then
			echo "sleep 15" > temp.sh
			echo "echo $(date '+%y-%m-%d %H:%M:%S')    restoring $(ls -tr backup/*.sql | tail -n 1) >> backup/backup.log" >> temp.sh
			echo 'exec gosu postgres psql -f $(ls -tr /backup/*.sql | tail -n 1)' >> temp.sh
			echo "exec gosu root rm temp.sh" >> temp.sh
			echo "$(date '+%y-%m-%d %H:%M:%S')   Will restore $(ls -tr backup/*.sql | tail -n 1) in 15 seconds after postgres is running..." >> backup/backup.log
			source temp.sh &
		else
			echo "$(date '+%y-%m-%d %H:%M:%S')   no suitable .sql backup found -- starting with clean postgres platform" >> backup/backup.log
		fi
	else
		echo "not restoring  $(ls -tr backup/*.sql | tail -n 1)"
	fi

	exec gosu postgres "$@"

fi

exec "$@"
