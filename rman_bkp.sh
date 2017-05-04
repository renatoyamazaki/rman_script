#!/bin/bash

############## PARAMETROS #####################################################
# nome da instancia
DBNAME=$1	# ex. PD01, CATRMAN
# nivel do backup (level 0 = FULL, level 1 = INCREMENTAL, level 2 = ARCHIVES)
LEVEL=$2	# ex. 0, 1, 2
# retencao do backup no disco em dias
RETENT_DISK=7
# retencao do backup em fita em dias
RETENT_TAPE=31
# lista de e-mails que recebe os logs
MAIL_DEST="johndoe@email.com"
# usuario, senha e tns do catalogo
CATALOG="username/password@catalog"
# NFS mount
NFS_DISK="/u09/app/oracle/rman"
###############################################################################


############## FUNCOES #######################################################


# Seta variaveis como:
# - paralelismo do backup em disco
# - paralelismo do backup em fita - fixo em 8 (se precisar de mais, aumentar 
# numero de nodes no tsm)
# - diretorio e nome do arquivo de log
# - comando principal do rman (depende da versao do oracle)

function setvar () {

	# variaveis utilizadas no log do backup e no rman
	HOSTNAME=`hostname`
	DATE=`date +%Y%m%dT%H%M%S`

	# extrai o numero de cpus do servidor, e utiliza esse valor 
	# no backup paralelo em disco
	NCPUS=`grep "model name" /proc/cpuinfo | wc -l`

	# parametros do TDP
	TDPO="ENV=(TDPO_OPTFILE=/opt/tivoli/tsm/client/oracle/bin64/tdpo.opt)"

	# cria o diretorio do log do backup, se nao existir 
	BKP_BASE="/u08/app/oracle/rman"
	BKP_LOG_DIR="$BKP_BASE/log"
	mkdir -p $BKP_LOG_DIR

	# cria o diretorio do backup nfs
	mkdir -p ${NFS_DISK}/${HOSTNAME}

	# arquivo de log do backup
	BKP_LOG="$BKP_LOG_DIR/${HOSTNAME}_${DBNAME}_${DATE}.log"

	# seta a tag utilizada no backup
	# essa tag identifica o backup, visivel nas views do rman
	BKP_TAG="level${LEVEL}_${DATE}"
	
	# aloca 8 canais para backup via TDP, incluindo o formato
	for (( i=1; i<=8; i++ )) ; do	
		CHANNEL_TAPE+="allocate channel c${i} device type sbt_tape format '%d_level${LEVEL}_%D_%M_%Y_%s_%t_%U.rman' parms '${TDPO}';"
	done

	# especifica o formato do autobackup em fita
	AUTOBACKUP_TAPE="%d_autobkp_%D_%M_%Y_%F.rman"

	# formato de data/horario utilizado no log do rman
	export NLS_DATE_FORMAT='HH24:MI:SS DD/MM/YYYY';

	# codigo de retorno das funcoes
	DUMP_ERROR=0
	ZIP_ERROR=0
	MAIL_ERROR=0

	# seta as variaveis de ambiente do oracle
	ORACLE_SID=$DBNAME
	ORAENV_ASK=NO
	. oraenv > /dev/null 2>&1
	
	# extrai a versao do banco
	ORAVER=$(tnsping | grep -i version | awk '{print $7}' | cut -d\. -f1)

	# caso seja backup do tipo archive (level 2)
	if [[ ${LEVEL} == "2" ]] ; then
		RMAN_DISK="backup as compressed backupset filesperset 10 archivelog all tag = 'ARCH-${DATE}';"
	else
		# level 0 ou level 1
		# seta em variavel o comando principal do backup via rman
		# caso a versao seja 10g, nao existe a opcao 'section size'
		if [[ "$ORAVER" == "10" ]] ; then
			RMAN_DISK="backup as compressed backupset filesperset 10 incremental level ${LEVEL} database tag = 'LVL${LEVEL}-${DATE}' plus archivelog tag = 'ARCH-${DATE}';"
		else
			RMAN_DISK="backup as compressed backupset section size 5G filesperset 10 incremental level ${LEVEL} database tag = 'LVL${LEVEL}-${DATE}' plus archivelog tag = 'ARCH-${DATE}';"
		fi
	fi
	
	# faz backup da recovery area em NFS	
	if [[ "$ORAVER" == "10" ]] ; then
		RMAN_NFS=""
	else
		RMAN_NFS="backup recovery area to destination '${NFS_DISK}/${HOSTNAME}';"
	fi

	# faz backup via TDP
        RMAN_TDP="${CHANNEL_TAPE}
backup recovery area;"

	# backup do controlfile
	RMAN_CFILE="backup as compressed backupset current controlfile tag = 'CTF-${DATE}';"

	# backup do spfile
	RMAN_SPFILE="backup as compressed backupset spfile tag = 'SPF-${DATE}';"
}


# Script rman, seguem os passos
# - conecta no catalogo
# - seta a tag do backup
# - configura todas as variaveis do rman 
# - executa o backup em disco
# - faz uma copia do backup em disco para a fita
# - deleta backups antigos
# codigo de retorno em DUMP_ERROR

