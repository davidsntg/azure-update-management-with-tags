#################
# CONFIGURATION #
#################

# Snapshot prefix to use. Must be the same used on UpdatementManagement-CleanUpSnapshots.ps1 Runbook
$snapshotPrefix = "UpdateMngmnt_snapshot_"

# Number of days to keep snapshot before deletion
$keepSnapshotDays = 8

##########
# SCRIPT #
##########

Import-Module Az.Automation

# Connect to Azure with Automation Account system-assigned managed identity
Disable-AzContextAutosave -Scope Process
$AzureContext = (Connect-AzAccount -Identity -WarningAction Ignore).context
$AzureContext = Set-AzContext -SubscriptionName $AzureContext.Subscription -DefaultProfile $AzureContext

# Get Snapshots
$snapshotsQuery = @{
    Query = "resources
    | where type == 'microsoft.compute/snapshots'
    | where name startswith '$($snapshotPrefix)'"
}
$snapshots = Search-AzGraph @snapshotsQuery

foreach ($snapshot in $snapshots)
{
    $snapDate = $snapshot.properties.timeCreated
    $currentDate = Get-Date
    $dateDiff = (New-TimeSpan -Start $snapDate -End $currentDate).Days

    if ($dateDiff -gt $keepSnapshotDays) 
    {
        # Delete Snapshot
        Select-AzSubscription -SubscriptionId $snapshot.subscriptionId
        Write-Output "$($snapshot.name) will be deleted."
        Remove-AzSnapshot -ResourceGroupName $snapshot.resourceGroup -SnapshotName $snapshot.name -Force
    }
    else {
        # Keep Snapshot
        Write-Output "$($snapshot.name) will not be deleted. Creation date is less or equal to $($keepSnapshotDays) days."
    }
}
