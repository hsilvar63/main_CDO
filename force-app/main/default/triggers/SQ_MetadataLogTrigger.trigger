trigger SQ_MetadataLogTrigger on Flosum__Metadata_Log__c (after update) {
     if (Trigger.isAfter && Trigger.isUpdate) {
        
        SQ_Enable_Setting__mdt configRec = SQ_Enable_Setting__mdt.getInstance('Config');
         
        if(configRec !=null && configRec.Enable_Disable__c!=null && configRec.Enable_Disable__c)
        {
            SQ_MetadataLogHandler.handleAfterUpdate(Trigger.newMap, Trigger.oldMap);
        }
         
    }
}