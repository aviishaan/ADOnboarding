# ADOnboarding – Benutzer-Onboarding mit PowerShell

PowerShell-Modul, das neue Benutzer aus einer CSV-Datei in Active Directory anlegt.
Entstanden als Lernprojekt zur Automatisierung wiederkehrender IT-Aufgaben, getestet in einer eigenen Laborumgebung.

## Funktionen

- Benutzer aus CSV anlegen (`FirstName`, `LastName`, `Department`, optional `Title`)
- Benutzername im Format `vorname.nachname` (Umlaute werden ersetzt, maximal 20 Zeichen)
- Zufälliges Initialpasswort, Änderung beim ersten Login erforderlich
- Ablage in der passenden OU und Mitgliedschaft in der Gruppe `GG-<Abteilung>` (wird bei Bedarf angelegt)
- `-WhatIf`: zeigt nur an, was passieren würde
- Idempotent: bereits vorhandene Benutzer werden übersprungen
- Fehlerbehandlung pro Zeile: ein Fehler stoppt nicht den ganzen Lauf
- Logdatei mit Zeitstempel und Status (`INFO`, `WARN`, `ERROR`)

## Voraussetzungen

- Windows Server mit Active Directory und dem PowerShell-Modul `ActiveDirectory`
- Windows PowerShell 5.1
- Pester (Tests)

## Verwendung

```powershell
Import-Module .\ADOnboarding.psm1 -Force

# 1) Trockenlauf
Invoke-UserOnboarding -CsvPath .\NewUsers.csv -WhatIf

# 2) Echtlauf
Invoke-UserOnboarding -CsvPath .\NewUsers.csv -PasswordExportPath .\passwords.csv
```

Die Standardwerte für `BaseOU`, `GroupOU` und `UpnSuffix` sind auf die Laborumgebung (`alptech.local`) eingestellt und können über Parameter angepasst werden.

### CSV-Format

```csv
FirstName,LastName,Department,Title
Anna,Muster,IT,Systemadministratorin
```

`Department` muss einer vorhandenen OU unterhalb von `BaseOU` entsprechen (z. B. `OU=IT,OU=user,...`).

## Tests

```powershell
Invoke-Pester -Path .\Tests -Output Detailed
```

Die Pester-Tests mocken die AD-Cmdlets. Sie verändern das echte Active Directory nicht.
Zuletzt ausgeführt mit Pester 6.2.0: 13 Tests bestanden, 0 fehlgeschlagen.

### Testfälle

| ID | Testfall | Erwartetes Ergebnis | Art |
|----|----------|---------------------|-----|
| TC-01 | Benutzername aus Vor- und Nachname | `anna.muster` | Pester |
| TC-02 | Umlaute im Namen | `juergen.mueller` | Pester |
| TC-03 | Leerzeichen im Vornamen | `annamaria.muster` | Pester |
| TC-04 | Sehr langer Name | höchstens 20 Zeichen | Pester |
| TC-05 | Passwort: Länge und Zeichenarten | gewünschte Länge, Groß-/Kleinbuchstaben, Ziffer, Sonderzeichen | Pester |
| TC-06 | Zwei gültige CSV-Zeilen | zwei Benutzer werden angelegt | Pester |
| TC-07 | Benutzer existiert bereits | wird übersprungen, kein Duplikat | Pester |
| TC-08 | Aufruf mit `-WhatIf` | es werden keine Benutzer angelegt | Pester |
| TC-09 | Ziel-OU existiert nicht | Fehler für diese Zeile, restliche Zeilen laufen weiter | Pester |
| TC-10 | CSV-Spalte fehlt | Abbruch mit verständlicher Fehlermeldung | Pester |
| TC-11 | Lauf mit Logdatei | Logdatei enthält den Benutzer | Pester |
| TC-12 | Echtlauf im Labor | Benutzer in der richtigen OU und in `GG-<Abteilung>` | manuell |
| TC-13 | Zweiter Lauf mit derselben CSV | alle Benutzer werden übersprungen (idempotent) | manuell |

## Testumgebung

- Windows Server 2022 (Evaluation) als Domänencontroller auf VMware
- Domäne `alptech.local`
- Vor den Tests wurde ein VM-Snapshot erstellt, damit die Umgebung reproduzierbar ist

## Sicherheitshinweise

- `passwords.csv` enthält Initialpasswörter im Klartext und ist nur für das Labor gedacht.
  Sie steht in der `.gitignore` und darf nicht ins Repository.
  In einer produktiven Umgebung sollten Passwörter über einen Passwort-Tresor oder einen Reset-Link übergeben werden.
- Das Skript ist nicht für den Einsatz in einer Produktivumgebung geprüft.
- Auf einem Domänencontroller keine VM-Snapshots zurückspielen, wenn es weitere DCs gibt (Gefahr eines USN Rollbacks).

## Bekannte Grenzen / nächste Schritte

- Doppelte Namen (zwei Personen mit gleichem Vor- und Nachnamen) werden noch nicht automatisch aufgelöst
- Kein Microsoft-365-Teil (Lizenzen, Postfach), z. B. über Microsoft Graph
- Offboarding (Benutzer deaktivieren) als zweite Funktion
