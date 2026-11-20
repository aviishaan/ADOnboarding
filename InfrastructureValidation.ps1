# InfrastructureValidation.ps1
# Read-only Active Directory infrastructure checks.
# Compatible with Windows PowerShell 5.1.

function Resolve-ADHostAddress {\n    param([Parameter(Mandatory)][string]$ComputerName)\n    [System.Net.Dns]::GetHostEntry($ComputerName)\n}\n\nfunction Test-ADInfrastructure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidateNotNullOrEmpty()]
        [string]$Domain,

        [string]$DomainController,

        [string[]]$RequiredOUs = @(),

        [int[]]$TcpPorts = @(389, 88, 445),

        [string]$ReportPath
    )

    $results = New-Object System.Collections.Generic.List[object]
    $target = if ([string]::IsNullOrWhiteSpace($DomainController)) { $Domain } else { $DomainController }

    function Add-ValidationResult {
        param([string]$Check, [bool]$Passed, [string]$Details)
        $results.Add([pscustomobject]@{
            Check = $Check
            Status = if ($Passed) { 'PASS' } else { 'FAIL' }
            Details = $Details
            Timestamp = Get-Date
        }) | Out-Null
    }

    # DNS A/host resolution
    try {
        $resolved = Resolve-ADHostAddress -ComputerName $target
        Add-ValidationResult -Check 'DNS Resolution' -Passed ($null -ne $resolved.AddressList -and $resolved.AddressList.Count -gt 0) -Details ("Resolved {0}" -f $target)
    }
    catch {
        Add-ValidationResult -Check 'DNS Resolution' -Passed $false -Details $_.Exception.Message
    }

    # Domain Controller SRV record
    try {
        $srvName = "_ldap._tcp.dc._msdcs.$Domain"
        $srv = Resolve-DnsName -Name $srvName -Type SRV -ErrorAction Stop
        $srvRecords = @($srv | Where-Object { $_.Type -eq 'SRV' })
        Add-ValidationResult -Check 'DNS SRV Record' -Passed ($srvRecords.Count -gt 0) -Details ("Found {0} LDAP SRV record(s)" -f $srvRecords.Count)
    }
    catch {
        Add-ValidationResult -Check 'DNS SRV Record' -Passed $false -Details $_.Exception.Message
    }

    foreach ($port in $TcpPorts) {
        try {
            $connection = Test-NetConnection -ComputerName $target -Port $port -WarningAction SilentlyContinue -InformationLevel Quiet
            $names = @{ 389 = 'LDAP TCP 389'; 636 = 'LDAPS TCP 636'; 88 = 'Kerberos TCP 88'; 445 = 'SMB TCP 445'; 135 = 'RPC Endpoint Mapper TCP 135' }
            $checkName = if ($names.ContainsKey($port)) { $names[$port] } else { "TCP $port" }
            Add-ValidationResult -Check $checkName -Passed ([bool]$connection) -Details ("{0}:{1}" -f $target, $port)
        }
        catch {
            Add-ValidationResult -Check ("TCP $port") -Passed $false -Details $_.Exception.Message
        }
    }

    # ActiveDirectory PowerShell module
    $module = Get-Module -ListAvailable -Name ActiveDirectory
    Add-ValidationResult -Check 'ActiveDirectory Module' -Passed ($null -ne $module) -Details $(if ($module) { 'Module is installed' } else { 'ActiveDirectory module not found' })

    # AD domain and required OU lookup
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
        $adDomain = Get-ADDomain -Identity $Domain -Server $target -ErrorAction Stop
        Add-ValidationResult -Check 'Active Directory Domain' -Passed ($null -ne $adDomain) -Details ("Connected to {0}" -f $Domain)

        foreach ($ou in $RequiredOUs) {
            try {
                $null = Get-ADOrganizationalUnit -Identity $ou -Server $target -ErrorAction Stop
                Add-ValidationResult -Check ("OU: $ou") -Passed $true -Details 'OU exists'
            }
            catch {
                Add-ValidationResult -Check ("OU: $ou") -Passed $false -Details $_.Exception.Message
            }
        }
    }
    catch {
        Add-ValidationResult -Check 'Active Directory Domain' -Passed $false -Details $_.Exception.Message
        foreach ($ou in $RequiredOUs) {
            Add-ValidationResult -Check ("OU: $ou") -Passed $false -Details 'Skipped because domain connectivity failed'
        }
    }

    $output = @($results)
    if ($ReportPath) {
        $output | Export-Csv -Path $ReportPath -NoTypeInformation -Encoding UTF8
    }

    $output
}

# Dot-source this file or import it as a script; the function does not modify AD.
