###############
# DESCRIPTION #
###############

# This script searchs VMs with key tag "POLICY_UPDATE"
# If a VM has a "POLICY_UPDATE" key tag, an update deployment will be created on the current automation account.
# The VM will be patched weekly based on its "POLICY_UPDATE" tag value

# Syntax of "POLICY_UPDATE" key tag:
# DaysOfWeek;startTime;rebootPolicy;excludedPackages;reportingMail

# Example #1 - POLICY_UPDATE: Sunday;05h20 PM;Always;*java*,*nagios*;
# Example #2 - POLICY_UPDATE: Friday;07h00 PM;IfRequired;;TeamA@abc.com

# rebootPolicy possible values: Always, Never, IfRequired
# excludedPackages: optional parameter, comma separated if multiple.
# reportingMail: optional parameter

# Prerequisites: 
#  1) Automation Account must have a system-managed identity
#  2) System-managed identity must be Contributor on VM's subscriptions scopes
#  3) Virtual Machines must be connected to Log Analytics Workspace linked to the Automation Account. 

#################
# CONFIGURATION #
#################

# Pre-Task Runbook to execute before the patching. The runbook must exists in the automation account.
$PreTaskRunbookName = "UM-PreTasks"

# Post-Task Runbook to execute after the patching. The runbook must exists in the automation account.
$PostTaskRunbookName = "UM-PostTasks"

# Onboard Azure Arc Servers ? Possible values: $true or $false.
$onboardAzureArcServersEnabled = $true

# Maintenance window (minutes) to perform patching. Minimum: 30 minutes. Maximum: 6 hours 
$duration = New-TimeSpan -Hours 2

# TimeZone - Can be the IANA ID or the Windows Time Zone ID
$timezone = "Romance Standard Time" # France - Central European Time

# Deployment Schedule name Prefix. Must be the same used on Updatemanagement-CleanUpSchedules Runbook.
$schedulePrefix = "ScheduledByTags-"

# Valid days of week - used to check tags values.
$validDaysOfWeek = @("Monday","Tuesday","Wednesday","Thursday","Friday","Saturday","Sunday")

# Valid reboot settings - used to check tags values.
$validRebootSettings = @("Always","Never","IfRequired")

##########
# SCRIPT #
##########

Import-Module Az.ResourceGraph

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
        $automationAccountSubscriptionId = $automationAccount.subscriptionId
        $automationAccountRg = $Job.ResourceGroupName
        $automationAccountName = $Job.AutomationAccountName
        break;
    }
}

# Search all Azure VMs with key tags "POLICY_UPDATE"
$azureVmsQueryParams = @{
    Query = "resources
| where type == 'microsoft.compute/virtualmachines'
| where isnotnull(tags['POLICY_UPDATE'])
| project id, name, policy_update=tags['POLICY_UPDATE'], osType=properties.storageProfile.osDisk.osType, vmType='Azure'"
}

$azureVmsWithBackupPolicy = Search-AzGraph @azureVmsQueryParams

# Search all Azure Arc Servers with key tags "POLICY_UPDATE"
if ($onboardAzureArcServersEnabled)
{
    $azureArcServersQueryParam = @{
        Query = "resources
        | where type == 'microsoft.hybridcompute/machines'
        | where isnotnull(tags['POLICY_UPDATE'])
        | project id, name, policy_update=tags['POLICY_UPDATE'], osType=properties.osType, vmType='Arc'"
    }

    $azureArcServersBackupPolicy = Search-AzGraph @azureArcServersQueryParam
}
else {
    $azureArcServersBackupPolicy = $null
}

# Concatain $azureVmsQueryParams & $azureArcServersQueryParam
$vmsWithBackupPolicy = $azureVmsWithBackupPolicy + $azureArcServersBackupPolicy

