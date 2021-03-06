#!/bin/bash

############## PARAMETROS - PASSADOS NA LINHA DE COMANDO ######################
# nome da instancia
DBNAME=$1	# ex. 'PD01', 'CATRMAN'
# nivel do backup (level 0 = FULL, level 1 = INCREMENTAL, level 2 = ARCHIVES)
LEVEL=$2	# ex. '0', '1', '2'
############## PARAMETROS - GERAIS ############################################
# lock desse script, para nao executar mais de uma vez ao mesmo tempo
LOCK_FILE="/u01/app/oracle/rman/rman_bkp.lock"
# diretorio onde ficam os logs do backup
LOG_DIR="/u01/app/oracle/rman/log"
# e-mails que recebe os logs em caso de erro
MAIL_DEST=""
############## PARAMETROS - CATALOGO ##########################################
# Uso de um catálogo rman (0 = desativado, 1 = ativado)
USE_CATALOG=1
# usuario/senha@tns_do_catalogo
CATALOG="rman/rmanpass@catrman"
############## PARAMETROS - BACKUP LOCAL ######################################
# retencao do backup no disco em dias
RETENT_DISK=7
############## PARAMETROS - BACKUP EM FITA ####################################
# utilização de backup em fita (0 = desativado, 1 = ativado)
USE_TAPE=0
# retencao do backup em fita em dias
RETENT_TAPE=31
# parametros do TDP
TDPO="ENV=(TDPO_OPTFILE=/opt/tivoli/tsm/client/oracle/bin64/tdpo.opt)"
############## PARAMETROS - BACKUP NO NFS #####################################
# utilização de backup em nfs (0 = desativado, 1 = ativado)
USE_NFS=0
# diretorio nfs
NFS_DISK="/u01/app/oracle/rman/nfs"
############## PARAMETROS - RMAN REPORT #####################################$$
# utilização da ferramenta de relatorio do rman
# more information on https://github.com/renatoyamazaki/rman_script
USE_RMAN_REPORT=1
URL_RMAN_REPORT="http://192.168.1.101/ora/rman_update.php"
###############################################################################


############## FUNCOES ########################################################

# Seta variaveis como:
# - paralelismo do backup em disco
# - paralelismo do backup em fita - fixo em 8 (se precisar de mais, aumentar 
# numero de nodes no tsm)
# - diretorio e nome do arquivo de log
# - comando principal do rman (depende da versao do oracle)

function setvar () {

	# variaveis utilizadas no log do backup e no rman
	SERVER=`hostname`
	DATE=`date +%Y%m%dT%H%M%S`

	# seta a tag utilizada no backup
	# essa tag identifica o backup, visivel nas views do rman
	BKP_TAG="level${LEVEL}_${DATE}"

	# extrai o numero de cpus do servidor, e utiliza esse valor 
	# no backup paralelo em disco
	NCPUS=`grep "model name" /proc/cpuinfo | wc -l`

	# cria o diretorio do log do backup, se nao existir 
	mkdir -p $LOG_DIR

	# arquivo de log do backup
	BKP_LOG="$LOG_DIR/${SERVER}_${DBNAME}_${DATE}.log"

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
	
	# extrai a versao da instancia
	ORAVER=$(tnsping | grep -i version | awk '{print $7}' | cut -d\. -f1)

	# extrai o dbid da instancia
	DBID=$(sqlplus -s / as sysdba<<EOF
    set heading off                     
    set feedback off                                             
    set pages 0                        
    alter session set optimizer_mode=RULE;
    select dbid from v\$database;
EOF)

}


function rman_public () {

	# utiliza catalogo
	if [[ ${USE_CATALOG} == "1" ]] ; then
		RMAN_CATALOG="connect catalog ${CATALOG}"
	else
		RMAN_CATALOG=""
	fi

	# backup do controlfile
	RMAN_CFILE="backup as compressed backupset current controlfile tag = 'CTF-${DATE}';"

	# backup do spfile
	RMAN_SPFILE="backup as compressed backupset spfile tag = 'SPF-${DATE}';"
}

