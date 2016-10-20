#!/bin/bash

##### CONSTANTS #####
COLOR_RED=$(tput setaf 1)
COLOR_GREEN=$(tput setaf 2)
COLOR_YELLOW=$(tput setaf 3)
COLOR_DEFAULT=$(tput sgr0)
COLS=$(tput cols)

MSG_TYPE_ERROR="ERROR"
MSG_TYPE_OK="OK"


#### FUNCTIONS ####
function test_connection() {
	local output=$(echo -n $(sqlplus -S "$DB_USER/$DB_PASSWORD@(DESCRIPTION = (ADDRESS_LIST = (ADDRESS = (PROTOCOL = TCP) (HOST = $DB_HOST)(PORT = $DB_PORT))) (CONNECT_DATA = (SID = $DB_DATABASE)))" <<EOF
SET HEAD OFF
SELECT 1 FROM DUAL;
exit;
EOF
))

	if [ "$output" != "1" ]; then
		print_message "ERROR" "It was not possible connect to Oracle!"
		print_message "ERROR" "$output"
		output=0
	fi

	return $output
}


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


function exec_oracle_sql() {
	local sql_file=$1
	local sql_file_log=$DIR_SCRIPTS/$(basename $sql_file .sql).log

	echo "
set echo on
set serveroutput on
spool $sql_file_log
@$sql_file
exit;
" | sqlplus -S "$DB_USER/$DB_PASSWORD@(DESCRIPTION = (ADDRESS_LIST = (ADDRESS = (PROTOCOL = TCP) (HOST = $DB_HOST)(PORT = $DB_PORT))) (CONNECT_DATA = (SID = $DB_DATABASE)))" > /dev/null 2>&1 &
	local pid=$!
	local msg="Executing sql file: $sql_file"
	print_progress "$pid" "$msg"

	local msg="Sql file executed: $sql_file"
	local errors=$(grep -i -e "^ERRO" -e "^SP2-" -e "^ORA-" -e "^PLS-" $sql_file_log 2>/dev/null |wc -l)
	if [ $errors -gt 0 ]; then
		local result=0
		local detail="Check the log file for errors ${COLOR_YELLOW}$sql_file_log${COLOR_DEFAULT}"
		print_results "ERROR" "$msg" "$detail"
	else
		local result=1
		print_results "OK" "$msg"
	fi

	return $result
}


function exec_sql_files() {
	test_connection
	local result=$?
	if [ $result -eq 0 ]; then
		exit 1
	fi

	# apply all sql scripts in directory
	for sql_file in `ls $DIR_SCRIPTS/*.sql`
	do
		exec_oracle_sql "$sql_file"
		result=$?

		if [ $result -eq 0 ]; then
			read -p "Errors have occurred. Continue (y|n)? " proceed
			if [[ "$proceed" != "y" ]] && [[ "$proceed" != "Y"  ]]; then
				echo "Please check the errors before run it again. Aborting..."
				exit 1
			fi
		fi
	done
}


##### START #####
# clean variables, to avoid conflicts inside this script
unset DB_HOST
unset DB_PORT
unset DB_DATABASE
unset DB_USER
unset DB_PASSWORD

unset DIR_SCRIPTS
unset DIR_LOGS


function usage() {
	echo "Usage: $0 OPTIONS <scripts dir>"
	echo ""
	echo "OPTIONS:"
	echo "  -h = Database host/IP                 Ex.: 10.20.40.5 or localhost"
	echo "  -P = Database port (defaut = 1521)    Ex.: 1521 or 1530"
	echo "  -d = Database database                Ex.: XE"
	echo "  -u = Database user"
	echo "  -p = Database password"
	exit 0
}


#### MAIN ####
while getopts :h:P::d:u:p: optname
do
	case "$optname" in
		"h") DB_HOST=$OPTARG ;;
		"P") DB_PORT=$OPTARG ;;
		"d") DB_DATABASE=$OPTARG ;;
		"u") DB_USER=$OPTARG ;;
		"p") DB_PASSWORD=$OPTARG ;;
		\?) 
			echo "Invalid option: $OPTARG"
			echo ""
			usage
			;;
		:)
			echo "Invalid option: $OPTARG requires an argument"
			echo ""
			usage
			;;
		*) usage ;;
	esac
done
shift $((OPTIND-1))

DIR_SCRIPTS=$1

if [ -z "$DB_PORT" ]; then
	DB_PORT=1521
fi

if [ -z "$DB_HOST" ] || \
	[ -z "$DB_PORT" ] || \
	[ -z "$DB_DATABASE" ] || \
	[ -z "$DB_USER" ] || \
	[ -z "$DB_PASSWORD" ] || \
	[ -z "$DIR_SCRIPTS" ]; then
	usage
fi

exec_sql_files


# echo "DB_HOST = $DB_HOST"
# echo "DB_PORT = $DB_PORT"
# echo "DB_DATABASE = $DB_DATABASE"
# echo "DB_USER = $DB_USER"
# echo "DB_PASSWORD = $DB_PASSWORD"
# echo "DIR_SCRIPTS = $DIR_SCRIPTS"


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

unset DB_HOST
unset DB_PORT
unset DB_DATABASE
unset DB_USER
unset DB_PASSWORD
