#!/bin/bash

# Quantos dias sao checados desde o ultimo backup rman, passados via parametro
CHECK_LEVEL0=$1
CHECK_LEVEL1=$2
CHECK_LEVEL2=$3

# Utiliza o nome do servidor para tratar excecoes
SERVERNAME=`hostname -s`

DBS=($(ps xua | grep [o]ra_arc | awk '{print $NF}' | cut -d"_" -f3 | sort | uniq))

###############################################################################

verify_rman_level0 () {
    sqlplus -s / as sysdba<<EOF
    set heading off
    set feedback off
    set pages 0
    alter session set optimizer_mode=RULE;
    select count(*) from v\$rman_status where command_id like 'level0%' and start_time >= sysdate-${CHECK_LEVEL0};
EOF
}

verify_rman_level1 () {
    sqlplus -s / as sysdba<<EOF
    set heading off
    set feedback off
    set pages 0
    alter session set optimizer_mode=RULE;
    select count(*) from v\$rman_status where command_id like 'level1%' and start_time >= sysdate-${CHECK_LEVEL1};
EOF
}

verify_rman_level2 () {
    sqlplus -s / as sysdba<<EOF
    set heading off
    set feedback off
    set pages 0
    alter session set optimizer_mode=RULE;
    select count(*) from v\$rman_status where command_id like 'level2%' and start_time >= sysdate-${CHECK_LEVEL2};
EOF
}

###############################################################################

# Executa uma sincronizacao com o NFS
rsync -a /u09/app/oracle/script/* /u08/app/oracle/script/

# Itera sobre todas as instancias
for DB in "${DBS[@]}"
do
	# Configura as variaveis de ambiente do oracle
	ORACLE_SID=$DB
	ORAENV_ASK=NO
	. oraenv

	# Coloca o resultado dos SQLs nas variaveis
	level0=$(verify_rman_level0)
	level1=$(verify_rman_level1)
	level2=$(verify_rman_level2)

	# Caso o backup level 0 tenha ultrapassado o limite de um período
	if [ "$level0" -eq 0 ]; then
		/u08/app/oracle/script/rman_bkp.sh $DB 0 > /dev/null 2>&1
	else
		# O backup level 1 é condição excludente do level 0
		if [ "$level1" -eq 0 ]; then
			/u08/app/oracle/script/rman_bkp.sh $DB 1 > /dev/null 2>&1
		else
			# O backup level 2 é de archives
			if [ "$level2" -eq 0 ]; then
				/u08/app/oracle/script/rman_bkp.sh $DB 2 > /dev/null 2>&1
			fi
		fi	
	fi	
done
