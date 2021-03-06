Param(
    [string]$azureAccountName,
    [string]$azurePasswordString,
    [string]$subscriptionID,
    [int]$buildId,
    [string] [Parameter(Mandatory=$true)] $ArtifactStagingDirectory,
    [string] [Parameter(Mandatory=$true)] $ResourceGroupLocation,
    [string] $ResourceGroupName = $ArtifactStagingDirectory.replace('.\','')+ "-" +$buildId.ToString(), #remove .\ if present
    [switch] $UploadArtifacts,
    [string] $StorageAccountName,
    [string] $StorageContainerName = $ResourceGroupName.ToLowerInvariant(),
    [string] $TemplateFile = $ArtifactStagingDirectory + '\labs\labs-azuredeploy.json',
    [string] $TemplateParametersFile = $ArtifactStagingDirectory + '.\labs\labs-azuredeploy.parameters.json',
    [string] $DSCSourceFolder = $ArtifactStagingDirectory + '.\DSC',
    [switch] $ValidateOnly,
    [string] $DebugOptions = "None",
    [switch] $Dev
)

$azurePassword = ConvertTo-SecureString $azurePasswordString -AsPlainText -Force
$psCred = New-Object System.Management.Automation.PSCredential($azureAccountName, $azurePassword)
Login-AzureRmAccount -Credential $psCred
Set-AzureRmContext -SubscriptionID $subscriptionID

try {
    [Microsoft.Azure.Common.Authentication.AzureSession]::ClientFactory.AddUserAgent("VSAzureTools-$UI$($host.name)".replace(" ","_"), "AzureRMSamples")
} catch { }

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 3

function Format-ValidationOutput {
    param ($ValidationOutput, [int] $Depth = 0)
    Set-StrictMode -Off
    return @($ValidationOutput | Where-Object { $_ -ne $null } | ForEach-Object { @('  ' * $Depth + ': ' + $_.Message) + @(Format-ValidationOutput @($_.Details) ($Depth + 1)) })
}

$OptionalParameters = New-Object -TypeName Hashtable
$TemplateArgs = New-Object -TypeName Hashtable

if ($Dev) {
    $TemplateParametersFile = $TemplateParametersFile.Replace('azuredeploy.parameters.json', 'azuredeploy.parameters.dev.json')
    if (!(Test-Path $TemplateParametersFile)) {
        $TemplateParametersFile = $TemplateParametersFile.Replace('azuredeploy.parameters.dev.json', 'azuredeploy.parameters.1.json')
    }
}

if (!$ValidateOnly) {
    $OptionalParameters.Add('DeploymentDebugLogLevel', $DebugOptions)
}

$TemplateFile = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $TemplateFile))
$TemplateParametersFile = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $TemplateParametersFile))

