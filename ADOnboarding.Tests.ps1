# Pester 5 Tests fuer ADOnboarding.psm1
# Ausfuehren:  Invoke-Pester -Path .\Tests -Output Detailed

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '..\ADOnboarding.psm1') -Force
}

Describe 'New-OnboardingSamAccountName' {
    It 'baut vorname.nachname in Kleinbuchstaben' {
        New-OnboardingSamAccountName -FirstName 'Anna' -LastName 'Muster' | Should -Be 'anna.muster'
    }
    It 'ersetzt Umlaute' {
        $first = 'J' + [char]0xFC + 'rgen'
        $last  = 'M' + [char]0xFC + 'ller'
        New-OnboardingSamAccountName -FirstName $first -LastName $last | Should -Be 'juergen.mueller'
    }
    It 'entfernt Leerzeichen' {
        New-OnboardingSamAccountName -FirstName 'Anna Maria' -LastName 'Muster' | Should -Be 'annamaria.muster'
    }
    It 'ist hoechstens 20 Zeichen lang' {
        (New-OnboardingSamAccountName -FirstName 'Maximilian' -LastName 'Musterhausen-Langenberg').Length | Should -BeLessOrEqual 20
    }
}

Describe 'New-OnboardingPassword' {
    It 'hat die gewuenschte Laenge' {
        (New-OnboardingPassword -Length 20).Length | Should -Be 20
    }
    It 'enthaelt Gross-, Kleinbuchstaben, Ziffer und Sonderzeichen' {
        $pw = New-OnboardingPassword
        $pw | Should -MatchExactly '[A-Z]'
        $pw | Should -MatchExactly '[a-z]'
        $pw | Should -Match '[0-9]'
        $pw | Should -Match '[^A-Za-z0-9]'
    }
    It 'erzeugt bei jedem Aufruf ein anderes Passwort' {
        New-OnboardingPassword | Should -Not -Be (New-OnboardingPassword)
    }
}

Describe 'Invoke-UserOnboarding' {
    BeforeAll {
        $csv = Join-Path $TestDrive 'users.csv'
        $first = 'J' + [char]0xFC + 'rgen'
        $last  = 'M' + [char]0xFC + 'ller'
        @(
            'FirstName,LastName,Department,Title'
            'Anna,Muster,IT,Systemadministratorin'
            "$first,$last,HR,Recruiter"
        ) | Set-Content -Path $csv -Encoding UTF8

        $badCsv = Join-Path $TestDrive 'bad.csv'
        @('FirstName,LastName', 'Anna,Muster') | Set-Content -Path $badCsv -Encoding UTF8
    }

    BeforeEach {
        $log = Join-Path $TestDrive ('test-{0}.log' -f [guid]::NewGuid())
        # AD-Cmdlets werden gemockt: der Test aendert nichts im echten Active Directory
        Mock Get-ADUser { $null } -ModuleName ADOnboarding
        Mock Get-ADOrganizationalUnit { [pscustomobject]@{ Name = 'OU' } } -ModuleName ADOnboarding
        Mock Get-ADGroup { [pscustomobject]@{ Name = 'GG' } } -ModuleName ADOnboarding
        Mock New-ADGroup { } -ModuleName ADOnboarding
        Mock New-ADUser { } -ModuleName ADOnboarding
        Mock Add-ADGroupMember { } -ModuleName ADOnboarding
    }

    It 'legt fuer jede gueltige Zeile einen Benutzer an' {
        Invoke-UserOnboarding -CsvPath $csv -LogPath $log | Out-Null
        Should -Invoke New-ADUser -ModuleName ADOnboarding -Times 2 -Exactly
        Should -Invoke Add-ADGroupMember -ModuleName ADOnboarding -Times 2 -Exactly
    }

    It 'ueberspringt Benutzer, die schon existieren' {
        Mock Get-ADUser { [pscustomobject]@{ SamAccountName = 'anna.muster' } } `
            -ParameterFilter { $Filter -like '*anna.muster*' } -ModuleName ADOnboarding
        $result = Invoke-UserOnboarding -CsvPath $csv -LogPath $log
        Should -Invoke New-ADUser -ModuleName ADOnboarding -Times 1 -Exactly
        ($result | Where-Object SamAccountName -eq 'anna.muster').Status | Should -BeLike 'Skipped*'
    }

    It 'aendert mit -WhatIf nichts' {
        Invoke-UserOnboarding -CsvPath $csv -LogPath $log -WhatIf | Out-Null
        Should -Invoke New-ADUser -ModuleName ADOnboarding -Times 0 -Exactly
        Should -Invoke Add-ADGroupMember -ModuleName ADOnboarding -Times 0 -Exactly
    }

    It 'meldet einen Fehler, wenn die Ziel-OU fehlt, und macht weiter' {
        Mock Get-ADOrganizationalUnit { throw 'OU not found' } `
            -ParameterFilter { $Identity -like 'OU=HR,*' } -ModuleName ADOnboarding
        $result = Invoke-UserOnboarding -CsvPath $csv -LogPath $log
        ($result | Where-Object Department -eq 'HR').Status | Should -BeLike 'Failed*'
        ($result | Where-Object Department -eq 'IT').Status | Should -Be 'Created'
    }

    It 'bricht ab, wenn eine CSV-Spalte fehlt' {
        { Invoke-UserOnboarding -CsvPath $badCsv -LogPath $log } | Should -Throw '*Department*'
    }

    It 'schreibt ein Log' {
        Invoke-UserOnboarding -CsvPath $csv -LogPath $log | Out-Null
        $log | Should -Exist
        Get-Content $log -Raw | Should -Match 'anna.muster'
    }
}
