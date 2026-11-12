<#
.SYNOPSIS
    Offboards one or more Active Directory users.

.DESCRIPTION
    For each user this script:
      - disables the account and resets the password to a random value nobody knows
      - records their group memberships in the report, then removes them
        (Domain Users is kept, since it's the primary group)
      - stamps the description with the offboarding date and who ran it
      - moves the account to the disabled-users OU
      - optionally moves their home folder to an archive share

    Nothing is deleted, so an account can be restored if someone leaves by mistake.
    Run with -WhatIf first.

.PARAMETER Identity
    One or more sAMAccountNames. Also accepts pipeline input,
    e.g. Import-Csv leavers.csv | Select-Object -ExpandProperty Sam | .\Offboard-User.ps1 ...

.PARAMETER DisabledOU
    Distinguished name of the OU for disabled accounts,
    e.g. "OU=Disabled Users,DC=lab,DC=local"

.PARAMETER ArchiveHomeRoot
    Optional UNC path. If set, the user's home folder is moved there.

.PARAMETER ReportPath
    Where the summary CSV is written.

.EXAMPLE
    .\Offboard-User.ps1 -Identity jsmith -DisabledOU "OU=Disabled Users,DC=lab,DC=local" -WhatIf

.NOTES
    Requires the ActiveDirectory module (RSAT).
    Status: unit-tested with Pester (see tests/), not yet run against a live domain.
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory, ValueFromPipeline)] [string[]] $Identity,
    [Parameter(Mandatory)] [string] $DisabledOU,
    [string] $ArchiveHomeRoot,
    [string] $ReportPath = ".\offboarding-report-$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
)

begin {
    Import-Module ActiveDirectory -ErrorAction Stop
    $report = [System.Collections.Generic.List[object]]::new()
    $stamp = "Offboarded $(Get-Date -Format 'yyyy-MM-dd') by $env:USERNAME"

    function Get-RandomSecurePassword {
        # Built straight into a SecureString: nobody needs to know this password,
        # so it never exists as plain text.
        $bytes = [byte[]]::new(24)
        # Create().GetBytes works in both Windows PowerShell 5.1 and PowerShell 7.
        [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes)
        $secure = [System.Security.SecureString]::new()
        # Base64 plus a fixed suffix guarantees every character class is present.
        foreach ($ch in ([Convert]::ToBase64String($bytes) + 'a1!A').ToCharArray()) { $secure.AppendChar($ch) }
        $secure.MakeReadOnly()
        $secure
    }
}

process {
    foreach ($sam in $Identity) {
        $entry = [ordered]@{ Sam = $sam; Name = ''; RemovedGroups = ''; HomeFolder = ''; Result = '' }
        try {
            $user = Get-ADUser -Identity $sam -Properties MemberOf, HomeDirectory, Description
            $entry.Name = $user.Name

            if ($PSCmdlet.ShouldProcess($sam, 'Disable account and reset password')) {
                Disable-ADAccount -Identity $user
                Set-ADAccountPassword -Identity $user -Reset -NewPassword (Get-RandomSecurePassword)
            }

            # Group names go into the report before removal, so access can be restored if needed.
            $groups = @($user.MemberOf | ForEach-Object { Get-ADGroup -Identity $_ })
            $entry.RemovedGroups = ($groups.Name -join '; ')
            foreach ($group in $groups) {
                if ($PSCmdlet.ShouldProcess($sam, "Remove from $($group.Name)")) {
                    Remove-ADGroupMember -Identity $group -Members $user -Confirm:$false
                }
            }

            if ($PSCmdlet.ShouldProcess($sam, "Set description '$stamp'")) {
                Set-ADUser -Identity $user -Description $stamp
            }

            if ($ArchiveHomeRoot -and $user.HomeDirectory -and (Test-Path $user.HomeDirectory)) {
                $dest = [System.IO.Path]::Combine($ArchiveHomeRoot, $sam)
                if ($PSCmdlet.ShouldProcess($user.HomeDirectory, "Move to $dest")) {
                    Move-Item -Path $user.HomeDirectory -Destination $dest
                    Set-ADUser -Identity $user -Clear HomeDirectory, HomeDrive
                }
                $entry.HomeFolder = $dest
            }
            else {
                $entry.HomeFolder = "$($user.HomeDirectory)"
            }

            # Move last: it changes the account's distinguished name.
            if ($PSCmdlet.ShouldProcess($sam, "Move to $DisabledOU")) {
                Move-ADObject -Identity $user.DistinguishedName -TargetPath $DisabledOU
            }

            $entry.Result = if ($WhatIfPreference) { 'WhatIf: would offboard' } else { 'Offboarded' }
        }
        catch {
            $entry.Result = "Failed: $($_.Exception.Message)"
            Write-Warning "${sam}: $($_.Exception.Message)"
        }
        $report.Add([pscustomobject]$entry)
    }
}

end {
    # The report is written even during -WhatIf: it's the point of a dry run.
    $report | Export-Csv -Path $ReportPath -NoTypeInformation -WhatIf:$false
    $report | Format-Table Sam, Name, Result -AutoSize
    Write-Information "Summary (including removed groups) written to $ReportPath" -InformationAction Continue
}