function rman_disk () {

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
}

function rman_nfs () {
	## PARAM NFS
	if [[ ${USE_NFS} == "1" ]] ; then
		# cria o diretorio do backup nfs
		mkdir -p ${NFS_DISK}/${SERVER}
		
		# faz backup da recovery area em NFS
		if [[ "$ORAVER" == "10" ]] ; then
			RMAN_NFS=""
		else
			RMAN_NFS="backup recovery area to destination '${NFS_DISK}/${SERVER}';"
		fi
	else
		RMAN_NFS=""
	fi
}

function rman_tape () {
	## PARAM TAPE
	if [[ ${USE_TAPE} == "1" ]] ; then
		# aloca 8 canais para backup via TDP, incluindo o formato
		for (( i=1; i<=8; i++ )) ; do	
			CHANNEL_TAPE+="allocate channel c${i} device type sbt_tape format '%d_level${LEVEL}_%D_%M_%Y_%s_%t_%U.rman' parms '${TDPO}';"
		done
		# especifica o formato do autobackup em fita
		AUTOBACKUP_TAPE="%d_autobkp_%D_%M_%Y_%F.rman"

		# configuracao TDP
		CONFIG_TDP="configure channel device type 'sbt_tape' parms '${TDPO}';"
		CONFIG_TDP+="configure controlfile autobackup format for device type sbt_tape to '${AUTOBACKUP_TAPE}';"
	
		# comando de backup via TDP
        	RMAN_TDP="${CHANNEL_TAPE}
		backup recovery area;"
		
		# comando para limpeza de backups via TDP
		DELETE_TDP="delete noprompt obsolete recovery window of ${RETENT_TAPE} days device type sbt_tape;"
	else
		CONFIG_TDP=""	
		RMAN_TDP=""
		DELETE_TDP=""
	fi
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
${RMAN_CATALOG}
set echo on;
set command id to '${BKP_TAG}';
configure default device type to disk;
configure backup optimization on;
configure controlfile autobackup on;
configure device type disk parallelism ${NCPUS};
${CONFIG_TDP}
run {
${RMAN_DISK} 
${RMAN_CFILE} 
${RMAN_SPFILE}
delete force noprompt archivelog all backed up 1 times to disk; 
delete noprompt obsolete recovery window of ${RETENT_DISK} days device type disk; 
${RMAN_TDP}
${DELETE_TDP}
}
${RMAN_NFS}
EOF
	# coloca o codigo de retorno do rman em variavel
	DUMP_ERROR=$?

}


# Se o backup rman teve algum erro (DUMP_ERROR), manda e-mail com o log
# codigo de retorno em MAIL_ERROR

function email () {

	# Envia e-mail somente em caso de erro no backup do RMAN
	if [[ ! $DUMP_ERROR -eq 0 ]] ; then	
                MAIL_SUBJECT="Backup RMAN level $LEVEL - $SERVER - $DBNAME - ERRO"
		
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

# Atualiza as informacoes de backup no catalogo do rman, na aplicacao
# Rman Report

function atualiza_rman_report () {
	if [[ ${USE_RMAN_REPORT} == "1" ]] ; then
		wget "${URL_RMAN_REPORT}?dbid=${DBID}" -O - > /dev/null 2>&1
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

###############################################################################


############## MAIN ###########################################################
(
	# Se já tiver outra execução em andamento, sair
        flock -n 9 || exit 200
	# Seta todas as variaiveis necessarias
	setvar
	# Monta os comandos que serao executados no rman
	rman_public
	rman_disk
	rman_nfs
	rman_tape
	# Executa o backup no rman
	backup
	# Em caso de erro, envia e-mail
	email
	# Compacta log do rman
	compacta
	# Atualia a aplicacao de report
	atualiza_rman_report
	# Retorna o código de erro
	rc
) 9>$LOCK_FILE
###############################################################################
