#!/bin/bash

##### CONSTANTS #####
COLOR_RED=$(tput setaf 1)
COLOR_GREEN=$(tput setaf 2)
COLOR_YELLOW=$(tput setaf 3)
COLOR_DEFAULT=$(tput sgr0)
COLS=$(tput cols)

MSG_TYPE_ERROR="ERROR"
MSG_TYPE_OK="OK"

URI_REGEX="(oracle|mysql|postgresql)://([a-zA-Z0-9_.]+):?([0-9]+)?/([a-zA-Z0-9_]+)"

DB_TYPE_ORACLE="oracle"
DB_TYPE_MYSQL="mysql"
DB_TYPE_POSTGRESQL="postgresql"

DEFAULT_PORT_ORACLE=1521
DEFAULT_PORT_MYSQL=3306
DEFAULT_PORT_POSTGRESQL=5432


#### FUNCTIONS ####
function print_message() {
	local msg_type=$1
	local msg=$2

	case "$msg_type" in
		"$MSG_TYPE_ERROR") local color=$COLOR_RED ;;
		"$MSG_TYPE_OK") local color=$COLOR_GREEN ;;
		*) exit ;;
	esac

	printf '%s\n' "${color}$msg${COLOR_DEFAULT}"
}


function print_results() {
	local msg_type=$1
	local msg=$2
	local details=$3

	case "$msg_type" in
		"$MSG_TYPE_ERROR") local color=$COLOR_RED ;;
		"$MSG_TYPE_OK") local color=$COLOR_GREEN ;;
		*) exit ;;
	esac

	printf "[ %s%-5s%s ] %s%*s\n" "${color}" "$msg_type" "${COLOR_DEFAULT}" "$msg" $((COLS - ${#color} - ${#msg_type} - ${#COLOR_DEFAULT} - ${#msg}))
	if [ -n "$details" ]; then
		printf '%s\n' " \`--> $details"
	fi
}


function print_progress() {
	local pid=$1
	local msg=$2
	
	while :
	do
		if kill -0 "$pid" 2> /dev/null
			then
			case "$progress_bar" in
				".    ") progress_bar="..   " ;;
				"..   ") progress_bar="...  " ;;
				"...  ") progress_bar=".... " ;;
				".... ") progress_bar="....." ;;
				".....") progress_bar=".    " ;;
				*) 		 progress_bar=".    " ;;
			esac

			printf "[ %s%s%s ] %s\r" "${COLOR_YELLOW}" "$progress_bar" "${COLOR_DEFAULT}" "$msg"
		else
			break
		fi
		sleep 1
	done
}


function check_client() {
	case "$DB_TYPE" in 
		"$DB_TYPE_ORACLE") local client="sqlplus2" ;;
		"$DB_TYPE_MYSQL") local client="mysql" ;;
		"$DB_TYPE_POSTGRESQL") local client="psql" ;;
	esac

	local output=$(command -v $client)
	if [ -z "$output" ]; then
		print_message "$MSG_TYPE_ERROR" "$client is required to run scripts against the $DB_TYPE database"
		print_message "$MSG_TYPE_ERROR" "Check if $client is in your \$PATH or even installed"
		output=0
	fi

	return $output
}


function test_connection() {
	case "$DB_TYPE" in 
		"$DB_TYPE_ORACLE") 
			local output=$(echo -n $(sqlplus -S "$DB_USER/$DB_PASSWORD@(DESCRIPTION = (ADDRESS_LIST = (ADDRESS = (PROTOCOL = TCP) (HOST = $DB_HOST)(PORT = $DB_PORT))) (CONNECT_DATA = (SID = $DB_DATABASE)))" <<EOF
SET HEAD OFF
SELECT 1 FROM DUAL;
exit;
EOF
))
			;;
		"$DB_TYPE_MYSQL") 
			local output=$(echo -n $(mysql --silent --skip-column-names --host=$DB_HOST --database=$DB_DATABASE --port=$DB_PORT --user=$DB_USER --password=$DB_PASSWORD --execute="SELECT 1"))
			;;
		"$DB_TYPE_POSTGRESQL") 
			local output=$(echo -n $(psql --quiet --tuples-only --host=$DB_HOST --dbname=$DB_DATABASE --port=$DB_PORT --user=$DB_USER --command="SELECT 1"))
			;;
	esac

	if [ "$output" != "1" ]; then
		print_message "$MSG_TYPE_ERROR" "It was not possible connect to database!"
		print_message "$MSG_TYPE_ERROR" "$output"
		output=0
	fi

	return $output
}


