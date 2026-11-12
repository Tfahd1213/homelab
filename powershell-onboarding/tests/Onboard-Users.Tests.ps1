# Unit tests for Onboard-Users.ps1. Active Directory is replaced with mocks backed by
# an in-memory "directory", so these run anywhere PowerShell 7 runs.
# Run from the powershell-onboarding folder:  Invoke-Pester ./tests

BeforeAll {
    . "$PSScriptRoot/ADStubs.ps1"
    $script:Onboard = Join-Path $PSScriptRoot '..' 'Onboard-Users.ps1'
    # Mock bodies can't see $script: variables in Pester 6, so the fake directory
    # lives in one global table that is removed again in AfterAll.
    $global:FakeAD = @{ DefaultOU = 'OU=Staff,DC=lab,DC=local' }

    function Invoke-Onboard([object[]] $Rows, [hashtable] $Extra = @{}) {
        $csv = Join-Path $TestDrive "hires-$([guid]::NewGuid()).csv"
        $Rows | Export-Csv -Path $csv -NoTypeInformation
        $script:ReportPath = Join-Path $TestDrive "report-$([guid]::NewGuid()).csv"
        & $script:Onboard -CsvPath $csv -DefaultOU $global:FakeAD.DefaultOU -ReportPath $script:ReportPath @Extra 6>$null | Out-Null
        Import-Csv $script:ReportPath
    }

    function Hire($First, $Last, $Dept = 'Sales', $Title = 'Rep') {
        [pscustomobject]@{ FirstName = $First; LastName = $Last; Department = $Dept; Title = $Title }
    }
}

