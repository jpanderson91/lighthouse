<#
.SYNOPSIS
  Deploys a User Managed Identity (UMI) for Sentinel ingestion.
.DESCRIPTION
  This script deploys a User Managed Identity (UMI) for Sentinel ingestion. It creates a resource group,
  registers the required Azure Resource Providers, installs the required PowerShell modules, and assigns
  permissions to the UMI. It also creates a service principal and assigns the required permissions for
  the UMI to manage the service principal.
.PARAMETER CustomerPrefix
  The customer prefix name. This is used to create the resource group name.
.PARAMETER Subscription
  The subscription ID where the UMI will be deployed.
.PARAMETER AzRegion
  The Azure region where the UMI will be deployed. Default is 'eastus'.
.PARAMETER SkipModuleInstall
  Skip module installation (useful in Azure Cloud Shell where modules may already be available).

#>
[CmdletBinding()]
param (
  [Parameter(Mandatory = $false)]
  [string] $CustomerPrefix,

  [Parameter(Mandatory = $false)]
  [string] $Subscription,

  [Parameter(Mandatory = $false)]
  [string] $AzRegion = 'eastus',

  [Parameter(Mandatory = $false)]
  [switch] $SkipModuleInstall
)

$maxRetries = 10

# Check if running in Azure Cloud Shell
$isCloudShell = $env:ACC_CLOUD -eq 'PROD' -or $env:AZUREPS_HOST_ENVIRONMENT -eq 'cloud-shell'

# Install the required PowerShell modules (skip in Cloud Shell if requested)
if (-not $SkipModuleInstall -and -not $isCloudShell) {
  Write-Information 'Installing required PowerShell modules...' -InformationAction Continue
  Install-Module Az.Resources -Scope CurrentUser -SkipPublisherCheck -Force -AllowClobber -AcceptLicense
  Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -SkipPublisherCheck -Force -AllowClobber -AcceptLicense
  Install-Module Microsoft.Graph.Applications -Scope CurrentUser -SkipPublisherCheck -Force -AllowClobber -AcceptLicense
  Install-Module Microsoft.Graph.Identity.DirectoryManagement -Scope CurrentUser -SkipPublisherCheck -Force -AllowClobber -AcceptLicense
}
elseif ($isCloudShell) {
  Write-Information 'Running in Azure Cloud Shell - using pre-installed modules' -InformationAction Continue
}
else {
  Write-Information 'Skipping module installation as requested' -InformationAction Continue
}

# Add required Azure Resource Providers
Register-AzResourceProvider -ProviderNamespace Microsoft.Insights
Register-AzResourceProvider -ProviderNamespace Microsoft.ManagedServices
Register-AzResourceProvider -ProviderNamespace Microsoft.ManagedIdentity

# Get user input if not provided as parameters
if (-not $CustomerPrefix) {
  do {
    $CustomerPrefix = Read-Host 'Enter customer prefix name'
  } while ($CustomerPrefix.Length -lt 3)
}

if (-not $Subscription) {
  do {
    $Subscription = Read-Host 'Enter the subscription id'
  } while ($Subscription.Length -lt 36)
}

$umiName = 'MSSP-Sentinel-Ingestion-UMI'
$rg = "$($CustomerPrefix.ToUpper())-Sentinel-Prod-rg"

# Authentication check - in Cloud Shell, user is already authenticated
if ($isCloudShell) {
  Write-Information 'Running in Azure Cloud Shell - using existing authentication' -InformationAction Continue
}
else {
  Write-Information 'If running locally, ensure you are authenticated with Connect-AzAccount' -InformationAction Continue
  Connect-AzAccount  # Uncomment if needed for local execution
}

Set-AzContext -SubscriptionId $Subscription

# Get the context of the current subscription
$subscriptionId = (Get-AzContext).Subscription.Id
$scope = "/subscriptions/$($subscriptionId)"

# Azure RBAC role IDs needed
$azureOwnerRoleId = '8e3af657-a8ff-443c-a75c-2fe8c4bcb635' # This is Owner.
$azureKVAdminRoleId = '00482a5a-887f-4fb3-b363-3b7fe8e74483' # This is Key Vault Administrator.
$azureKVUserRoleId = '4633458b-17de-408a-b874-0445c86b69e6' # This is Key Vault Secrets User.
$metricsPubRoleId = '3913510d-42f4-4e42-8a64-420c390055eb' # This is Monitoring Metrics Publisher.

# Create resource group if needed.
if ([string]::IsNullOrEmpty((Get-AzResourceGroup -Name $rg -ErrorAction SilentlyContinue))) {
  Write-Information "Creating resource group: $rg" -InformationAction Continue
  New-AzResourceGroup -Name $rg -Location $AzRegion
}
else {
  Write-Information "Resource group $rg already exists" -InformationAction Continue
}

# Check if User Managed Identity already exists
Write-Information 'Checking if User Managed Identity already exists...' -InformationAction Continue
$existingUmi = Get-AzUserAssignedIdentity -Name $umiName -ResourceGroupName $rg -ErrorAction SilentlyContinue

