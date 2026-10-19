public class SQ_MetadataLogHandler {
    
    public static void handleAfterUpdate(Map<Id,Flosum__Metadata_Log__c> newMap, Map<Id, Flosum__Metadata_Log__c> oldMap) {
        List<Flosum__Metadata_Log__c> changedLogs = new List<Flosum__Metadata_Log__c>();
        Map<Id,Flosum__Metadata_Log__c> newAutomationLogMap = new Map<Id,Flosum__Metadata_Log__c>(); 
        Map<String,Flosum__Metadata_Log__c> newManualLogMap = new Map<String,Flosum__Metadata_Log__c>(); 
        
        Id branchId;
        for (Flosum__Metadata_Log__c logRec : [Select Id,Flosum__Deployment_Name__c,Flosum__Branch__c, Flosum__Job_Completed__c, Flosum__PipelineStepId__r.Flosum__Next_Step_Id_On_Pass__c,Flosum__Process_Type__c, Flosum__PipelineStepId__r.Flosum__Automation_Type__c, (SELECT Id, Name FROM Attachments where name='Flosum Scan Issues') FROM Flosum__Metadata_Log__c WHERE Flosum__Process_Type__c= 'Automation Step' AND Flosum__PipelineStepId__r.Flosum__Automation_Type__c='Flosum Scan' AND ID IN :newMap.keySet()]) {
            newAutomationLogMap.put(logRec.Id,logRec);
            branchId = logRec.Flosum__Branch__c;
        }
        
        for(Flosum__Metadata_Log__c logRec : [Select Id,Flosum__Status__c,Flosum__Deployment_Name__c,Flosum__Is_Error__c,Flosum__Process_Log__c,Flosum__Job_Completed__c, Flosum__PipelineStepId__c,Flosum__Process_Type__c, Flosum__PipelineStepId__r.Flosum__Automation_Type__c FROM Flosum__Metadata_Log__c WHERE Flosum__Process_Type__c= 'Pause' AND Flosum__Branch__c=:branchId]){
            newManualLogMap.put(logRec.Flosum__Deployment_Name__c,logRec); 
        }
        
        for (Flosum__Metadata_Log__c newLog : newAutomationLogMap.values()) {
            
            if(newAutomationLogMap.get(newLog.Id).Flosum__PipelineStepId__r.Flosum__Automation_Type__c =='Flosum Scan'){
                Flosum__Metadata_Log__c nextMetadataLogRec = new Flosum__Metadata_Log__c();
                Flosum__Metadata_Log__c oldLog = oldMap.get(newLog.Id);  
                Flosum__Metadata_Log__c newMapLog = newMap.get(newLog.Id);
                Boolean wasCompletedBefore = oldLog.Flosum__Job_Completed__c;
                Boolean isNowCompleted = newMapLog.Flosum__Job_Completed__c;
                if (oldLog.Flosum__Job_Completed__c != newMapLog.Flosum__Job_Completed__c && newMapLog.Flosum__Job_Completed__c) {
                    Integer stepNum = Integer.valueOf((newLog.Flosum__Deployment_Name__c).subString((newLog.Flosum__Deployment_Name__c).lastIndexOf('-')+1));
                    stepNum++;
                    String newLogName = (newLog.Flosum__Deployment_Name__c).subString(0,(newLog.Flosum__Deployment_Name__c).lastIndexOf('-'))+'-'+stepNum;
                    nextMetadataLogRec = newManualLogMap.get(newLogName);
                    if(newLog.attachments!=null && newLog.attachments[0].Id !=null)
                    {
                        SQ_QualityGate.calculateResult(newLog.attachments[0].Id,nextMetadataLogRec);
                    }
                    
                }
            }
        }
       
    }
    
}