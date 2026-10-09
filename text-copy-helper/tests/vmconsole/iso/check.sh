#!/bin/sh
# Prüft im Gast, ob ein per TextCopyHelper getipptes Testmuster exakt ankommt.
# Eingabe verdeckt wie bei einer Passwortabfrage.
#   sh /mnt/check.sh [ascii|pw]      (Standard: ascii)
D=$(dirname "$0")
F="$D/${1:-ascii}.txt"
exp=$(cat "$F")
printf '\n=== Muster %s (%d Zeichen) - jetzt tippen lassen ===\n' "${1:-ascii}" "${#exp}"
stty -echo
IFS= read -r got
stty echo
if [ "$got" = "$exp" ]; then
    printf '>>> OK: %d von %d Zeichen korrekt\n' "${#got}" "${#exp}"
    exit 0
fi
printf %s "$exp" > /tmp/e
printf %s "$got" > /tmp/g
pos=$(cmp /tmp/e /tmp/g 2>&1 | sed -n 's/.*char \([0-9]*\).*/\1/p')
printf '>>> FEHLER: %d Zeichen erwartet, %d bekommen\n' "${#exp}" "${#got}"
if [ -n "$pos" ]; then
    e=$(dd if=/tmp/e bs=1 skip=$((pos-1)) count=1 2>/dev/null)
    g=$(dd if=/tmp/g bs=1 skip=$((pos-1)) count=1 2>/dev/null)
    printf '    erste Abweichung an Stelle %s: erwartet [%s] bekommen [%s]\n' "$pos" "$e" "$g"
fi
printf '    erwartet: %s\n    bekommen: %s\n' "$exp" "$got"
exit 1
