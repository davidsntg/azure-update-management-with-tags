<#

.PARAMETER SoftwareUpdateConfigurationRunContext
  This is a system variable which is automatically passed in by Update Management during a deployment.

#>

param(
    [string]$SoftwareUpdateConfigurationRunContext,

    [Parameter(Mandatory = $true)]
    [string]$DestinationMail = "",

    [Parameter(Mandatory = $true)]
    [string]$ScheduleName = ""
)

#################
# CONFIGURATION #
#################

# Stop VM that were started after patching? Possible values: $true or $false. Value must be the same used in UM-PreTasks runbook by $startStopppedVmEnabled variable
$stopStartedVmEnable = $true

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
        $automationAccountSubscriptionId = $automationAccount.subscriptionId
        $automationAccountRg = $Job.ResourceGroupName
        $automationAccountName = $Job.AutomationAccountName
        break;
    }
}

$context = ConvertFrom-Json  $SoftwareUpdateConfigurationRunContext
$vmIds = $context.SoftwareUpdateConfigurationSettings.AzureVirtualMachines

$vmIds | ForEach-Object {
    $vmId = $_

    $split = $vmId -split "/";

    if ($split.Length -eq 1)
    {
        # Azure Arc Server
    }
    else {
        # Azure VM
        $subscriptionId = $split[2]; 
        $rg = $split[4];
        $name = $split[8];

        $mute = Select-AzSubscription -Subscription $subscriptionId

        #Hack to get VM log analytics ID
        $vmExtension = Get-AzVMExtension -ResourceGroupName $rg -VMName $name -DefaultProfile $mute
        $workspaceID = ($vmExtension | Select-String -InputObject {$_.PublicSettings} -Pattern "(\w{8}-\w{4}-\w{4}-\w{4}-\w{12})" -All).Matches.Value
    }
}

if ($DestinationMail -and $ScheduleName -and $DestinationMail -Match "^\w+([-+.']\w+)*@\w+([-.]\w+)*\.\w+([-.]\w+)*$")
{
    Write-Output "Create reporting mail"
    #Log Analytics Query Informations
    $query = 'UpdateRunProgress
    | where TimeGenerated > now(-4h)
    | where InstallationStatus <> ''NotStarted''
    | where UpdateRunName == ''' + $scheduleName + '''
    | project Computer, strcat(Product, KBID), InstallationStatus, ResourceId
    | project-rename Product=Column1
    | order by InstallationStatus asc, Computer asc'

    #Log Analytics Request
    $queryResults = Invoke-AzOperationalInsightsQuery -WorkspaceId $workspaceID -Query $query

    $rows = $queryResults.Results
    $rows  | ConvertTo-Json

    #Data Modeling for Mail Report
    if ($rows){
        $mailContent = "<html><head><style>table, th, td {border: 1px solid black; border-collapse: collapse; padding: 5px; text-align: left}</style></head><body>"
        $mailContent += "<table><tr><th>VM</th><th>Software</th><th>Status</th></tr>"

        foreach ($row in $rows){
            $mailContent += "<tr><td>" + $row.Computer + "</td><td>" + $row.Product + "</td><td>" + $row.InstallationStatus + "</td></tr>"    
        }

        $mailContent += "</table><br>---<br>Cloud Team</body></html>"

        #Get Automation Account variables
        $SendGridAPIKey =  Get-AutomationVariable -Name SendGridAPIKey
        $fromEmailAddress = Get-AutomationVariable -Name SendGridSender
        
        # Create the headers for the API call
        $headers = New-Object "System.Collections.Generic.Dictionary[[String],[String]]"
        $headers.Add("Authorization", "Bearer " + $SendGridAPIKey)
        $headers.Add("Content-Type", "application/json")
    
        # Parameters for sending the email
        $subject = "Update Management - Automatic patching report : " + $scheduleName

        $emailTo = @()
        $DestinationMail.Split(';') | ForEach-Object {
            $emailTo += @{email=$_}
        }

        # Create a JSON message with the parameters from above
        $body = @{
        personalizations = @(
            @{
                to = $emailTo          
            }
        )
        from = @{
            email = $fromEmailAddress
        }
        subject = $subject
        content = @(
            @{
                type = "text/html"
                value = $mailContent
            }
        )
        }
        
        # Convert the string into a real JSON-formatted string
        # Depth specifies how many levels of contained objects
        # are included in the JSON representation. The default
        # value is 2
        $bodyJson = $body | ConvertTo-Json -Depth 4
        
        # Call the SendGrid RESTful web service and pass the
        # headers and json message. More details about the 
        # webservice and the format of the JSON message go to
        # https://sendgrid.com/docs/api-reference/
        $response = Invoke-RestMethod -Uri https://api.sendgrid.com/v3/mail/send -Method Post -Headers $headers -Body $bodyJson
    }
}

if ($stopStartedVmEnable)
{
    # Get VMs from $SoftwareUpdateConfigurationRunContext
    $context = ConvertFrom-Json  $SoftwareUpdateConfigurationRunContext
    $runId = "PrescriptContext" + $context.SoftwareUpdateConfigurationRunId

    #Retrieve the automation variable, which we named using the runID from our run context. 
    #See: https://docs.microsoft.com/en-us/azure/automation/automation-variables#activities
    $variable = Get-AutomationVariable -Name $runId
    if (!$variable) 
    {
        Write-Output "No machines to turn off"
        return
    }

    $vmIds = $variable -split ","
    $stoppableStates = "starting", "running"

    $vmIds | ForEach-Object {
        $vmId =  $_
        
        $split = $vmId -split "/";
        $subscriptionId = $split[2]; 
        $rg = $split[4];
        $name = $split[8];

        $mute = Select-AzSubscription -Subscription $subscriptionId
        $vm = Get-AzVM -ResourceGroupName $rg -Name $name -Status -DefaultProfile $mute

        ###########
        # VM STOP #
        ###########

        # Get VM state
        $state = ($vm.Statuses[1].DisplayStatus -split " ")[1]
        if($state -in $stoppableStates) {
            Write-Output "$($name) - Stopping ..."
            Stop-AzVM -Id $vmId -Force  -DefaultProfile $mute 

        }else {
            Write-Output ($name + ": already stopped. State: " + $state) 
        }
    }

    # Clean up automation account variable:
    Select-AzSubscription -SubscriptionId $automationAccountSubscriptionId
    Remove-AzAutomationVariable -AutomationAccountName $automationAccountName -ResourceGroupName $automationAccountRg -name $runID
}

Write-Output "Done"