if ($existingUmi) {
  Write-Information "User Managed Identity '$umiName' already exists - skipping creation" -InformationAction Continue
}
else {
  Write-Information "Creating User Managed Identity '$umiName'..." -InformationAction Continue
  $null = New-AzUserAssignedIdentity -Name $umiName -ResourceGroupName $rg -Location $AzRegion
}

# Connect to Microsoft Graph early for all directory operations
Write-Information 'Connecting to Microsoft Graph...' -InformationAction Continue
Connect-MgGraph -Scopes 'Application.ReadWrite.All', 'Directory.Read.All', 'AppRoleAssignment.ReadWrite.All' -NoWelcome

# Wait for the UMI to be created and available
Write-Information 'Waiting for User Managed Identity to be created...' -InformationAction Continue

$retryCount = 0
$umi = $null

do {
  Start-Sleep 10
  $retryCount++
  Write-Information "Attempt $retryCount of $maxRetries - Checking if UMI is available." -InformationAction Continue

  try {
    # Use Graph to lookup the UMI service principal for consistency
    $umi = Get-MgServicePrincipal -Filter "DisplayName eq '$umiName'" -ErrorAction SilentlyContinue
    if ($umi) {
      Write-Information 'User Managed Identity found and ready!' -InformationAction Continue
      break
    }
  }
  catch {
    Write-Warning "Error checking UMI: $($_.Exception.Message)"
  }

  if ($retryCount -ge $maxRetries) {
    throw "Timeout waiting for User Managed Identity '$umiName' to be created after $($maxRetries * 10) seconds"
  }
} while (-not $umi)

# Assign User Assigned Identity Owner permissions to the subscription
Write-Information 'Assigning RBAC roles to the UMI...' -InformationAction Continue
New-AzRoleAssignment -RoleDefinitionId $azureOwnerRoleId -ObjectId $umi.Id -Scope $scope -ErrorAction SilentlyContinue

# Assign monitoring metrics permissions to the UMI
New-AzRoleAssignment -RoleDefinitionId $metricsPubRoleId -ObjectId $umi.Id -Scope $scope -ErrorAction SilentlyContinue

# The UMI needs to be able to manage Key Vaults, so we assign it the Key Vault Administrator role
New-AzRoleAssignment -RoleDefinitionId $azureKVAdminRoleId -ObjectId $umi.Id -Scope $scope -ErrorAction SilentlyContinue

# Assign Key Vault Secrets User permissions to the UMI
# The UMI needs to be able to read secrets from Key Vaults, so we assign it the Key Vault Secrets User role.
# This role allows the UMI to read secrets from Key Vaults, which is necessary for its operation.
New-AzRoleAssignment -RoleDefinitionId $azureKVUserRoleId -ObjectId $umi.Id -Scope $scope -ErrorAction SilentlyContinue

# Wait for the role assignments to propagate
Write-Information 'Waiting for role assignments to propagate...' -InformationAction Continue
Start-Sleep 30

# Create the service principal/app registration using Graph
$appName = 'MSSP-Sentinel-Ingestion'

# Check if application registration already exists
Write-Information 'Checking if application registration already exists...' -InformationAction Continue
$existingApplication = Get-MgApplication -Filter "DisplayName eq '$appName'" -ErrorAction SilentlyContinue

