[CmdletBinding()]
Param (
    #Script parameters go here
    [Parameter(mandatory = $true)]
    [string]$HostPoolName ,

    [Parameter(mandatory = $true)]
    [string]$ResourceGroupName ,
    
    [Parameter(mandatory = $true)]
    [int]$LimitSecondsToForceLogOffUser ,

    [Parameter(mandatory = $true)]
    [string]$LogOffMessageTitle ,

    [Parameter(mandatory = $true)]
    [string]$LogOffMessageBody 
)

$ErrorActionPreference = 'Continue'

$connection = Get-AutomationConnection -Name 'AzureRunAsConnection'
    Clear-AzContext -Force
    $AZAuthentication = Connect-AzAccount -ApplicationId $Connection.ApplicationId -TenantId $Connection.TenantId -CertificateThumbprint $Connection.CertificateThumbprint -ServicePrincipal
        if ($AZAuthentication -eq $null) {
            Write-Output "Failed to authenticate Azure: $($_.exception.message)"
            #Write-Host "Failed to authenticate Azure: $($_.exception.message)"
            exit
        } else {
            $AzObj = $AZAuthentication | Out-String
            Write-Output "Authenticating as service principal for Azure. Result: `n$AzObj"
            #Write-Host "Authenticating as service principal for Azure. Result: `n$AzObj"
        }
    $context = Get-AzContext

$rebooted = 0
$shutdown = 0
$stoppableStates = "starting", "running"
$jobIDs= New-Object System.Collections.Generic.List[System.Object]


$sessionHosts = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName
write-Output "Session hosts : $($sessionHosts | Format-List -Force | Out-String)"
foreach ($sh in $sessionHosts) {
    

    # Name is in the format 'host-pool-name/vmname.domainfqdn' so need to split the last part
    $SessionHostName = $sh.Name.Split("/")[1]
    $VMName = $SessionHostName.Split(".")[0]
    
    $Session = $sh.Session
    $Status = $sh.Status
    $UpdateState = $sh.UpdateState
    $UpdateErrorMessage = $sh.UpdateErrorMessage

    Write-output "VM: $VMName"
    Write-output "Session: $Session"
    Write-output "Status: $Status"
    Write-output "UpdateState: $UpdateState"
    Write-output "UpdateErrorMessage: $UpdateErrorMessage"
    
    if ($Status -ne "Unavailable") {
        
        Update-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -Name $SessionHostName -AllowNewSession:$false
      
        if ($Session -gt 0) {
            Write-output "!! The VM '$VMName' has $Session session(s), so sending a notification. !!"       
            $usersessions = Get-AzWvdUserSession -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -SessionHostName $SessionHostName
            write-Output "user sessions : $($usersessions | Format-List -Force | Out-String)"
            foreach ($us in $usersessions) {
                if ($us.SessionState -ne 'Active') {
                    continue
                }
                $SessionID = $usersessions.Name.Split('/')[-1]
                Send-AzWvdUserSessionMessage -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -SessionHostName $SessionHostName -UserSessionId $SessionID -MessageTitle $LogOffMessageTitle -MessageBody "$LogOffMessageBody You will be logged off in $LimitSecondsToForceLogOffUser seconds"
                #Start-Sleep -Seconds $LimitSecondsToForceLogOffUser
            }
            Start-Sleep -Seconds $LimitSecondsToForceLogOffUser
            foreach ($us in $usersessions) {
                if ($us.SessionState -ne 'Active') {
                    continue
                }
                $SessionID = $usersessions.Name.Split('/')[-1]
                Remove-AzWvdUserSession -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -SessionHostName $SessionHostName -Id $SessionID -Force
                
            }
           <#check for active sessions again.
            $sh1 = Get-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -Name $SessionHostName
            if($sh1.Session -gt 0) {
                Write-Output "More sessions found"
                $usersessions = Get-AzWvdUserSession -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -SessionHostName $SessionHostName
                write-Output "user sessions : $($usersessions | Format-List -Force | Out-String)"
                foreach ($us in $usersessions) {
                    if ($us.SessionState -ne 'Active') {
                        continue
                    }
                    $SessionID = $usersessions.Name.Split('/')[-1]
                    Send-AzWvdUserSessionMessage -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -SessionHostName $SessionHostName -UserSessionId $SessionID -MessageTitle $LogOffMessageTitle -MessageBody "$LogOffMessageBody You will be logged off in $LimitSecondsToForceLogOffUser seconds"
                    #Start-Sleep -Seconds $LimitSecondsToForceLogOffUser
                }
                Start-Sleep -Seconds $LimitSecondsToForceLogOffUser
                foreach ($us in $usersessions) {
                    if ($us.SessionState -ne 'Active') {
                        continue
                    }
                    $SessionID = $usersessions.Name.Split('/')[-1]
                    Remove-AzWvdUserSession -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -SessionHostName $SessionHostName -Id $SessionID -Force
                    Start-Sleep -Seconds 30
                }
            }#>
            
            $newJob = Start-ThreadJob -ScriptBlock { param($resource, $vmname) Restart-AzVM -ResourceGroupName $resource -Name $vmname } -ArgumentList $ResourceGroupName,$VMName 
            $jobIDs.Add($newJob.Id)
            $rebooted += 1
            Write-output "=== Reboot initiated for VM after logging all sessions off: $VMName"       
            
        }
        else {
            
            write-Output "no sessions found on: $VMName"
            
            $newJob = Start-ThreadJob -ScriptBlock { param($resource, $vmname) Restart-AzVM -ResourceGroupName $resource -Name $vmname } -ArgumentList $ResourceGroupName,$VMName 
            $jobIDs.Add($newJob.Id)
            $rebooted += 1
            Write-output "=== Reboot initiated for VM: $VMName"       
        }
        

        Update-AzWvdSessionHost -ResourceGroupName $ResourceGroupName -HostPoolName $HostPoolName -Name $SessionHostName -AllowNewSession:$true
    }
    else {
        $vm = Get-AzVM -ResourceGroupName $ResourceGroupName -Name $vmname -Status
              
        $state = ($vm.Statuses[1].DisplayStatus -split " ")[1]
        Write-Output "VM is unavailable is AVD but it is in '$state' state"
        if($state -in $stoppableStates) {
            $newJob = Start-ThreadJob -ScriptBlock { param($resource, $vmname) Restart-AzVM -ResourceGroupName $resource -Name $vmname } -ArgumentList $ResourceGroupName,$VMName 
            $jobIDs.Add($newJob.Id)
            $rebooted += 1
        }
        else {
            $shutdown += 1
            Write-output "!! The VM '$VMName' must be started in order to reboot it. !!"       
        }
        
    }


}

    $jobsList = $jobIDs.ToArray()
    if ($jobsList)
    {
        Write-Output "Waiting for machines to finish restarting..."
        Wait-Job -Id $jobsList
    }

    foreach($id in $jobsList)
    {
        $job = Get-Job -Id $id
        if ($job.Error)
        {
            Write-Output $job.Error
        }
    }


Write-Output ""
Write-Output "============== Completed =========================="
Write-Output "Host not started: $shutdown"
Write-Output "Rebooted: $rebooted"
Write-Output "==================================================="
