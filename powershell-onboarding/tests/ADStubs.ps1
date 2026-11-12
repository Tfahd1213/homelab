# Empty stand-ins for the ActiveDirectory module's commands, so the scripts can run
# (and be mocked by Pester) on machines without RSAT, including macOS and Linux.
# The parameters match what the scripts pass, so Pester can filter on them.

function global:Get-ADDomain { [CmdletBinding()] param($Server) }
function global:Get-ADUser { [CmdletBinding()] param($Identity, $Filter, $Properties) }
function global:Get-ADOrganizationalUnit { [CmdletBinding()] param($Filter) }
function global:Get-ADGroup { [CmdletBinding()] param($Identity, $Filter) }
function global:New-ADUser {
    [CmdletBinding()] param($Name, $GivenName, $Surname, $DisplayName, $SamAccountName,
        $UserPrincipalName, $Department, $Title, $Path, $AccountPassword, $ChangePasswordAtLogon, $Enabled)
}
function global:New-ADGroup { [CmdletBinding()] param($Name, $GroupScope, $GroupCategory, $Path) }
function global:Add-ADGroupMember { [CmdletBinding()] param($Identity, $Members) }
function global:Set-ADUser { [CmdletBinding()] param($Identity, $HomeDirectory, $HomeDrive, $Description, $Clear) }
function global:Disable-ADAccount { [CmdletBinding()] param($Identity) }
function global:Set-ADAccountPassword { [CmdletBinding()] param($Identity, [switch] $Reset, $NewPassword) }
function global:Remove-ADGroupMember { [CmdletBinding()] param($Identity, $Members, [switch] $Confirm) }
function global:Move-ADObject { [CmdletBinding()] param($Identity, $TargetPath) }
