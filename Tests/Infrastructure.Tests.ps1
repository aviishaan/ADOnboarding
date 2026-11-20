# Pester 5 tests for Test-ADInfrastructure.
# Run: Invoke-Pester -Path .\Tests\Infrastructure.Tests.ps1 -Output Detailed

BeforeAll {
    . (Join-Path $PSScriptRoot '..\InfrastructureValidation.ps1')
    function Get-ADDomain { }
    function Get-ADOrganizationalUnit { }
}

Describe 'Test-ADInfrastructure' {
    BeforeEach {
        Mock Resolve-ADHostAddress {
            [pscustomobject]@{ AddressList = @([System.Net.IPAddress]::Loopback) }
        }
        Mock Resolve-DnsName {
            [pscustomobject]@{ Type = 'SRV'; NameTarget = 'dc01.alptech.local' }
        }
        Mock Test-NetConnection { $true }
        Mock Get-Module { [pscustomobject]@{ Name = 'ActiveDirectory' } } -ParameterFilter { $ListAvailable -and $Name -eq 'ActiveDirectory' }
        Mock Import-Module { }
        Mock Get-ADDomain { [pscustomobject]@{ DNSRoot = 'alptech.local' } }
        Mock Get-ADOrganizationalUnit { [pscustomobject]@{ DistinguishedName = $Identity } }
    }

    It 'returns PASS when DNS, ports, domain and configured OUs are available' {
        $result = Test-ADInfrastructure -Domain 'alptech.local' -DomainController 'dc01.alptech.local' -RequiredOUs @('OU=user,DC=alptech,DC=local','OU=group,DC=alptech,DC=local')
        ($result | Where-Object Check -eq 'DNS Resolution').Status | Should -Be 'PASS'
        ($result | Where-Object Check -eq 'DNS SRV Record').Status | Should -Be 'PASS'
        ($result | Where-Object Check -eq 'LDAP TCP 389').Status | Should -Be 'PASS'
        ($result | Where-Object Check -eq 'Active Directory Domain').Status | Should -Be 'PASS'
        ($result | Where-Object Check -like 'OU:*' | Where-Object Status -ne 'PASS').Count | Should -Be 0
    }

    It 'reports a failed LDAP port check' {
        Mock Test-NetConnection { $false } -ParameterFilter { $Port -eq 389 }
        $result = Test-ADInfrastructure -Domain 'alptech.local' -DomainController 'dc01.alptech.local' -TcpPorts @(389)
        ($result | Where-Object Check -eq 'LDAP TCP 389').Status | Should -Be 'FAIL'
    }

    It 'reports missing OUs without stopping the remaining checks' {
        Mock Get-ADOrganizationalUnit { throw 'OU not found' } -ParameterFilter { $Identity -eq 'OU=missing,DC=alptech,DC=local' }
        $result = Test-ADInfrastructure -Domain 'alptech.local' -DomainController 'dc01.alptech.local' -RequiredOUs @('OU=missing,DC=alptech,DC=local')
        ($result | Where-Object Check -like 'OU:*').Status | Should -Be 'FAIL'
        ($result | Where-Object Check -eq 'Active Directory Domain').Status | Should -Be 'PASS'
    }

    It 'exports results to CSV when ReportPath is supplied' {
        $report = Join-Path $TestDrive 'infrastructure-report.csv'
        $null = Test-ADInfrastructure -Domain 'alptech.local' -DomainController 'dc01.alptech.local' -TcpPorts @() -ReportPath $report
        $report | Should -Exist
        (Import-Csv $report).Count | Should -BeGreaterThan 0
    }

    It 'reports DNS resolution errors as FAIL' {
        Mock Resolve-ADHostAddress { throw 'DNS lookup failed' }
        $result = Test-ADInfrastructure -Domain 'alptech.local' -DomainController 'unknown.alptech.local' -TcpPorts @()
        ($result | Where-Object Check -eq 'DNS Resolution').Status | Should -Be 'FAIL'
    }
}