function exec_sql() {
	local sql_file=$1
	local sql_log=$2

	case "$DB_TYPE" in 
		"$DB_TYPE_ORACLE") 
			echo "
set echo on
set serveroutput on
spool $sql_log
@$sql_file
exit;
" | sqlplus -S "$DB_USER/$DB_PASSWORD@(DESCRIPTION = (ADDRESS_LIST = (ADDRESS = (PROTOCOL = TCP) (HOST = $DB_HOST)(PORT = $DB_PORT))) (CONNECT_DATA = (SID = $DB_DATABASE)))" > /dev/null 2>&1 &
			local pid=$!
			;;
		"$DB_TYPE_MYSQL") 
			mysql --silent --line-numbers --host=$DB_HOST --database=$DB_DATABASE --port=$DB_PORT --user=$DB_USER --password=$DB_PASSWORD < $sql_file >/dev/null 2>$sql_log &
			local pid=$!
			;;
		"$DB_TYPE_POSTGRESQL") 
			psql --quiet --host=$DB_HOST --dbname=$DB_DATABASE --port=$DB_PORT --user=$DB_USER --file=$sql_file --output=/dev/null 2>$sql_log &
			local pid=$!
			;;
	esac

	local msg="Executing sql file: $sql_file"
	print_progress "$pid" "$msg"

	local msg="Sql file executed: $sql_file"
	
	case "$DB_TYPE" in 
		"$DB_TYPE_ORACLE") 
			local errors=$(grep -i -e "^ERRO" -e "^SP2-" -e "^ORA-" -e "^PLS-" $sql_log 2>/dev/null | wc -l)
			;;
		"$DB_TYPE_MYSQL") 
			local errors=$(wc -l < $sql_log)
			;;
		"$DB_TYPE_POSTGRESQL") 
			local errors=$(wc -l < $sql_log)
			;;
	esac

	if [ $errors -gt 0 ]; then
		local result=0
		local detail="Check the log file for errors ${COLOR_YELLOW}$sql_log${COLOR_DEFAULT}"
		print_results "ERROR" "$msg" "$detail"
	else
		rm $sql_log 2>/dev/null
		local result=1
		print_results "$MSG_TYPE_OK" "$msg"
	fi

	return $result
}