Describe 'Onboard-Users.ps1' {

AfterAll { Remove-Variable FakeAD -Scope Global -ErrorAction SilentlyContinue }

BeforeEach {
    # The fake directory, reset before every test.
    $global:FakeAD.ExistingSams = @()
    $global:FakeAD.ExistingNames = @()
    $global:FakeAD.OUs = @('OU=Sales,DC=lab,DC=local')
    $global:FakeAD.Groups = @('GG-Sales')
    $global:FakeAD.Created = [System.Collections.Generic.List[object]]::new()

    Mock Import-Module {} -ParameterFilter { $Name -eq 'ActiveDirectory' }
    Mock Get-ADDomain { [pscustomobject]@{ DNSRoot = 'lab.local'; DistinguishedName = 'DC=lab,DC=local'; NetBIOSName = 'LAB' } }
    Mock Get-ADUser {
        if ($Filter -match "^SamAccountName -eq '(.+)'$" -and $global:FakeAD.ExistingSams -contains $Matches[1]) { [pscustomobject]@{ SamAccountName = $Matches[1] } }
        elseif ($Filter -match "^Name -eq '(.+)'$" -and $global:FakeAD.ExistingNames -contains ($Matches[1] -replace "''", "'")) { [pscustomobject]@{ Name = $Matches[1] } }
    }
    Mock Get-ADOrganizationalUnit {
        if ($Filter -match "DistinguishedName -eq '(.+)'$" -and $global:FakeAD.OUs -contains $Matches[1]) { [pscustomobject]@{ DistinguishedName = $Matches[1] } }
    }
    Mock Get-ADGroup {
        if ($Filter -match "^Name -eq '(.+)'$" -and $global:FakeAD.Groups -contains $Matches[1]) { [pscustomobject]@{ Name = $Matches[1] } }
    }
    Mock New-ADUser {
        # $PSBoundParameters is empty inside Pester 6 mock bodies, so record the parameters by name.
        $global:FakeAD.Created.Add([pscustomobject]@{
                SamAccountName = $SamAccountName; UserPrincipalName = $UserPrincipalName; Path = $Path
                AccountPassword = $AccountPassword; ChangePasswordAtLogon = $ChangePasswordAtLogon; Enabled = $Enabled
            })
        $global:FakeAD.ExistingSams += $SamAccountName
    }
    Mock New-ADGroup { $global:FakeAD.Groups += $Name }
    Mock Add-ADGroupMember {}
    Mock Set-ADUser {}
}


    Context 'Usernames' {
        It 'uses first initial + last name, lowercase' {
            Invoke-Onboard @(Hire 'Ava' 'Martin')
            $global:FakeAD.Created[0].SamAccountName | Should -Be 'amartin'
            $global:FakeAD.Created[0].UserPrincipalName | Should -Be 'amartin@lab.local'
        }

        It 'removes apostrophes and other symbols (O''Brien -> lobrien)' {
            Invoke-Onboard @(Hire 'Liam' "O'Brien")
            $global:FakeAD.Created[0].SamAccountName | Should -Be 'lobrien'
        }

        It 'adds a number when the username is already taken' {
            $global:FakeAD.ExistingSams = @('amartin')
            Invoke-Onboard @(Hire 'Alex' 'Martin')
            $global:FakeAD.Created[0].SamAccountName | Should -Be 'amartin2'
        }

        It 'gives two new hires with the same initials in one CSV different usernames' {
            Invoke-Onboard @((Hire 'Ava' 'Martin'), (Hire 'Alex' 'Martin'))
            $global:FakeAD.Created.SamAccountName | Should -Be @('amartin', 'amartin2')
        }

        It 'keeps usernames within the 20-character AD limit' {
            Invoke-Onboard @(Hire 'Christopher' 'Montgomery-Wellington')
            $global:FakeAD.Created[0].SamAccountName | Should -Be 'cmontgomerywellingto'
            $global:FakeAD.Created[0].SamAccountName.Length | Should -BeLessOrEqual 20
        }
    }

    Context 'Account settings' {
        It 'forces a password change at first logon and enables the account' {
            Invoke-Onboard @(Hire 'Ava' 'Martin')
            $global:FakeAD.Created[0].ChangePasswordAtLogon | Should -BeTrue
            $global:FakeAD.Created[0].Enabled | Should -BeTrue
        }

        It 'generates a 16-character password with upper, lower, digit and symbol' {
            Invoke-Onboard @(Hire 'Ava' 'Martin')
            $plain = [System.Net.NetworkCredential]::new('', $global:FakeAD.Created[0].AccountPassword).Password
            $plain.Length | Should -Be 16
            $plain | Should -MatchExactly '[A-Z]'
            $plain | Should -MatchExactly '[a-z]'
            $plain | Should -Match '[0-9]'
            $plain | Should -Match '[!@#$%^&*?]'
        }

        It 'gives each user a different password' {
            Invoke-Onboard @((Hire 'Ava' 'Martin'), (Hire 'Noah' 'Chen'))
            $p = $global:FakeAD.Created | ForEach-Object { [System.Net.NetworkCredential]::new('', $_.AccountPassword).Password }
            $p[0] | Should -Not -Be $p[1]
        }

        It 'places users in their department OU when it exists' {
            Invoke-Onboard @(Hire 'Ava' 'Martin' 'Sales')
            $global:FakeAD.Created[0].Path | Should -Be 'OU=Sales,DC=lab,DC=local'
        }

        It 'falls back to the default OU when the department has no OU' {
            Invoke-Onboard @(Hire 'Noah' 'Chen' 'Finance')
            $global:FakeAD.Created[0].Path | Should -Be $global:FakeAD.DefaultOU
        }
    }

    Context 'Groups' {
        It 'adds the user to the existing department group without recreating it' {
            Invoke-Onboard @(Hire 'Ava' 'Martin' 'Sales')
            Should -Invoke New-ADGroup -Times 0
            Should -Invoke Add-ADGroupMember -Times 1 -ParameterFilter { $Identity -eq 'GG-Sales' -and $Members -eq 'amartin' }
        }

        It 'creates a missing department group once, even for several new hires' {
            Invoke-Onboard @((Hire 'Noah' 'Chen' 'Finance'), (Hire 'Zoe' 'Kim' 'Finance'))
            Should -Invoke New-ADGroup -Times 1 -ParameterFilter { $Name -eq 'GG-Finance' -and $Path -eq $global:FakeAD.DefaultOU }
            Should -Invoke Add-ADGroupMember -Times 2 -ParameterFilter { $Identity -eq 'GG-Finance' }
        }
    }

    Context 'Safety' {
        It 'skips people who already have an account' {
            $global:FakeAD.ExistingNames = @('Ava Martin')
            $report = Invoke-Onboard @(Hire 'Ava' 'Martin')
            Should -Invoke New-ADUser -Times 0
            $report[0].Result | Should -Be 'Skipped: account already exists'
        }

        It 'matches existing names that contain an apostrophe' {
            $global:FakeAD.ExistingNames = @("Liam O'Brien")
            $report = Invoke-Onboard @(Hire 'Liam' "O'Brien")
            $report[0].Result | Should -Be 'Skipped: account already exists'
        }

        It 'changes nothing with -WhatIf' {
            $report = Invoke-Onboard @((Hire 'Ava' 'Martin'), (Hire 'Noah' 'Chen' 'Finance')) @{ WhatIf = $true }
            Should -Invoke New-ADUser -Times 0
            Should -Invoke New-ADGroup -Times 0
            Should -Invoke Add-ADGroupMember -Times 0
            $report.Result | Should -Be @('WhatIf: would create', 'WhatIf: would create')
        }

        It 'shows the real usernames in a -WhatIf report, even for same-initial hires' {
            # Regression test: nothing is created during -WhatIf, so the second Martin
            # used to be reported as "amartin" too.
            $report = Invoke-Onboard @((Hire 'Ava' 'Martin'), (Hire 'Alex' 'Martin')) @{ WhatIf = $true }
            $report.Sam | Should -Be @('amartin', 'amartin2')
        }

        It 'reports a failed row and still processes the rest' {
            Mock New-ADUser { throw 'The server is unwilling to process the request' } -ParameterFilter { $SamAccountName -eq 'nchen' }
            $report = Invoke-Onboard @((Hire 'Noah' 'Chen'), (Hire 'Ava' 'Martin')) 3>$null
            $report[0].Result | Should -BeLike 'Failed:*unwilling*'
            $report[1].Result | Should -Be 'Created'
        }

        It 'reports rows with a missing name as failed' {
            $report = Invoke-Onboard @(Hire '' 'Martin') 3>$null
            $report[0].Result | Should -Be 'Failed: Missing first or last name'
            Should -Invoke New-ADUser -Times 0
        }
    }

    Context 'Passwords in output files' {
        It 'never writes passwords to the summary report' {
            Invoke-Onboard @(Hire 'Ava' 'Martin')
            $plain = [System.Net.NetworkCredential]::new('', $global:FakeAD.Created[0].AccountPassword).Password
            Get-Content $script:ReportPath -Raw | Should -Not -Match ([regex]::Escape($plain))
            (Import-Csv $script:ReportPath | Get-Member -MemberType NoteProperty).Name | Should -Not -Contain 'TempPassword'
        }

        It 'writes no credentials file unless -ExportCredentials is used' {
            Invoke-Onboard @(Hire 'Ava' 'Martin')
            Test-Path ($script:ReportPath -replace '\.csv$', '-CREDENTIALS.csv') | Should -BeFalse
        }

        It 'writes the matching temporary passwords with -ExportCredentials' {
            Invoke-Onboard @(Hire 'Ava' 'Martin') @{ ExportCredentials = $true } 3>$null
            $creds = Import-Csv ($script:ReportPath -replace '\.csv$', '-CREDENTIALS.csv')
            $creds[0].Sam | Should -Be 'amartin'
            $creds[0].TempPassword | Should -Be ([System.Net.NetworkCredential]::new('', $global:FakeAD.Created[0].AccountPassword).Password)
        }
    }

    Context 'Home folders' {
        It 'skips home folders when -HomeRoot is not given' {
            Invoke-Onboard @(Hire 'Ava' 'Martin')
            Should -Invoke Set-ADUser -Times 0
        }
        # Creating the folder and its NTFS permissions needs Windows; it's covered by the
        # manual test plan in the domain lab instead.
    }
}
