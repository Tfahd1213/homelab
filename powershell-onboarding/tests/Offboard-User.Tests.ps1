# Unit tests for Offboard-User.ps1, with Active Directory replaced by mocks.
# Run from the powershell-onboarding folder:  Invoke-Pester ./tests

BeforeAll {
    . "$PSScriptRoot/ADStubs.ps1"
    $script:Offboard = Join-Path $PSScriptRoot '..' 'Offboard-User.ps1'
    # Mock bodies can't see $script: variables in Pester 6 (see Onboard-Users.Tests.ps1).
    $global:FakeAD = @{ DisabledOU = 'OU=Disabled Users,DC=lab,DC=local' }

    function Invoke-Offboard([string[]] $Identity, [hashtable] $Extra = @{}) {
        $script:ReportPath = Join-Path $TestDrive "report-$([guid]::NewGuid()).csv"
        & $script:Offboard -Identity $Identity -DisabledOU $global:FakeAD.DisabledOU -ReportPath $script:ReportPath @Extra 6>$null | Out-Null
        Import-Csv $script:ReportPath
    }
}

Describe 'Offboard-User.ps1' {

AfterAll { Remove-Variable FakeAD -Scope Global -ErrorAction SilentlyContinue }

BeforeEach {
    $global:FakeAD.Users = @{
        mpatel = [pscustomobject]@{
            SamAccountName = 'mpatel'; Name = 'Mia Patel'
            DistinguishedName = 'CN=Mia Patel,OU=Sales,DC=lab,DC=local'
            MemberOf = @('CN=GG-Sales,OU=Staff,DC=lab,DC=local', 'CN=VPN Users,OU=Staff,DC=lab,DC=local')
            HomeDirectory = '\\DC01\Home\mpatel'
        }
        nchen = [pscustomobject]@{
            SamAccountName = 'nchen'; Name = 'Noah Chen'
            DistinguishedName = 'CN=Noah Chen,OU=Finance,DC=lab,DC=local'
            MemberOf = @(); HomeDirectory = $null
        }
    }
    # Records the order of every change, to check the account is moved last.
    $global:FakeAD.Calls = [System.Collections.Generic.List[string]]::new()

    Mock Import-Module {} -ParameterFilter { $Name -eq 'ActiveDirectory' }
    Mock Get-ADUser {
        if (-not $global:FakeAD.Users.ContainsKey($Identity)) { throw "Cannot find an object with identity: '$Identity'" }
        $global:FakeAD.Users[$Identity]
    }
    Mock Get-ADGroup { [pscustomobject]@{ Name = ($Identity -replace '^CN=([^,]+),.*$', '$1'); DistinguishedName = $Identity } }
    Mock Disable-ADAccount { $global:FakeAD.Calls.Add('Disable') }
    Mock Set-ADAccountPassword { $global:FakeAD.Calls.Add('ResetPassword') }
    Mock Remove-ADGroupMember { $global:FakeAD.Calls.Add("RemoveFrom:$($Identity.Name)") }
    Mock Set-ADUser { $global:FakeAD.Calls.Add('SetUser') }
    Mock Move-ADObject { $global:FakeAD.Calls.Add('Move') }
}


    Context 'Offboarding a user' {
        It 'disables the account' {
            Invoke-Offboard 'mpatel'
            Should -Invoke Disable-ADAccount -Times 1
        }

        It 'resets the password to a random, read-only SecureString' {
            Invoke-Offboard 'mpatel'
            Should -Invoke Set-ADAccountPassword -Times 1 -ParameterFilter {
                $Reset -and $NewPassword -is [System.Security.SecureString] -and
                $NewPassword.IsReadOnly() -and $NewPassword.Length -eq 36
            }
        }

        It 'uses a different random password each time' {
            $global:FakeAD.Seen = @()
            Mock Set-ADAccountPassword { $global:FakeAD.Seen += [System.Net.NetworkCredential]::new('', $NewPassword).Password }
            Invoke-Offboard 'mpatel', 'nchen'
            $global:FakeAD.Seen.Count | Should -Be 2
            $global:FakeAD.Seen[0] | Should -Not -Be $global:FakeAD.Seen[1]
        }

        It 'removes every group and lists them in the report first' {
            $report = Invoke-Offboard 'mpatel'
            Should -Invoke Remove-ADGroupMember -Times 2
            $report[0].RemovedGroups | Should -Be 'GG-Sales; VPN Users'
        }

        It 'stamps the description with the date' {
            Invoke-Offboard 'mpatel'
            $today = Get-Date -Format 'yyyy-MM-dd'
            Should -Invoke Set-ADUser -Times 1 -ParameterFilter { $Description -like "Offboarded $today by *" }
        }

        It 'moves the account to the disabled OU, as the last change' {
            Invoke-Offboard 'mpatel'
            Should -Invoke Move-ADObject -Times 1 -ParameterFilter {
                $Identity -eq 'CN=Mia Patel,OU=Sales,DC=lab,DC=local' -and $TargetPath -eq $global:FakeAD.DisabledOU
            }
            $global:FakeAD.Calls[-1] | Should -Be 'Move'
        }

        It 'works for a user with no groups and no home folder' {
            $report = Invoke-Offboard 'nchen'
            $report[0].Result | Should -Be 'Offboarded'
            Should -Invoke Remove-ADGroupMember -Times 0
        }

        It 'accepts usernames from the pipeline' {
            'mpatel', 'nchen' | & $script:Offboard -DisabledOU $global:FakeAD.DisabledOU -ReportPath (Join-Path $TestDrive 'p.csv') 6>$null | Out-Null
            Should -Invoke Disable-ADAccount -Times 2
        }
    }

    Context 'Home folder archiving' {
        It 'leaves the home folder alone without -ArchiveHomeRoot' {
            Mock Move-Item {}
            $report = Invoke-Offboard 'mpatel'
            Should -Invoke Move-Item -Times 0
            $report[0].HomeFolder | Should -Be '\\DC01\Home\mpatel'
        }

        It 'moves the home folder to the archive and clears it on the account' {
            Mock Test-Path { $true } -ParameterFilter { $Path -eq '\\DC01\Home\mpatel' }
            Mock Move-Item {}
            $report = Invoke-Offboard 'mpatel' @{ ArchiveHomeRoot = '\\DC01\Archive' }
            Should -Invoke Move-Item -Times 1 -ParameterFilter { $Path -eq '\\DC01\Home\mpatel' -and $Destination -like '*Archive*mpatel' }
            Should -Invoke Set-ADUser -ParameterFilter { $Clear -contains 'HomeDirectory' }
            $report[0].HomeFolder | Should -BeLike '*Archive*mpatel'
        }
    }

    Context 'Safety' {
        It 'changes nothing with -WhatIf' {
            $report = Invoke-Offboard 'mpatel' @{ WhatIf = $true }
            $global:FakeAD.Calls.Count | Should -Be 0
            $report[0].Result | Should -Be 'WhatIf: would offboard'
            $report[0].RemovedGroups | Should -Be 'GG-Sales; VPN Users'
        }

        It 'reports an unknown user as failed and still processes the others' {
            $report = Invoke-Offboard 'ghost', 'mpatel' 3>$null
            $report[0].Result | Should -BeLike 'Failed:*ghost*'
            $report[1].Result | Should -Be 'Offboarded'
        }

        It 'never deletes accounts' {
            Get-Content $script:Offboard -Raw | Should -Not -Match 'Remove-ADUser|Remove-ADObject'
        }
    }
}
