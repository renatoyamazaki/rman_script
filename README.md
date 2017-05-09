# RMAN Script

Script for rman backups.
Options included: catalog, tape backup, secondary disk backup.
Works on Oracle (10G,11G and 12c) with linux os. Tested on rhel 5 and rhel 6.

It folows these steps:
1. connects to catalog (optional)
1. backup on local disk (set up db\_recovery\_file\_dest parameter)
1. backup to tape (optional)
1. backup to a secondary disk location (optional)

Features:
* Parallel backup on local disk (cpu count)
* Parameterized options: catalog, tape backup, secondary disk backup
* Sends an e-mail when an error ocurred, with the log attachment

## How to use

### Configure

Edit the script **rman_bkp.sh**, reading the comments of the parameters and 
adjusting according to your environment.

### Execute

For example, if your instance is named *orcl* and you want a full backup:

```
./rman_bkp orcl 0
```