function exec_sql_files() {
	check_client
	local result=$?
	if [ $result -eq 0 ]; then
		exit 1
	fi

	test_connection
	local result=$?
	if [ $result -eq 0 ]; then
		exit 1
	fi

	# apply all sql scripts in directory
	for sql_file in $(ls $DIR_SCRIPTS/*.sql)
	do
		sql_file=$(dirname $sql_file)/$(basename $sql_file)
		local sql_log=$DIR_LOGS/$(echo $sql_file | sed 's:/:__:g').log

		exec_sql "$sql_file" "$sql_log"
		local result=$?
		if [ $result -eq 0 ]; then
			read -p "Errors have occurred. Continue (y|N)? " proceed
			if [[ "$proceed" != "y" ]] && [[ "$proceed" != "Y"  ]]; then
				echo "Please check the errors before run it again. Aborting..."
				exit 1
			fi
		fi
	done
}


##### START #####
# clean variables, to avoid conflicts inside this script
unset DB_TYPE
unset DB_HOST
unset DB_PORT
unset DB_DATABASE
unset DB_USER
unset DB_PASSWORD

unset DIR_SCRIPTS
unset DIR_LOGS


function print_usage() {
    echo "Usage: $(basename $0) OPTIONS <scripts dir>

    Executes the .sql files in <scripts dir> on database
    
OPTIONS:

    -h <database host>  in format <type>://<ip|hostname>[:<port>]/<dbname>
                        type:   oracle or mysql or postgresql
                        port:   optional. default values:
                                1521 for Oracle
                                3306 for MySQL
                                5432 for PostgreSQL
                        dbname: database name for MySQL or PostgreSQL
                                SID for Oracle
    -u <user>
    -p <password>
    
Examples:

    Oracle:

    $(basename $0) -h oracle://localhost/XE -u test_user -p t3stP4ss0rd scripts/oracle
    $(basename $0) -h oracle://localhost:1521/XE -u test_user -p t3stP4ss0rd scripts/oracle

    MySQL:

    $(basename $0) -h mysql://10.20.40.5/testdb -u test_user -p t3stP4ss0rd scripts/mysql
    $(basename $0) -h mysql://10.20.40.5:3306/testdb -u test_user -p t3stP4ss0rd scripts/mysql
    
    PostgreSQL:

    $(basename $0) -h postgresql//localhost/testdb -u test_user -p t3stP4ss0rd scripts/postgresql
    $(basename $0) -h postgresql//localhost:5432/testdb -u test_user -p t3stP4ss0rd scripts/postgresql
"
    exit 0
}


#### MAIN ####
while getopts :h:u:p: optname
do
	case "$optname" in
		"h") DB_URI=$OPTARG ;;
		"u") DB_USER=$OPTARG ;;
		"p") DB_PASSWORD=$OPTARG ;;
		\?) 
			echo "Invalid option: $OPTARG"
			echo ""
			print_usage
			;;
		:)
			echo "Invalid option: $OPTARG requires an argument"
			echo ""
			print_usage
			;;
		*) print_usage ;;
	esac
done
shift $((OPTIND-1))

DIR_SCRIPTS=$1

if [[ $DB_URI =~ $URI_REGEX ]]; then
	DB_TYPE=${BASH_REMATCH[1]}
	DB_HOST=${BASH_REMATCH[2]}
	DB_PORT=${BASH_REMATCH[3]}
	DB_DATABASE=${BASH_REMATCH[4]}

	if [ -z "$DB_PORT" ]; then
		case "$DB_TYPE" in 
			"$DB_TYPE_ORACLE") DB_PORT=$DEFAULT_PORT_ORACLE ;;
			"$DB_TYPE_MYSQL") DB_PORT=$DEFAULT_PORT_MYSQL ;;
			"$DB_TYPE_POSTGRESQL") DB_PORT=$DEFAULT_PORT_POSTGRESQL ;;
		esac
	fi
fi

DIR_LOGS=logs/$DB_TYPE/$DB_HOST/$DB_DATABASE/$DB_USER
mkdir -p $DIR_LOGS

# printf "%-12s = %s\n" "DB_TYPE" "$DB_TYPE"
# printf "%-12s = %s\n" "DB_HOST" "$DB_HOST"
# printf "%-12s = %s\n" "DB_PORT" "$DB_PORT"
# printf "%-12s = %s\n" "DB_DATABASE" "$DB_DATABASE"
# printf "%-12s = %s\n" "DB_USER" "$DB_USER"
# printf "%-12s = %s\n" "DB_PASSWORD" "$DB_PASSWORD"
# printf "%-12s = %s\n" "DIR_LOGS" "$DIR_LOGS"
# printf "%-12s = %s\n" "DIR_SCRIPTS" "$DIR_SCRIPTS"


if [ -z "$DB_TYPE" ] || \
	[ -z "$DB_HOST" ] || \
	[ -z "$DB_PORT" ] || \
	[ -z "$DB_DATABASE" ] || \
	[ -z "$DB_USER" ] || \
	[ -z "$DB_PASSWORD" ] || \
	[ -z "$DIR_SCRIPTS" ]; then
	print_usage
fi

exec_sql_files


# clean variables used inside this script
unset DIR_SCRIPTS
unset DIR_LOGS

unset MSG_TYPE_ERROR
unset MSG_TYPE_OK

unset COLOR_RED
unset COLOR_GREEN
unset COLOR_YELLOW
unset COLOR_DEFAULT
unset COLS

unset DB_TYPE
unset DB_HOST
unset DB_PORT
unset DB_DATABASE
unset DB_USER
unset DB_PASSWORD
