# ADOnboarding.psm1
# Automatisiert das Anlegen neuer AD-Benutzer aus einer CSV-Datei.
# Hinweis: Nur ASCII-Zeichen im Code (ae/oe/ue), damit Windows PowerShell 5.1 keine Encoding-Probleme hat.

function New-OnboardingSamAccountName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$FirstName,
        [Parameter(Mandatory)][string]$LastName
    )

    # Umlaute ueber Zeichencodes, damit die Datei encoding-sicher bleibt
    $map = [ordered]@{
        ([string][char]0xE4) = 'ae'   # a-Umlaut
        ([string][char]0xF6) = 'oe'   # o-Umlaut
        ([string][char]0xFC) = 'ue'   # u-Umlaut
        ([string][char]0xDF) = 'ss'   # scharfes s
    }

    $normalize = {
        param([string]$text)
        $t = $text.Trim().ToLowerInvariant()
        foreach ($key in $map.Keys) { $t = $t.Replace($key, $map[$key]) }
        $t -replace '[^a-z0-9\-]', ''
    }

    $sam = '{0}.{1}' -f (& $normalize $FirstName), (& $normalize $LastName)
    # sAMAccountName darf in AD maximal 20 Zeichen lang sein
    $sam.Substring(0, [Math]::Min(20, $sam.Length))
}

function New-OnboardingPassword {
    [CmdletBinding()]
    param(
        [ValidateRange(12, 64)][int]$Length = 16
    )

    $sets = 'ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!@#$%&*?'
    $rng  = [System.Security.Cryptography.RandomNumberGenerator]::Create()

    $pick = {
        param([char[]]$chars)
        $bytes = New-Object byte[] 4
        $rng.GetBytes($bytes)
        $chars[[int]([BitConverter]::ToUInt32($bytes, 0) % [uint32]$chars.Length)]
    }

    # Mindestens ein Zeichen aus jeder Gruppe, der Rest zufaellig aus allen Gruppen
    $result = foreach ($set in $sets) { & $pick $set.ToCharArray() }
    $all    = ($sets -join '').ToCharArray()
    $result += foreach ($i in 1..($Length - $sets.Count)) { & $pick $all }

    # Reihenfolge mischen, damit die ersten vier Zeichen nicht vorhersagbar sind
    -join ($result | Sort-Object { Get-Random })
}

function Write-OnboardingLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    # -WhatIf:$false, damit das Log auch bei einem WhatIf-Lauf geschrieben wird
    Add-Content -Path $Path -Value $line -WhatIf:$false
}