foreach ($vm in $vmsWithBackupPolicy) {
    Write-Output "=========="
    Write-Output "VM Name: $($vm.name)"
    Write-Output "VM Policy: $($vm.policy_update)"

    # Check inputs
    if ($vm.policy_update.Split(";").Length -ne 4 -And $vm.policy_update.Split(";").Length -ne 5)
    {
        Write-Error "/!\ Error! Wrong number of parameters given. POLICY_UPDATE syntax is: DaysOfWeek;startTime;rebootPolicy;excludedPackages;reportingMail"
        continue
    }  
    $DaysOfWeek = $vm.policy_update.Split(";")[0].Split(',')
    foreach($day in $DaysOfWeek)
    {
        if (!$validDaysOfWeek.contains($day))
        {
            Write-Error "/!\ Error! DaysOfWeek is not valid. It should be Monday, Tuesday, Wednesday, Thursday, Friday, Saturday or Sunday. Current value for VM $($vm.name): $($DaysOfWeek)"
            continue
        }
    }
    
    $startTime = $vm.policy_update.Split(";")[1]
    try {
        $startTime = (Get-Date $startTime).AddDays(1)
    }
    catch {
        Write-Error "/!\ Error! startTime is not valid. It should be 'hh:mm AM' or 'hh:mm PM' formatted. Current value for VM: $($startTime)"
        continue
    }

    $rebootPolicy =  $vm.policy_update.Split(";")[2]
    if (!$validRebootSettings.contains($rebootPolicy))
    {
        Write-Error "/!\ Error! rebootSetting is not valid. It should be Always, Never or IfRequired. Current value for VM $($vm.name): $($rebootPolicy)"
        continue
    }

    $excludedPackages = $vm.policy_update.Split(";")[3]
    if ($excludedPackages) 
    {
        $excludedPackages = $excludedPackages.Split(",")
    }
    else
    {
        $excludedPackages = $null   
    }

    $reportingMail = $vm.policy_update.Split(";")[4]
    $reportingMailHash = $null
    if ($reportingMail)
    {
        if ($reportingMail -NotMatch "^\w+([-+.']\w+)*@\w+([-.]\w+)*\.\w+([-.]\w+)*$")
        {
            Write-Error "/!\ Error! reportingMail is not valid. It should a valid email address. Current value for VM $($vm.name): $($reportingMail)"
            continue
        }
        $reportingMailHash = @{"DestinationMail" = $reportingMail ; "ScheduleName" = "$($schedulePrefix)$($vm.name)" }
    }
    
    if (!$PreTaskRunbookName) { $PreTaskRunbookName = $null }
    if (!$PostTaskRunbookName) { $PostTaskRunbookName = $null }

    # Checking osType
    if ($vm.osType -ne "Windows" -and $vm.osType -ne "Linux")
    {
        Write-Error "/!\ Error! VM osType not supported. Supported OS are: Linux or Windows. Current value for VM $($vm.name): $($vm.osType)"
        continue
    }

    # Check is a schedule for the VM already exists
    $schedules = Get-AzAutomationSchedule -ResourceGroupName $automationAccountRg -AutomationAccountName $automationAccountName | Where-Object {($_.Name -like "$($schedulePrefix)$($vm.name)*")}
    $schedule = $null
    $createOrUpdateSchedule = $false

    # If a schedule for the VM already exists, check that Days&Hour defined in tags = Days&Hours defined in schedule. Update Schedule otherwise.
    if ($schedules.Length -eq 1 -And !([string]::IsNullOrEmpty($schedules.Name)))
    {
        # Get schedule details
        $schedule = Get-AzAutomationSchedule -ResourceGroupName $automationAccountRg -AutomationAccountName $automationAccountName -Name $schedules.Name

        # Check if Days between those defined in existing schedule are equal to those defined in vm tags
        $automationScheduleDaysOfWeek = $schedule.WeeklyScheduleOptions.DaysOfWeek | Sort-Object
        $automationScheduleDaysOfWeek = $automationScheduleDaysOfWeek -join ", "

        $DaysOfWeekSorted = $DaysOfWeek | Sort-Object
        $DaysOfWeekSorted = $DaysOfWeekSorted -join ', ' 

        if ($automationScheduleDaysOfWeek -ne $DaysOfWeekSorted)
        {
            Write-Output "Days between those defined in existing schedule and days defined tags are different. Existing schedule will be updated."
            $createOrUpdateSchedule = $true
        }

        # Check if hour:minute between those defined in existing schedule are equal to those defined in vm tags
        $automationScheduleNextRunDateTime = $schedule.NextRun.DateTime
        $diff = New-TimeSpan -Start (Get-Date $startTime) -End $automationScheduleNextRunDateTime

        if ($diff.Hours -ne 0 -Or $diff.Minutes -ne 0)
        {
            Write-Output "hour:minute between those defined in existing schedule are equal to those defined in vm tags. Existing schedule will be updated."
            $createOrUpdateSchedule = $true
        }
    }
    else
    {
        # New VM detected : a schedule must be created
        $createOrUpdateSchedule = $true 
    }

    
    if ($createOrUpdateSchedule)
    {
        $schedule = New-AzAutomationSchedule -ResourceGroupName $automationAccountRg `
        -AutomationAccountName $automationAccountName `
        -Name "$($schedulePrefix)$($vm.name)" `
        -StartTime $startTime `
        -TimeZone $timezone `
        -DaysOfWeek $DaysOfWeek `
        -WeekInterval 1 `
        -ForUpdateConfiguration
    } else {
        $schedule.Name = "$($schedulePrefix)$($vm.name)"
    }
    # Azure VM
    if ($vm.vmType -eq "Azure")
    {
        if ($vm.osType -eq "Windows") 
        {
            New-AzAutomationSoftwareUpdateConfiguration -ResourceGroupName $automationAccountRg `
                -AutomationAccountName $automationAccountName `
                -Schedule $schedule `
                -Windows `
                -AzureVMResourceId $vm.id `
                -IncludedUpdateClassification Unclassified,Critical,Security,UpdateRollup,FeaturePack,ServicePack,Definition,Tools,Updates `
                -ExcludedKbNumber $excludedPackages `
                -RebootSetting $rebootPolicy `
                -Duration $duration `
                -PreTaskRunbookName $PreTaskRunbookName `
                -PostTaskRunbookName $PostTaskRunbookName `
                -PostTaskRunbookParameter $reportingMailHash
        }
        elseif ($vm.osType -eq "Linux") 
        {
            New-AzAutomationSoftwareUpdateConfiguration -ResourceGroupName $automationAccountRg `
                -AutomationAccountName $automationAccountName `
                -Schedule $schedule `
                -Linux `
                -AzureVMResourceId $vm.id `
                -IncludedPackageClassification Critical, Security, Other, Unclassified `
                -ExcludedPackageNameMask $excludedPackages `
                -RebootSetting $rebootPolicy `
                -Duration $duration `
                -PreTaskRunbookName $PreTaskRunbookName `
                -PostTaskRunbookName $PostTaskRunbookName `
                -PostTaskRunbookParameter $reportingMailHash
        }
    }
    # Azure Arc Server 
    elseif ($vm.vmType -eq "Arc") {
        if ($vm.osType -eq "Windows") 
        {
            New-AzAutomationSoftwareUpdateConfiguration -ResourceGroupName $automationAccountRg `
                -AutomationAccountName $automationAccountName `
                -Schedule $schedule `
                -Windows `
                -NonAzureComputer  $vm.name `
                -IncludedUpdateClassification Unclassified,Critical,Security,UpdateRollup,FeaturePack,ServicePack,Definition,Tools,Updates `
                -ExcludedKbNumber $excludedPackages `
                -RebootSetting $rebootPolicy `
                -Duration $duration `
                -PreTaskRunbookName $PreTaskRunbookName `
                -PostTaskRunbookName $PostTaskRunbookName `
                -PostTaskRunbookParameter $reportingMailHash
        }
        elseif ($vm.osType -eq "Linux") 
        {
            New-AzAutomationSoftwareUpdateConfiguration -ResourceGroupName $automationAccountRg `
                -AutomationAccountName $automationAccountName `
                -Schedule $schedule `
                -Linux `
                -NonAzureComputer  $vm.name `
                -IncludedPackageClassification Critical, Security, Other, Unclassified `
                -ExcludedPackageNameMask $excludedPackages `
                -RebootSetting $rebootPolicy `
                -Duration $duration `
                -PreTaskRunbookName $PreTaskRunbookName `
                -PostTaskRunbookName $PostTaskRunbookName `
                -PostTaskRunbookParameter $reportingMailHash
        }
    }
    else {
        Write-Error "VM Type Unknown!"
        continue
    }
}

Write-Output "Done"
