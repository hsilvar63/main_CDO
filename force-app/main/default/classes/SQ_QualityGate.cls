public class SQ_QualityGate {
    
    public class JsonData {
        // JSON structure
        public String type;
        public String severity;
        public String rule;
        public String issueType;
        public String message;
    }
    public static List<JsonData> readJsonFromFile(String attchmentID) {
        // Fetch the file as Blob from Attachment
        Attachment att = [
            SELECT Id, Name, Body
            FROM Attachment 
            WHERE Id = :attchmentID 
            LIMIT 1
        ];
        
        String jsonString = att.Body.toString();
        List<JsonData> dataList = (List<JsonData>) JSON.deserialize(jsonString, List<JsonData>.class);
        return dataList;
    }
    
    public static void calculateResult(String attachementId, Flosum__Metadata_Log__c nxtRec){
        
        Integer bugCount=0,vulnerabilityCount=0,codeSmellCount=0;
        List<SQ_QualityGate.JsonData> results = SQ_QualityGate.readJsonFromFile(attachementId);
        List<SQ_QualityGate.JsonData> revisedResultList = new List<SQ_QualityGate.JsonData>();
        
        List<SQ_Config__mdt> settings = [
            SELECT DeveloperName, Issue_Type__c, Message__c, Rule__c, Sevirity__c 
            FROM SQ_Config__mdt
        ];
        Map<String,SQ_Config__mdt> configMap = new Map<String,SQ_Config__mdt>();
        for(SQ_Config__mdt setRec : settings){
            configMap.put(setRec.Rule__c,setRec);
        }
        
        for (SQ_QualityGate.JsonData item : results) {
            
            SQ_Config__mdt cfRec = configMap.get(item.rule);
            if(cfRec !=null)
            {
                item.severity = cfRec.Sevirity__c;
            } 
            revisedResultList.add(item);
            
            
        }
        
        String orgSeverity ='';
        Map<String,Integer> sever = new Map<String,Integer>{'INFO'=>1 , 'MINOR'=>2 , 'MAJOR'=>3 , 'CRITICAL' =>4 , 'BLOCKER'=>5};
            //Threshold Config
            List<SQ_Threshold_Config__mdt> thresholdSetting = [
                SELECT DeveloperName, Frequency__c, Threshold_Type__c, Severity__c 
                FROM SQ_Threshold_Config__mdt
            ];
        Map<String,Integer> thresholdConfigMap = new Map<String,Integer>(); 
        for(SQ_Threshold_Config__mdt th : thresholdSetting){
            
            thresholdConfigMap.put(th.Threshold_Type__c ,sever.get(th.Severity__c));
        }
        
        Map<String,Integer> issueCount = new Map<String,Integer>();
        for (SQ_QualityGate.JsonData item : revisedResultList) {
            
            if(sever.get(item.severity) >= thresholdConfigMap.get(item.issueType))
            { 
                issueCount.put(item.issueType,(issueCount.containsKey(item.issueType) ? issueCount.get(item.issueType)+1 : 1));
            }
            
        }
        Boolean flag = false;
        List<Flosum__Metadata_Log__c>  updateMetadataList = new List<Flosum__Metadata_Log__c>();
        for(SQ_Threshold_Config__mdt th : thresholdSetting){
            if(issueCount.get(th.Threshold_Type__c)>th.Frequency__c){
                flag = true;
                break;
            }
        }
        
        if(flag && nxtRec.Flosum__Process_Type__c=='Pause'){
            nxtRec.Flosum__Status__c = 'Completed';
            nxtRec.Flosum__Job_Completed__c = true;
            nxtRec.Flosum__Is_Error__c = true;
            nxtRec.Flosum__Succeed__c = false;
            system.debug('FAILD');
        }else
        {
            nxtRec.Flosum__Status__c = 'Completed';
            nxtRec.Flosum__Job_Completed__c = true;
            nxtRec.Flosum__Is_Error__c = false;
            nxtRec.Flosum__Succeed__c = true;
            system.debug('PASS');
        }
        updateMetadataList.add(nxtRec);
        
        if(!updateMetadataList.isEmpty()){
            update updateMetadataList;
        }
        
    }
}