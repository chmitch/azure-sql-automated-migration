# Notes
# ------------------------------------------------------------------------------------------ 
# This script connects to a local instance, enumerates the databases and migrates them
# to Azure.  This script automates the process of extracting a bacpac, uploading the
# bacpac to azure blob storage, and restoring the bacpac to an Azure SQL database.
#
# This script presently makes a few assumptions that are easy to addres.
# 1.  The databases you want to migrate are on the local instance.
# 2.  You want to migrate all the databases on the instance.
# 3.  You want to migrage all the databases to the same azure resoure group.
# ------------------------------------------------------------------------------------------ 

#local variables
$sourceServer = "localhost"
$tempLocation = "c:\Projects"

#Define the path to the sqlpackage.exe
$cmd = "C:\Program Files (x86)\Microsoft SQL Server\130\DAC\bin\sqlpackage.exe"

#azure variables 
$resourceGroupName = "[resource group]"
$storageAccount = "[storage account]"
$storageContainer = "[storage container]"
$StorageKey = "[storage key]"

#base path for SqlPS databases.
$root = "SQLSERVER:\SQL\$sourceServer\DEFAULT\Databases"
Set-Location $root

$subscriptionId = "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
Set-AzureRmContext -SubscriptionId $subscriptionId

#Enumerate the databases on the server
foreach ($Item in Get-ChildItem)
{
    #Retreive the size of the database so we know how to size the SQL Azure DB.
    $dbName = $Item.Name
    Set-Location "$root\$name"
    $dbSize = $Item.Size
    Write-Host $dbName
    
    #Call function to extract the database
    ExtractBacpac -server $sourceServer -database $dbName -size $dbSize -account $storageAccount -key $storageKey -container $storageContainer
    
    #define the URI needed for the restore step
    $uri = "http://$storageAccount.blob.core.windows.net/$storageContainer/$dbName.bacpac"

    #call function to restore the database
    MigrateDatabase -storageUri $uri -key $storageKey -resourceGroup $resourceGroupName -database $dbName -size $dbSize   
}

function ExtractBacpac
{
    param([string]$server, [string]$database, [int]$size, [string]$account, [string]$key, [string]$container)

    Set-Location c:
    $fileName = "$database.bacpac"
    $localPath = "$tempLocation\$fileName"
    
    $params = "/Action:Export /ssn:" + $server + " /sdn:" + $database + " /tf:" + $localPath
    $p = $params.Split(" ")

    #shell out the export command for the bacpac
    & "$cmd" $p

    
    #Set storage context and upload blob file
    $context = New-AzureStorageContext -StorageAccountName $account -StorageAccountKey $key
    Set-AzureStorageBlobContent -File $localpath -Container $container -Context $context

}



function MigrateDatabase
{
    param([string]$storageUri, [string]$key, [string]$resourceGroup, [string]$database, [int]$size)
    Write-Host $size
    
    $serverName = "[destination server]"
     
    $credential = Get-Credential
    
    #set the service objective baseline based on the size of the database
    If ($size -gt 250)
    {
        $edition = "Premium"
        $objective = "p1"
    }
    else
    {
        $edition = "Standard"
        $objective = "s0"
    }

    $importRequest = New-AzureRmSqlDatabaseImport   –ResourceGroupName $resourceGroup `
                                                    –ServerName $serverName `
                                                    –DatabaseName $database `
                                                    –StorageKeyType "StorageAccessKey" `
                                                    –StorageKey $key `
                                                    -StorageUri $storageUri `
                                                    –AdministratorLogin $credential.UserName `
                                                    –AdministratorLoginPassword $credential.Password `
                                                    –Edition $edition `
                                                    –ServiceObjectiveName $objective `
                                                    -DatabaseMaxSizeBytes $size

    Get-AzureRmSqlDatabaseImportExportStatus -OperationStatusLink $importRequest.OperationStatusLink

    # The DatabaseImport command is async so check status of the export every 10 seconds
    do
    {
        $status = Get-AzureRmSqlDatabaseImportExportStatus -OperationStatusLink $importRequest.OperationStatusLink
        Write-Host $status.StatusMessage
        Start-Sleep -s 10
    } while($status.Status -eq "InProgress")
}