# PowerShell onboarding and offboarding

Two scripts that automate the most common help desk account tasks in Active Directory.

> **Status: written, not yet tested.** These scripts haven't been run against a live
> domain yet. They'll be tested in the [Windows domain lab](../windows-domain-lab/),
> and this section will be updated with the results and any fixes.

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

## Test plan
- [ ] Run both scripts with `-WhatIf` and check the output
- [ ] Onboard `new-hires.sample.csv`; check the OUs, groups and home folder permissions
- [ ] Run the same CSV again and confirm everyone is skipped
- [ ] Log in as a new user on a domain-joined client; confirm the forced password change and the `H:` drive
- [ ] Offboard a user; confirm they can't log in, the groups are in the report and the account is in the disabled OU

`new-hires.sample.csv` contains made-up names only.
