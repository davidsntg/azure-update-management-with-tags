param VmName string
param VmLocation string
param VmSize string
param VmOsType string 
param VmOsPublisher string 
param VmOsOffer string 
param VmOsSku string 
param VmOsVersion string 
param VmNicSubnetId string
param WorkspaceId string
param WorkspaceKey string

var VmOsDiskName = '${VmName}od01'
var VmNicName = '${VmName}ni01'

param tags_policy_update string
param adminUsername string
param adminPassword string

resource Nic 'Microsoft.Network/networkInterfaces@2020-08-01' = {
  name: VmNicName
  location: VmLocation
  properties: {
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Dynamic'
          subnet: {
            id: VmNicSubnetId
          }
          primary: true
        }
      }
    ]
    dnsSettings: {
      dnsServers: []
    }
    enableAcceleratedNetworking: false
    enableIPForwarding: false
  }
}

resource VirtualMachine 'Microsoft.Compute/virtualMachines@2019-07-01' = {
  name: VmName
  location: VmLocation
  tags: {
    POLICY_UPDATE: tags_policy_update
  }
  properties: {
    hardwareProfile: {
      vmSize: VmSize
    }
    storageProfile: {
      osDisk: {
        name: VmOsDiskName
        createOption: 'FromImage'
        osType: VmOsType
      }
      imageReference: {
        publisher: VmOsPublisher
        offer: VmOsOffer
        sku: VmOsSku
        version: VmOsVersion
      }
    }
    osProfile: {
      computerName: VmName
      adminUsername: adminUsername
      adminPassword: adminPassword
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: Nic.id
        }
      ]
    }
  }
}

output VirtualMachineId string = VirtualMachine.id

resource VmLinuxLaw 'Microsoft.Compute/virtualMachines/extensions@2021-04-01' = if (VmOsType == 'Linux') {
  name: '${VmName}/OmsAgentForLinux'
  location: VmLocation
  properties:{
    publisher: 'Microsoft.EnterpriseCloud.Monitoring'
    type: 'OmsAgentForLinux'
    typeHandlerVersion: '1.13'
    autoUpgradeMinorVersion: true
    settings:{
      workspaceId: WorkspaceId
    }
    protectedSettings:{
      workspaceKey: WorkspaceKey 
    }
  }
  dependsOn:[
    VirtualMachine
    Nic
  ]
}


resource VmWindowsLaw 'Microsoft.Compute/virtualMachines/extensions@2021-04-01' = if (VmOsType == 'Windows') {
  name: '${VmName}/MicrosoftMonitoringAgent'
  location: VmLocation
  properties:{
    publisher: 'Microsoft.EnterpriseCloud.Monitoring'
    type: 'MicrosoftMonitoringAgent'
    typeHandlerVersion: '1.0'
    autoUpgradeMinorVersion: true
    settings:{
      workspaceId: WorkspaceId
    }
    protectedSettings:{
      workspaceKey: WorkspaceKey
    }
  }
  dependsOn:[
    VirtualMachine
    Nic
  ]
}
