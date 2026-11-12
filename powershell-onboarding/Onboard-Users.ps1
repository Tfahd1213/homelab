<#
.SYNOPSIS
    Creates Active Directory accounts for new hires from a CSV file.

.DESCRIPTION
    For each row in the CSV this script:
      - skips the row if an account with that name already exists
      - creates the user in the OU named after their department (or -DefaultOU)
      - generates a random temporary password and forces a change at first logon
      - adds the user to the department security group (GG-<Department>), creating it if needed
      - creates a home folder that only the user, Administrators and SYSTEM can access
      - writes a summary report with no passwords in it

    Run with -WhatIf first to see what would happen without changing anything.

.PARAMETER CsvPath
    CSV with the columns FirstName, LastName, Department, Title.

.PARAMETER DefaultOU
    Distinguished name of the OU used when a department has no OU of its own,
    e.g. "OU=Staff,DC=lab,DC=local". New department groups are created here too.

.PARAMETER HomeRoot
    UNC path of the share that holds home folders, e.g. \\DC01\Home

.PARAMETER ReportPath
    Where the summary CSV is written.

.PARAMETER ExportCredentials
    Also write the temporary passwords to a separate CSV. Off by default, because
    passwords in a file are a risk. Hand them over securely and delete the file.

.EXAMPLE
    .\Onboard-Users.ps1 -CsvPath .\new-hires.sample.csv `
        -DefaultOU "OU=Staff,DC=lab,DC=local" -HomeRoot \\DC01\Home -WhatIf

.NOTES
    Requires the ActiveDirectory module (RSAT) and rights to create users.
    Status: written, not yet run against a live domain. See README.md.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory)] [ValidateScript({ Test-Path $_ })] [string] $CsvPath,
    [Parameter(Mandatory)] [string] $DefaultOU,
    [Parameter(Mandatory)] [string] $HomeRoot,
    [string] $ReportPath = ".\onboarding-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv",
    [switch] $ExportCredentials
)

Import-Module ActiveDirectory -ErrorAction Stop

$domain = Get-ADDomain
$upnSuffix = $domain.DNSRoot

function ConvertTo-FilterValue([string] $value) {
    # Single quotes must be doubled inside an AD filter string (e.g. O'Brien).
    $value -replace "'", "''"
}

function New-TempPassword {
    # 16 characters drawn from all four character classes, skipping look-alikes (0/O, 1/l/I).
    $sets = @('ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnpqrstuvwxyz', '23456789', '!@#$%^&*?')
    $chars = @(foreach ($s in $sets) { $s[(Get-Random -Maximum $s.Length)] })
    $all = $sets -join ''
    $chars += 1..12 | ForEach-Object { $all[(Get-Random -Maximum $all.Length)] }
    -join ($chars | Sort-Object { Get-Random })
}

function Get-UniqueSam([string] $first, [string] $last) {
    # First initial + last name, lowercase, letters and digits only, max 20 characters.
    $base = ($first.Substring(0, 1) + $last).ToLower() -replace '[^a-z0-9]', ''
    $base = $base.Substring(0, [Math]::Min(20, $base.Length))
    $candidate, $n = $base, 1
    while (Get-ADUser -Filter "SamAccountName -eq '$candidate'") {
        $n++
        $candidate = $base.Substring(0, [Math]::Min($base.Length, 20 - "$n".Length)) + $n
    }
    $candidate
}

$report = [System.Collections.Generic.List[object]]::new()
$creds = [System.Collections.Generic.List[object]]::new()

foreach ($row in Import-Csv -Path $CsvPath) {
    $first, $last = "$($row.FirstName)".Trim(), "$($row.LastName)".Trim()
    $dept, $title = "$($row.Department)".Trim(), "$($row.Title)".Trim()
    $entry = [ordered]@{ Name = "$first $last"; Sam = ''; OU = ''; Group = ''; Result = '' }

    try {
        if (-not $first -or -not $last) { throw 'Missing first or last name' }

        # Matching on the full name makes re-running the same CSV safe.
        if (Get-ADUser -Filter "Name -eq '$(ConvertTo-FilterValue "$first $last")'") {
            $entry.Result = 'Skipped: account already exists'
            $report.Add([pscustomobject]$entry)
            continue
        }

        $sam = Get-UniqueSam $first $last
        $deptOu = "OU=$dept,$($domain.DistinguishedName)"
        $hasDeptOu = $dept -and (Get-ADOrganizationalUnit -Filter "DistinguishedName -eq '$(ConvertTo-FilterValue $deptOu)'")
        $ou = if ($hasDeptOu) { $deptOu } else { $DefaultOU }
        $entry.Sam, $entry.OU = $sam, $ou

        $password = New-TempPassword
        if ($PSCmdlet.ShouldProcess("$sam@$upnSuffix", "Create user in $ou")) {
            New-ADUser -Name "$first $last" -GivenName $first -Surname $last `
                -DisplayName "$first $last" -SamAccountName $sam `
                -UserPrincipalName "$sam@$upnSuffix" `
                -Department $dept -Title $title -Path $ou `
                -AccountPassword (ConvertTo-SecureString $password -AsPlainText -Force) `
                -ChangePasswordAtLogon $true -Enabled $true
        }

        if ($dept) {
            $groupName = "GG-$dept"
            if (-not (Get-ADGroup -Filter "Name -eq '$(ConvertTo-FilterValue $groupName)'")) {
                if ($PSCmdlet.ShouldProcess($groupName, "Create security group in $DefaultOU")) {
                    New-ADGroup -Name $groupName -GroupScope Global -GroupCategory Security -Path $DefaultOU
                }
            }
            if ($PSCmdlet.ShouldProcess($sam, "Add to $groupName")) {
                Add-ADGroupMember -Identity $groupName -Members $sam
            }
            $entry.Group = $groupName
        }

        # Inheritance is removed so other users can't browse into the folder.
        $homePath = Join-Path $HomeRoot $sam
        if ($PSCmdlet.ShouldProcess($homePath, 'Create home folder and set permissions')) {
            New-Item -ItemType Directory -Path $homePath -Force | Out-Null
            $acl = Get-Acl $homePath
            $acl.SetAccessRuleProtection($true, $false)
            foreach ($rule in @(
                    @('BUILTIN\Administrators', 'FullControl'),
                    @('NT AUTHORITY\SYSTEM', 'FullControl'),
                    @("$($domain.NetBIOSName)\$sam", 'Modify'))) {
                $acl.AddAccessRule([System.Security.AccessControl.FileSystemAccessRule]::new(
                        $rule[0], $rule[1], 'ContainerInherit,ObjectInherit', 'None', 'Allow'))
            }
            Set-Acl -Path $homePath -AclObject $acl
            Set-ADUser -Identity $sam -HomeDirectory $homePath -HomeDrive 'H:'
        }

        $creds.Add([pscustomobject]@{ Sam = $sam; TempPassword = $password })
        $entry.Result = if ($WhatIfPreference) { 'WhatIf: would create' } else { 'Created' }
    }
    catch {
        $entry.Result = "Failed: $($_.Exception.Message)"
        Write-Warning "$($entry.Name): $($_.Exception.Message)"
    }
    $report.Add([pscustomobject]$entry)
}

$report | Export-Csv -Path $ReportPath -NoTypeInformation
$report | Format-Table -AutoSize

if ($ExportCredentials -and $creds.Count -and -not $WhatIfPreference) {
    $credPath = $ReportPath -replace '\.csv$', '-CREDENTIALS.csv'
    $creds | Export-Csv -Path $credPath -NoTypeInformation
    Write-Warning "Temporary passwords written to $credPath. Hand them out securely, then delete the file."
}

Write-Host "`nSummary written to $ReportPath"
Write-Host ("Created: {0}   Skipped: {1}   Failed: {2}" -f
    @($report | Where-Object Result -Match '^(Created|WhatIf)').Count,
    @($report | Where-Object Result -Match '^Skipped').Count,
    @($report | Where-Object Result -Match '^Failed').Count)
