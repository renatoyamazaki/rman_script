# RMAN Script

Script for rman backups.
Options included tape backup, nfs backup.

It folows these steps:
- backup on local disk (set up db_recovery_file_dest parameter)
- backup to the tape
- backup to the nfs mount
