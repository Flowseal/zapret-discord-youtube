Set WshShell = CreateObject("WScript.Shell")

' Перейти в директорию скрипта
Set fso = CreateObject("Scripting.FileSystemObject")
scriptPath = fso.GetParentFolderName(WScript.ScriptFullName)
WshShell.CurrentDirectory = scriptPath

' Выполнить service_status.bat
WshShell.Run """" & scriptPath & "\service_status.bat"" zapret", 0, True

' Выполнить check_updates.bat
WshShell.Run """" & scriptPath & "\check_updates.bat"" soft", 0, True

' Запустить winws.exe с параметрами
cmd = """" & scriptPath & "\bin\winws.exe"" --wf-tcp=80,443 --wf-udp=443,50000-50100 " & _
" --filter-udp=443 --hostlist=""" & scriptPath & "\lists\list-general.txt"" --dpi-desync=fake --dpi-desync-repeats=6 " & _
" --dpi-desync-fake-quic=""" & scriptPath & "\bin\quic_initial_www_google_com.bin"" --new " & _
" --filter-udp=50000-50100 --ipset=""" & scriptPath & "\lists\ipset-discord.txt"" --dpi-desync=fake --dpi-desync-any-protocol --dpi-desync-cutoff=d3 --dpi-desync-repeats=6 --new " & _
" --filter-tcp=80 --hostlist=""" & scriptPath & "\lists\list-general.txt"" --dpi-desync=fake,split2 --dpi-desync-autottl=2 --dpi-desync-fooling=md5sig --new " & _
" --filter-tcp=443 --hostlist=""" & scriptPath & "\lists\list-general.txt"" --dpi-desync=fake,multidisorder --dpi-desync-split-pos=midsld --dpi-desync-repeats=8 --dpi-desync-fooling=md5sig,badseq --new " & _
" --filter-udp=443 --ipset=""" & scriptPath & "\lists\ipset-cloudflare.txt"" --dpi-desync=fake --dpi-desync-repeats=6 --dpi-desync-fake-quic=""" & scriptPath & "\bin\quic_initial_www_google_com.bin"" --new " & _
" --filter-tcp=80 --ipset=""" & scriptPath & "\lists\ipset-cloudflare.txt"" --dpi-desync=fake,split2 --dpi-desync-autottl=2 --dpi-desync-fooling=md5sig --new " & _
" --filter-tcp=443 --ipset=""" & scriptPath & "\lists\ipset-cloudflare.txt"" --dpi-desync=fake,multidisorder --dpi-desync-split-pos=midsld --dpi-desync-repeats=6 --dpi-desync-fooling=md5sig,badseq"

WshShell.Run cmd, 0, False