function Invoke-UserOnboarding {
    <#
    .SYNOPSIS
    Legt neue Benutzer aus einer CSV-Datei in Active Directory an.
    .DESCRIPTION
    CSV-Spalten: FirstName, LastName, Department (und optional Title).
    Der Benutzer landet in OU=<Department> unterhalb von BaseOU und wird Mitglied der Gruppe GG-<Department>.
    Mit -WhatIf wird nur angezeigt, was passieren wuerde.
    .EXAMPLE
    Invoke-UserOnboarding -CsvPath .\NewUsers.csv -WhatIf
    #>
    [CmdletBinding(SupportsShouldProcess = $true)]
    param(
        [Parameter(Mandatory)][string]$CsvPath,
        [string]$BaseOU    = 'OU=user,DC=alptech,DC=local',
        [string]$GroupOU   = 'OU=group,DC=alptech,DC=local',
        [string]$UpnSuffix = 'alptech.local',
        [string]$LogPath   = (Join-Path $PSScriptRoot 'onboarding.log'),
        [string]$PasswordExportPath
    )

    Import-Module ActiveDirectory -ErrorAction Stop

    if (-not (Test-Path -Path $CsvPath)) { throw "CSV not found: $CsvPath" }
    $rows = @(Import-Csv -Path $CsvPath -Encoding UTF8)

    $required = 'FirstName', 'LastName', 'Department'
    if ($rows.Count -gt 0) {
        $missing = $required | Where-Object { $_ -notin $rows[0].PSObject.Properties.Name }
        if ($missing) { throw "CSV is missing column(s): $($missing -join ', ')" }
    }

    Write-OnboardingLog -Path $LogPath -Message "Start onboarding: $($rows.Count) row(s) from $CsvPath"
    $results   = @()
    $passwords = @()

    foreach ($row in $rows) {
        $sam    = $null
        $status = 'Failed'
        try {
            if ([string]::IsNullOrWhiteSpace($row.FirstName) -or
                [string]::IsNullOrWhiteSpace($row.LastName)  -or
                [string]::IsNullOrWhiteSpace($row.Department)) {
                $status = 'Skipped (incomplete row)'
                Write-OnboardingLog -Path $LogPath -Level WARN -Message $status
            }
            else {
                $sam = New-OnboardingSamAccountName -FirstName $row.FirstName -LastName $row.LastName

                # 1) Existiert der Benutzer schon?
                if (Get-ADUser -Filter "SamAccountName -eq '$sam'" -ErrorAction SilentlyContinue) {
                    $status = 'Skipped (already exists)'
                    Write-OnboardingLog -Path $LogPath -Level WARN -Message "$sam : $status"
                }
                else {
                    # 2) Existiert die Ziel-OU?
                    $ouDn = "OU=$($row.Department),$BaseOU"
                    Get-ADOrganizationalUnit -Identity $ouDn -ErrorAction Stop | Out-Null

                    # 3) Gruppe sicherstellen
                    $groupName = "GG-$($row.Department)"
                    $group = Get-ADGroup -Filter "Name -eq '$groupName'" -SearchBase $GroupOU -ErrorAction SilentlyContinue
                    if (-not $group -and $PSCmdlet.ShouldProcess($groupName, 'Create group')) {
                        New-ADGroup -Name $groupName -GroupScope Global -GroupCategory Security -Path $GroupOU `
                            -Description 'Created by ADOnboarding' -ErrorAction Stop
                        Write-OnboardingLog -Path $LogPath -Message "Group created: $groupName"
                    }

                    # 4) Benutzer anlegen
                    if ($PSCmdlet.ShouldProcess($sam, "Create user in $ouDn")) {
                        $password = New-OnboardingPassword
                        $userParams = @{
                            Name                  = "$($row.FirstName) $($row.LastName)"
                            GivenName             = $row.FirstName
                            Surname               = $row.LastName
                            SamAccountName        = $sam
                            UserPrincipalName     = "$sam@$UpnSuffix"
                            Department            = $row.Department
                            Description           = 'Created by ADOnboarding'
                            Path                  = $ouDn
                            AccountPassword       = (ConvertTo-SecureString $password -AsPlainText -Force)
                            ChangePasswordAtLogon = $true
                            Enabled               = $true
                            ErrorAction           = 'Stop'
                        }
                        if (-not [string]::IsNullOrWhiteSpace($row.Title)) { $userParams['Title'] = $row.Title }

                        New-ADUser @userParams
                        Add-ADGroupMember -Identity $groupName -Members $sam -ErrorAction Stop

                        $passwords += [pscustomobject]@{ SamAccountName = $sam; InitialPassword = $password }
                        $status = 'Created'
                        Write-OnboardingLog -Path $LogPath -Message "$sam : user created in $ouDn, member of $groupName"
                    }
                    else {
                        $status = 'WhatIf (nothing changed)'
                    }
                }
            }
        }
        catch {
            $status = "Failed: $($_.Exception.Message)"
            Write-OnboardingLog -Path $LogPath -Level ERROR -Message "$sam : $status"
        }
        $results += [pscustomobject]@{ SamAccountName = $sam; Department = $row.Department; Status = $status }
    }

    if ($PasswordExportPath -and $passwords.Count -gt 0) {
        $passwords | Export-Csv -Path $PasswordExportPath -NoTypeInformation -Encoding UTF8
        Write-OnboardingLog -Path $LogPath -Level WARN -Message "Initial passwords exported to $PasswordExportPath - handle securely and delete afterwards"
    }

    Write-OnboardingLog -Path $LogPath -Message 'Onboarding finished'
    $results
}

Export-ModuleMember -Function New-OnboardingSamAccountName, New-OnboardingPassword, Invoke-UserOnboarding
