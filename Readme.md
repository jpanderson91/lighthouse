Links to deploy custom template for lighthouse authorizations:

1. Complete Azure Lighthouse authorizations using this ARM template.

  <a href="https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fjpanderson91%2Flighthouse%2Frefs%2Fheads%2Fmain%2Flighthouseauthorizations.json/createUIDefinitionUri/https%3A%2F%2Fraw.githubusercontent.com%2Fjpanderson91%2Flighthouse%2Frefs%2Fheads%2Fmain%2Flighthouseauthorizationsui.json" target="_blank"><img src="https://aka.ms/deploytoazurebutton"/>

2. Download and run UMI creation PowerShell script in Azure Cloud Shell

  - Download [UMI Deployment script](New-UmiDeployment.ps1) (Right-click and click *Save link as*).
  - In the Azure Portal, open Cloud Shell.
    - Select PowerShell as the shell type.
    - Select **No storage account required.**

  ![Cloud Shell](./images/cloudshell.png)

  - Upload the file to the Cloud Shell using the **Manage Files > Upload** button in the Cloud Shell toolbar.

  ![Upload PowerShell Script to Azure Cloud Shell](./images/upload-script-cloudshell.png)

  - Run the script with the command `./New-UmiDeployment.ps1`.
  - Follow the prompts to complete the deployment.
  - You may need to grant your account access to use the Microsoft Graph API.

3. (DEPRECATED) Deploy custom template for Service Principals deployment

  <a href="https://portal.azure.com/#create/Microsoft.Template/uri/https%3A%2F%2Fraw.githubusercontent.com%2Fjpanderson91%2Flighthouse%2Frefs%2Fheads%2Fmain%2Fspdeployment.json" target="_blank"><img src="https://aka.ms/deploytoazurebutton"/>

