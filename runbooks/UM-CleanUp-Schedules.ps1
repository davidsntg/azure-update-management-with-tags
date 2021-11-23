#################
# CONFIGURATION #
#################

# Deployment Schedule name Prefix. Must be the same used on Updatemanagement-CleanUpSchedules Runbook.
$schedulePrefix = "ScheduledByTags-"

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

# Get Update Deployment Schedules
$updateSchedules = Get-AzAutomationSoftwareUpdateConfiguration -ResourceGroupName $automationAccountRg -AutomationAccountName $automationAccountName | Where-Object { $_.Name -like "$($schedulePrefix)*"  }

foreach ($updateSchedule in $updateSchedules)
{
    $schedule = Get-AzAutomationSoftwareUpdateConfiguration -ResourceGroupName $automationAccountRg -AutomationAccountName $automationAccountName -Name $updateSchedule.Name
    $vmScheduledId = $schedule.UpdateConfiguration.AzureVirtualMachines[0]
    $vmScheduledName = $vmScheduledId.Split("/")[8]

    # Quick naming check
    if ($schedule.Name.Replace($schedulePrefix,"") -ne $vmScheduledName) {
        Write-Output "Error ! Schedule Name & VM Name in schedule mismatch, continue..."
        continue
    }

    $vmScheduledTags = Get-AzTag -ResourceId $vmScheduledId
    $vmScheduledTags = $vmScheduledTags.PropertiesTable 
    $deleteSchedule = $false

    if ($null -eq $vmScheduledTags)
    {
        $deleteSchedule = $true
    }
    else {
        if (! $vmScheduledTags.Contains("POLICY_UPDATE")) {
            $deleteSchedule = $true
        }
    }

    # Delete Schedule
    if ($deleteSchedule)
    {
        Write-Output "Removing $($updateSchedule.Name) ..."
        Remove-AzAutomationSoftwareUpdateConfiguration -ResourceGroupName $automationAccountRg -AutomationAccountName $automationAccountName -Name $updateSchedule.Name
    }
    else {
        Write-Output "Nothing to do!"
    }
}
