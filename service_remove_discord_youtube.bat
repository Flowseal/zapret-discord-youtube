set SRVCNAME=zapret

net stop "%SRVCNAME%"
sc delete "%SRVCNAME%"