function backup () {

rman target / msglog $BKP_LOG append > /dev/null 2>&1 <<EOF
connect catalog ${CATALOG}
set echo on;
set command id to '${BKP_TAG}';
configure default device type to disk;
configure backup optimization on;
configure controlfile autobackup on;
configure device type disk parallelism ${NCPUS};
configure channel device type 'sbt_tape' parms '${TDPO}';
configure controlfile autobackup format for device type sbt_tape to '${AUTOBACKUP_TAPE}';
run { 
${RMAN_DISK} 
${RMAN_CFILE} 
${RMAN_SPFILE}
${RMAN_TDP}
delete force noprompt archivelog all backed up 1 times to disk; 
delete noprompt obsolete recovery window of ${RETENT_DISK} days device type disk; 
delete noprompt obsolete recovery window of ${RETENT_TAPE} days device type sbt_tape;
}
${RMAN_NFS}
EOF

	# coloca o codigo de retorno do rman em variavel
	DUMP_ERROR=$?

}

# Atualiza as informacoes de backup no catalogo do rman, na aplicacao
# Rman Report

function atualiza_rman_report () {

	DBID=$(grep DBID $BKP_LOG | awk '{print $6}' | cut -d \= -f2 | cut -d \) -f1)
	wget "http://webapp/rman_update.php?dbid=$DBID" -O - > /dev/null 2> /dev/null
}

# Se o backup rman teve algum erro (DUMP_ERROR), manda e-mail com o log
# codigo de retorno em MAIL_ERROR

function email () {

	# Envia e-mail somente em caso de erro no backup do RMAN
	if [[ ! $DUMP_ERROR -eq 0 ]] ; then	
                MAIL_SUBJECT="Backup RMAN level $LEVEL - $HOSTNAME - $DBNAME - ERRO"
		
		MAIL_BODY+="\n[rman] RMAN terminou com erro, log em anexo."

		# Tenta enviar e-mail com anexo, se nao funcionar, a razao eh a versao 
		# do mail. No caso, de versao antiga, tenta o segundo comando
        	echo -e "$MAIL_BODY" | mail -a $BKP_LOG -s "$MAIL_SUBJECT" "$MAIL_DEST"
		MAIL_ERROR=$?
		if [[ ! $MAIL_ERROR -eq 0 ]] ; then
			MAIL_BODY+=$(cat "$BKP_LOG")
		        echo -e "$MAIL_BODY" | mail -s "$MAIL_SUBJECT" "$MAIL_DEST"	
			MAIL_ERROR=$?
		fi
	fi
}


# Se o backup foi executado com sucesso (DUMP_ERROR), compacta o log
# codigo de retorno em ZIP_ERROR

function compacta () {

	# Compacta o log se o RMAN nao teve erro 
	# Deixa em texto puro para facilitar na hora da analise (caso de erro)
	if [[ $DUMP_ERROR -eq 0 ]] ; then
		gzip $BKP_LOG
		# retorno do gzip em variavel
		ZIP_ERROR=$?
	fi

}


# de acordo com os codigos de retorno das funcoes,
# sai com o codigo de retorno da tabela:
#
#Codigo	Descricao do Erro
#0	Backup OK
#100	Configuracao do Oracle errada ou  TSM fora do ar
#101	Problema no gzip do arquivo de log 
#102	Envio de e-mail
#103	Erros 100 e 101 e 102
#104	Erros 100 e 101
#105	Erros 101 e 102
#106	Erros 100 e 102
#200	Execucao duplicada do script

function rc () {

	# Codigo de erros retornados pelo script
	# O codigo 200 eh enviado em caso de duplicacao na execucao
        if [[ ! $DUMP_ERROR -eq 0 ]] && [[ ! $ZIP_ERROR ]] && [[ ! $MAIL_ERROR ]]; then
		exit 103
	fi
        if [[ ! $DUMP_ERROR -eq 0 ]] && [[ ! $ZIP_ERROR ]] ; then
		exit 104
	fi
        if [[ ! $ZIP_ERROR ]] && [[ ! $MAIL_ERROR ]]; then
		exit 105
	fi
        if [[ ! $DUMP_ERROR -eq 0 ]] && [[ ! $MAIL_ERROR ]]; then
		exit 106
	fi
        if [[ ! $DUMP_ERROR -eq 0 ]] ; then
		exit 100
	fi
	if [[ ! $ZIP_ERROR -eq 0 ]] ; then
		exit 101
	fi
	if [[ ! $MAIL_ERROR -eq 0 ]] ; then
		exit 102
	fi

}


############## MAIN ###########################################################
(
	# Se já tiver outra execução em andamento, sair
        flock -n 9 || exit 200
	# Seta todas as variaiveis necessarias
	setvar
	# Backup em disco e fita
	backup
	# Atualiza as informacoes no rman report
	atualiza_rman_report
	# Em caso de erro, envia e-mail
	email
	# Compacta log do rman
	compacta
	# Retorna o código de erro
	rc
) 9>/u08/app/oracle/rman_bkp.lock

