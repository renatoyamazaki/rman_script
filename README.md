# RMAN Script

Script for rman backups.
Options included: catalog, tape backup, secondary disk backup.
Works on Oracle (10G,11G and 12c) with linux SO. Tested on rhel 5 and rhel 6.

It folows these steps:
1. connects to catalog (optional)
1. backup on local disk (set up db\_recovery\_file\_dest parameter)
1. backup to tape (optional)
1. backup to a secondary disk location (optional)

Features:
1. Parallel backup on local disk (cpu count)
1. Parameterized options: catalog, tape backup, secondary disk backup
1. Sends an e-mail when an error ocurred, with the log attachment

