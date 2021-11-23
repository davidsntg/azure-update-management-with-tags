<#
.PARAMETER SoftwareUpdateConfigurationRunContext
  This is a system variable which is automatically passed in by Update Management during a deployment.
#>

param(
    [string]$SoftwareUpdateConfigurationRunContext
)


#################
# CONFIGURATION #
#################

# Start stopped VM before patching ? Possible values: $true or $false. Value must be the same used in UM-PostTasks runbook by $stopStartedVmEnable variable
$startStopppedVmEnabled = $true

# Snapshot before patching ? Possible values: $true or $false.
$snapshotEnabled = $true

# Snapshot prefix to use. Must be the same used on UM-CleanUp-Snapshots.ps1 Runbook
$snapshotPrefix = "UpdateMngmnt_snapshot_"

# VM status that can be started
$startableStates = "stopped" , "stopping", "deallocated", "deallocating"

##########
# SCRIPT #
##########

Import-Module Az.Automation
Import-Module Az.Compute

# Connect to Azure with Automation Account system-assigned managed identity
Disable-AzContextAutosave -Scope Process
$AzureContext = (Connect-AzAccount -Identity -WarningAction Ignore).context
$AzureContext = Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext

# Get current automation account
$automationAccountsQuery = @{
    Query = "resources
| where type == 'microsoft.automation/automationaccounts'"
}
$automationAccounts = Search-AzGraph @automationAccountsQuery

foreach ($automationAccount in $automationAccounts)
{
    Select-AzSubscription -SubscriptionId $automationAccount.subscriptionId
    $Job = Get-AzAutomationJob -ResourceGroupName $automationAccount.resourceGroup -AutomationAccountName $automationAccount.name -Id $PSPrivateMetadata.JobId.Guid -ErrorAction SilentlyContinue
    if (!([string]::IsNullOrEmpty($Job)))
    {
        $automationAccountRg = $Job.ResourceGroupName
        $automationAccountName = $Job.AutomationAccountName
        break;
    }
}


# Get Azure VMs or Azure Arc Servers from $SoftwareUpdateConfigurationRunContext
$context = ConvertFrom-Json  $SoftwareUpdateConfigurationRunContext
$vmIds = $context.SoftwareUpdateConfigurationSettings.AzureVirtualMachines
$runId = "PrescriptContext" + $context.SoftwareUpdateConfigurationRunId

if (!$vmIds) 
{
    Write-Output "No Azure VMs found, checking Azure Arc Servers..."
    $vmIds = $context.SoftwareUpdateConfigurationSettings.NonAzureComputerNames
    if (!$vmIds){
        if (!$vmIds) 
        {
            Write-Output "No Azure Arc Servers found!"
            return
        }
    }
}

$vmIds | ForEach-Object {
    $vmId = $_

    $split = $vmId -split "/";

    if ($split.Length -eq 1)
    {
        # Azure Arc Server
        $vmType = "Arc"
    }
    else {
        # Azure VM
        $vmType = "Azure"
        $subscriptionId = $split[2]; 
        $rg = $split[4];
        $name = $split[8];

        $mute = Select-AzSubscription -Subscription $subscriptionId
        $vm = Get-AzVM -Name $name -resourceGroupName $rg -DefaultProfile $mute 
        
        $vmOS = $vm.StorageProfile.osDisk.osType
        
    }
 

    ####################
    # SNAPSHOT OS DISK #
    ####################

    if ($snapshotEnabled -and $vmType -eq "Azure")
    {
        Write-Output "$($vm.name) - OS Disk Snapshot Begin"
        $snapshotdisk = $vm.StorageProfile
        $OSDiskSnapshotConfig = New-AzSnapshotConfig -SourceUri $snapshotdisk.OsDisk.ManagedDisk.id -CreateOption Copy -Location $vm.Location -OsType $vmOS
        $snapshotNameOS = "$($snapshotPrefix)$($snapshotdisk.OsDisk.Name)_$(Get-Date -Format yyyyMMdd_HHmm)"

        try {
            New-AzSnapshot -ResourceGroupName $rg -SnapshotName $snapshotNameOS -Snapshot $OSDiskSnapshotConfig -ErrorAction Stop
        }
        catch {
            $_
        }
        Write-Output "$($vm.name) - OS Disk Snapshot End"
    }

    ############
    # VM START #
    ############

    if ($startStopppedVmEnabled -and $vmType -eq "Azure")
    {
        # Create Automation Account Variable - used to store the state of VMs
        New-AzAutomationVariable -ResourceGroupName $automationAccountRg -AutomationAccountName $automationAccountName -Name $runId -Value "" -Encrypted $false

        $updatedMachines = @()

        # Get VM state
        $vm = Get-AzVM -Name $name -resourceGroupName $rg -Status -DefaultProfile $mute 
        #Query the state of the VM to see if it's already running or if it's already started
        $state = ($vm.Statuses[1].DisplayStatus -split " ")[1]
        if($state -in $startableStates) {
            Write-Output "$($name) - Starting ..."
            $updatedMachines += $vmId
            Start-AzVM -Id $vmId -NoWait -DefaultProfile $mute 
        } else {
            Write-Output ($name + ": no action taken. State: " + $state) 
        }
    }
    
}

if ($startStopppedVmEnabled -and $null -ne $updatedMachines)
{
    $updatedMachinesCommaSeperated = $updatedMachines -join ","

    # Store output in the automation variable
    Set-AutomationVariable -Name $runId -Value $updatedMachinesCommaSeperated
}

Write-Output "Done"
