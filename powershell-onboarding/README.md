# PowerShell onboarding and offboarding

Two scripts that automate the most common help desk account tasks in Active Directory.

> **Status: unit-tested, not yet run against a live domain.** 35 automated tests pass,
> with Active Directory replaced by mocks, and PSScriptAnalyzer reports no warnings.
> The home-folder permissions step needs Windows, so it's covered by the manual test
> plan below. The live run happens in the [Windows domain lab](../windows-domain-lab/).

## Onboard-Users.ps1
Takes a CSV of new hires and, for each person:
- creates the account (username = first initial + last name, with a number added if it's taken)
- puts it in the OU for their department, or a default OU
- sets a random 16-character temporary password that must be changed at first logon
- adds them to a `GG-<Department>` security group, creating the group if it doesn't exist
- creates a private home folder and maps it as `H:`
- writes a summary CSV (no passwords in it)

Running the same CSV twice is safe: existing accounts are skipped.

```powershell
.\Onboard-Users.ps1 -CsvPath .\new-hires.sample.csv `
    -DefaultOU "OU=Staff,DC=lab,DC=local" -HomeRoot \\DC01\Home -WhatIf
```

## Offboard-User.ps1
For each departing user:
- disables the account and resets the password to a random value
- saves their group memberships to the report, then removes them
- adds an "Offboarded <date> by <admin>" description
- moves the account to a disabled-users OU
- optionally moves their home folder to an archive share

Nothing is deleted, so an account can be restored if someone was offboarded by mistake.

```powershell
.\Offboard-User.ps1 -Identity mpatel -DisabledOU "OU=Disabled Users,DC=lab,DC=local" -WhatIf
```

## Design choices
- **`-WhatIf` support.** Every change goes through `ShouldProcess`, so a dry run shows exactly what would happen.
- **No passwords in logs.** Temporary passwords only go to a separate file with `-ExportCredentials`, with a warning to delete it.
- **Per-row error handling.** One bad row is reported as `Failed` and the rest still run.
- **Names with apostrophes** (like O'Brien) are escaped in AD filters, and dropped from usernames.

## Automated tests
[Pester](https://pester.dev) unit tests in [`tests/`](tests/) swap every AD command for a mock
backed by a small fake directory, then check what the scripts asked AD to do.

```powershell
Install-Module Pester, PSScriptAnalyzer -Scope CurrentUser
Invoke-Pester ./tests           # 35 tests
Invoke-ScriptAnalyzer -Path .   # lint
```

What they cover: usernames (collisions, apostrophes, the 20-character limit), password
strength and uniqueness, OU placement and fallback, group creation, skipping existing users,
`-WhatIf` making no changes, one bad row not stopping the rest, no passwords in reports,
the offboarding steps and their order, home folder archiving, and unknown users.

**Bugs the tests caught and fixed:**
- With `-WhatIf`, no report was written, because the dry run skipped saving it too.
- With `-WhatIf`, two new hires with the same initials both showed the same username,
  because the first account was never actually created. Usernames picked earlier in the run are now tracked.
- Building network paths (`\\DC01\Home`) with `Join-Path` failed off Windows. Switched to `[IO.Path]::Combine`.
- `PSScriptAnalyzer` flagged a plain-text password in offboarding. That password is now built
  directly as a `SecureString`, since nobody ever needs to know it.

## Manual test plan (domain lab)
- [ ] Run both scripts with `-WhatIf` and check the output
- [ ] Onboard `new-hires.sample.csv`; check the OUs, groups and home folder permissions
- [ ] Run the same CSV again and confirm everyone is skipped
- [ ] Log in as a new user on a domain-joined client; confirm the forced password change and the `H:` drive
- [ ] Offboard a user; confirm they can't log in, the groups are in the report and the account is in the disabled OU

`new-hires.sample.csv` contains made-up names only.
