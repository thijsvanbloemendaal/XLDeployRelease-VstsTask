param() 
Trace-VstsEnteringInvocation $MyInvocation
try 
{ 
	Import-VstsLocStrings "$PSScriptRoot\Task.json" 

	$action = Get-VstsInput -Name action -Require
    $connectedServiceName = Get-VstsInput -Name connectedServiceName -Require
    $endpoint = Get-VstsEndpoint -Name $connectedServiceName -Require
    $buildDefinition = Get-VstsInput -Name buildDefinition
    $applicationLocation = Get-VstsInput -Name applicationLocation -Require
    $targetEnvironment = Get-VstsInput -Name targetEnvironment -Require
    $rollback = Get-VstsInput -Name rollback -AsBool
    $applicationVersion = Get-VstsInput -Name applicationVersion

	Import-Module $PSScriptRoot\ps_modules\XLD_module\xld-deploy.psm1
	Import-Module $PSScriptRoot\ps_modules\XLD_module\xld-verify.psm1
    $ErrorActionPreference = "Stop"
	
	if($action -eq "Deploy application created from build")
	{
        #Check if TFS 2017 is installed
        if((Get-VstsTaskVariable -Name "Release.AttemptNumber"))
        {
		    $buildNumber = Get-VstsTaskVariable -Name "RELEASE.ARTIFACTS.$buildDefinition.BUILDNUMBER"
        }
        else
        {
            Write-Warning "The field BuildDefinition is ignored, not supported on TFS 2015"
            $buildNumber = Get-VstsTaskVariable -Name "Build.BuildNumber"
        }
	}
	else
	{
		$buildNumber = $applicationVersion
	}

	if(!$buildNumber)
	{

	    if($action -eq "Deploy application created from build")
	    {
		    throw "Version for $($buildDefinition) couldn't be determined."
	    }
	    else
	    {
		    throw "Application version seems to be empty."
	    }
	}

	$authScheme = $endpoint.Auth.scheme
	if ($authScheme -ne 'UserNamePassword')
	{
		throw "The authorization scheme $authScheme is not supported by XL Deploy server."
	}

	# Create PSCredential object
	$credential = New-PSCredential $endpoint.Auth.parameters.username $endpoint.Auth.parameters.password
	$serverUrl = Test-EndpointBaseUrl $endpoint.Url

	# Add URL and credentials to default parameters so that we don't need
	# to specify them over and over for this session.
	$PSDefaultParameterValues.Add("*:EndpointUrl", $serverUrl)
	$PSDefaultParameterValues.Add("*:Credential", $credential)


	# Check server state and validate the address
	Write-Output "Checking XL Deploy server state..."
	if ((Get-ServerState) -ne "RUNNING")
	{
		throw "XL Deploy server not in running state."
	}
	Write-Output "XL Deploy server is running."


	if (-not (Test-EnvironmentExists $targetEnvironment)) 
	{
		throw "Specified environment $targetEnvironment doesn't exists."
	}

    $deploymentPackageId = [System.IO.Path]::Combine($applicationLocation, $buildNumber).Replace("\", "/")

	if(-not $deploymentPackageId.StartsWith("Applications/", "InvariantCultureIgnoreCase"))
	{
		$deploymentPackageId = "Applications/$deploymentPackageId"
	}

	if(-not (Test-Package $deploymentPackageId))
	{
		throw "Specified application $deploymentPackageId doesn't exists."
	}

	# create new deployment task
	
	$deploymentTaskId = New-DeploymentTask $deploymentPackageId $targetEnvironment
    Write-Output "Start deployment $($deploymentPackageId) to $($targetEnvironment)."
	Start-Task $deploymentTaskId

	$taskOutcome = Get-TaskOutcome $deploymentTaskId

	#Implemented retry mechanism because sometimes the deployment is failing in combination with the IIS deployment plugin of XL Deploy
	#Maximum number of retries: 3
    <# retry mechanism does not seem to work. commented out until feature is needed.
	$retryCounter = 1
	while(($taskOutcome -eq "FAILED" -or $taskOutcome -eq "STOPPED" -or $taskOutcome -eq "CANCELLED") -and $retryCounter -lt 5)
	{
		Write-Output "Deployment failed. Number of times retried: $retryCounter"
		Start-Task $deploymentTaskId
		$taskOutcome = Get-TaskOutcome $deploymentTaskId
		$retryCounter++
	}
	#>

	if ($taskOutcome -eq "EXECUTED" -or $taskOutcome -eq "DONE")
	{
		# archive
		Complete-Task $deploymentTaskId
		Write-Output "Successfully deployed to $targetEnvironment."
	}
	else
	{
		Write-Warning (Get-FailedTaskMessage -taskId $deploymentTaskId | Out-String)
		
		if (!$rollback) 
		{
			throw "Deployment failed."
		}

		Write-Output "Starting rollback."

		# rollback
		$rollbackTaskId = New-RollbackTask $deploymentTaskId

		Start-Task $rollbackTaskId

		$rollbackTaskOutcome = Get-TaskOutcome $rollbackTaskId

		if ($rollbackTaskOutcome -eq "EXECUTED" -or $rollbackTaskOutcome -eq "DONE")
		{
			# archive
			Complete-Task $rollbackTaskId
			Write-Output "Rollback executed successfully."
		}
		else
		{
			Write-Warning (Get-FailedTaskMessage -taskId $rollbackTaskId | Out-String)
			throw "Rollback failed." 
		}

        Write-Output ("##vso[task.complete result=SucceededWithIssues;]Deployment failed.")
	}
}
finally
{
	Trace-VstsLeavingInvocation $MyInvocation
}