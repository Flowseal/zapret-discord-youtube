@echo off
chcp 65001 > nul
:: 65001 - UTF-8

copy /b ipsets\*.txt ipset-all-unsorted.txt
type ipset-all-unsorted.txt | sort > ipset-all.txt
del ipset-all-unsorted.txt