if ($UploadArtifacts) {
    # Convert relative paths to absolute paths if needed
    $ArtifactStagingDirectory = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $ArtifactStagingDirectory))
    $DSCSourceFolder = [System.IO.Path]::GetFullPath([System.IO.Path]::Combine($PSScriptRoot, $DSCSourceFolder))
    # Parse the parameter file and update the values of artifacts location and artifacts location SAS token if they are present
    $JsonParameters = Get-Content $TemplateParametersFile -Raw | ConvertFrom-Json
    if (($JsonParameters | Get-Member -Type NoteProperty 'parameters') -ne $null) {
        $JsonParameters = $JsonParameters.parameters
    }
    #$ArtifactsLocationName = '_artifactsLocation'
    #$ArtifactsLocationSasTokenName = '_artifactsLocationSasToken'
    #$OptionalParameters[$ArtifactsLocationName] = $JsonParameters | Select-Object -Expand $ArtifactsLocationName -ErrorAction Ignore | Select-Object -Expand 'value' -ErrorAction Ignore
    #$OptionalParameters[$ArtifactsLocationSasTokenName] = $JsonParameters | Select-Object -Expand $ArtifactsLocationSasTokenName -ErrorAction Ignore | Select-Object -Expand 'value' -ErrorAction Ignore

    # Create DSC configuration archive
    if (Test-Path $DSCSourceFolder) {
        $DSCSourceFilePaths = @(Get-ChildItem $DSCSourceFolder -File -Filter '*.ps1' | ForEach-Object -Process {$_.FullName})
        foreach ($DSCSourceFilePath in $DSCSourceFilePaths) {
            $DSCArchiveFilePath = $DSCSourceFilePath.Substring(0, $DSCSourceFilePath.Length - 4) + '.zip'
            Publish-AzureRmVMDscConfiguration $DSCSourceFilePath -OutputArchivePath $DSCArchiveFilePath -Force -Verbose
        }
    }

    # Create a storage account name if none was provided
    if ($StorageAccountName -eq '') {
        $StorageAccountName = 'stage' + ((Get-AzureRmContext).Subscription.Id).Replace('-', '').substring(0, 19)
    }

    $StorageAccount = (Get-AzureRmStorageAccount | Where-Object{$_.StorageAccountName -eq $StorageAccountName})

    # Create the storage account if it doesn't already exist
    if ($StorageAccount -eq $null) {
        $StorageResourceGroupName = 'ARM_Deploy_Staging'
        New-AzureRmResourceGroup -Location "$ResourceGroupLocation" -Name $StorageResourceGroupName -Force
        $StorageAccount = New-AzureRmStorageAccount -StorageAccountName $StorageAccountName -Type 'Standard_LRS' -ResourceGroupName $StorageResourceGroupName -Location "$ResourceGroupLocation"
    }


 
    $ScriptsFolder=$ArtifactStagingDirectory+"\labs\scripts"
    if (Test-Path $ScriptsFolder) {
        # Copy files from the local storage staging location to the storage account container
        New-AzureStorageContainer -Name $StorageContainerName -Permission Container -Context $StorageAccount.Context -ErrorAction SilentlyContinue *>&1
        $ArtifactFilePaths = Get-ChildItem $ScriptsFolder -Recurse -File | ForEach-Object -Process {$_.FullName}
        foreach ($SourcePath in $ArtifactFilePaths) {
        Set-AzureStorageBlobContent -File $SourcePath -Blob $SourcePath.Substring($ArtifactStagingDirectory.length + 1) -Container $StorageContainerName -Context $StorageAccount.Context -Force
        }
    }

   
    $TemplateArgs.Add('TemplateFile', $TemplateFile)


}
else {

    $TemplateArgs.Add('TemplateFile', $TemplateFile)

}

$TemplateArgs.Add('TemplateParameterFile', $TemplateParametersFile)


# Create or update the resource group using the specified template file and template parameters file
New-AzureRmResourceGroup -Name $ResourceGroupName -Location $ResourceGroupLocation -Verbose -Force -ErrorAction Stop 

if ($ValidateOnly) {
    $ErrorMessages = Format-ValidationOutput (Test-AzureRmResourceGroupDeployment -ResourceGroupName $ResourceGroupName `
                                                                                  @TemplateArgs `
                                                                                  @OptionalParameters)
    if ($ErrorMessages) {
        Write-Output '', 'Validation returned the following errors:', @($ErrorMessages), '', 'Template is invalid.'
    }
    else {
        Write-Output '', 'Template is valid.'
    }
}
else {
    $result=New-AzureRmResourceGroupDeployment -Name ((Get-ChildItem $TemplateFile).BaseName + '-' + ((Get-Date).ToUniversalTime()).ToString('MMdd-HHmm')) `
                                       -ResourceGroupName $ResourceGroupName `
                                       @TemplateArgs `
                                       @OptionalParameters `
                                       -Force -Verbose `
                                       -ErrorVariable ErrorMessages
    #replace all output string
    $resultTemplateFilePath=$ArtifactStagingDirectory + '\labs\labs-result-template.json'
    $resultFilePath=$ArtifactStagingDirectory + '\labs\result.json'
    $outputs=$result.Outputs | ConvertTo-Json
    echo "outputs json"
    echo $outputs
    $outputsObj=$outputs | ConvertFrom-Json
    $result = Get-Content $resultTemplateFilePath | Out-String 
    ForEach ($i in $outputsObj.psobject.properties) 
    {
       
        $replacePara="#"+$i.Name;
        $replaceValue=$i.Value.Value;
        $result=$result.Replace("$replacePara", $replaceValue);
    
    }
    
    out-File -FilePath $resultFilePath -InputObject $result
    echo $result

    if ($ErrorMessages) {
        Write-Output '', 'Template deployment returned the following errors:', @(@($ErrorMessages) | ForEach-Object { $_.Exception.Message.TrimEnd("`r`n") })
    }
}