if ($existingApplication) {
  Write-Information "Application registration '$appName' already exists - using existing" -InformationAction Continue
  $application = $existingApplication

  # Check if service principal exists for this application
  $existingServicePrincipal = Get-MgServicePrincipal -Filter "AppId eq '$($application.AppId)'" -ErrorAction SilentlyContinue

  if ($existingServicePrincipal) {
    Write-Information "Service Principal for '$appName' already exists - using existing" -InformationAction Continue
    $adsp = $existingServicePrincipal
  }
  else {
    Write-Information "Creating Service Principal for existing application '$appName'..." -InformationAction Continue
    $spParams = @{
      AppId       = $application.AppId
      DisplayName = $appName
    }
    $null = New-MgServicePrincipal @spParams

    # Wait for service principal to be available
    $retryCount = 0
    $adsp = $null
    do {
      Start-Sleep 10
      $retryCount++
      Write-Information "Attempt $retryCount of $maxRetries - Checking if Service Principal is available..." `
        -InformationAction Continue
      try {
        $adsp = Get-MgServicePrincipal -Filter "AppId eq '$($application.AppId)'" -ErrorAction SilentlyContinue
        if ($adsp) {
          Write-Information 'Service Principal found and ready!' -InformationAction Continue
          break
        }
      }
      catch {
        Write-Warning "Error checking Service Principal: $($_.Exception.Message)"
      }
      if ($retryCount -ge $maxRetries) {
        throw "Timeout waiting for Service Principal '$appName' to be created after $($maxRetries * 10) seconds"
      }
    } while (-not $adsp)
  }
}
else {
  Write-Information "Creating new application registration '$appName'..." -InformationAction Continue

  # Create the application with retry logic
  $appParams = @{
    DisplayName    = $appName
    SignInAudience = 'AzureADMyOrg'
  }

  Write-Information 'Attempting to create application registration...' -InformationAction Continue
  $retryCount = 0
  $application = $null

  do {
    $retryCount++
    Write-Information "Attempt $retryCount of $maxRetries - Creating application..." -InformationAction Continue

    try {
      $application = New-MgApplication @appParams

      # Verify the application was created successfully
      if ($application -and $application.Id) {
        Write-Information "Application '$appName' created successfully with ID: $($application.Id)" -InformationAction Continue
        break
      }
      else {
        Write-Warning "Application creation returned null or missing ID on attempt $retryCount"
      }
    }
    catch {
      Write-Warning "Error creating application on attempt ${retryCount}: $($_.Exception.Message)"
    }

    if ($retryCount -ge $maxRetries) {
      throw "Failed to create application registration '$appName' after $maxRetries attempts"
    }

    Start-Sleep 5
  } while (-not $application -or -not $application.Id)

  # Create the service principal from the application
  Write-Information "Creating Service Principal for new application '$appName'..." -InformationAction Continue
  $spParams = @{
    AppId       = $application.AppId
    DisplayName = $appName
  }

  $null = New-MgServicePrincipal @spParams

  # Wait for the service principal to be created and available
  Write-Information 'Waiting for Service Principal to be created...' -InformationAction Continue
  $retryCount = 0
  $adsp = $null

  do {
    Start-Sleep 10
    $retryCount++
    Write-Information "Attempt $retryCount of $maxRetries - Checking if Service Principal is available..." `
      -InformationAction Continue

    try {
      # Use Graph to lookup the service principal for consistency
      $adsp = Get-MgServicePrincipal -Filter "AppId eq '$($application.AppId)'" -ErrorAction SilentlyContinue
      if ($adsp) {
        Write-Information 'Service Principal found and ready!' -InformationAction Continue
        break
      }
    }
    catch {
      Write-Warning "Error checking Service Principal: $($_.Exception.Message)"
    }

    if ($retryCount -ge $maxRetries) {
      throw "Timeout waiting for Service Principal '$appName' to be created after $($maxRetries * 10) seconds"
    }
  } while (-not $adsp)
}

# Create a client secret with 1-day expiration (always create new secret for security)
Write-Information 'Creating new application secret with 1-day expiration...' -InformationAction Continue
$secretParams = @{
  PasswordCredential = @{
    DisplayName = 'Auto-generated secret (1 day expiry)'
    EndDateTime = (Get-Date).AddDays(1)
  }
}

$appSecret = Add-MgApplicationPassword -ApplicationId $application.Id -BodyParameter $secretParams
Write-Information "Application secret created with 1-day expiration: $($appSecret.SecretText)" -InformationAction Continue

# The UMI needs to be granted permissions to the Microsoft Graph API
# to allow it to view and manage its owned resources in the tenant.

# Get the Service Principal for Microsoft Graph
$graphSP = Get-MgServicePrincipal -Filter "AppId eq '00000003-0000-0000-c000-000000000000'"

# Graph API permissions to assign to the UMI
# This allows the UMI to manage its service principal
$addPermissions = @(
  'Application.ReadWrite.OwnedBy',
  'Application.Read.All'
)

$appRoles = $graphSP.AppRoles |
  Where-Object { ($_.Value -in $addPermissions) -and ($_.AllowedMemberTypes -contains 'Application') }

$appRoles | ForEach-Object {
  New-MgServicePrincipalAppRoleAssignment -ResourceId $graphSP.Id -PrincipalId $umi.Id -AppRoleId $_.Id -ServicePrincipalId $umi.Id
}

# Make sure the UMI is set as the owner of the application. This is required to allow
# the UMI to manage the app registration.
$newOwner = @{
  '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($umi.Id)"
}

# This adds the UMI as an owner to application (using the application object, not service principal)
New-MgApplicationOwnerByRef -ApplicationId $application.Id -BodyParameter $newOwner

# Script completion summary
Write-Information '=== DEPLOYMENT COMPLETED SUCCESSFULLY ===' -InformationAction Continue
Write-Information "Resource Group: $rg" -InformationAction Continue
Write-Information "User Managed Identity: $umiName" -InformationAction Continue
Write-Information "Application Registration: $appName" -InformationAction Continue
Write-Information "Application ID: $($application.AppId)" -InformationAction Continue
Write-Information "Service Principal Object ID: $($adsp.Id)" -InformationAction Continue
Write-Information "UMI Object ID: $($umi.Id)" -InformationAction Continue
Write-Information '' -InformationAction Continue
Write-Information 'IMPORTANT: Application secret expires in 24 hours!' -InformationAction Continue
Write-Information "Secret Value: $($appSecret.SecretText)" -InformationAction Continue
