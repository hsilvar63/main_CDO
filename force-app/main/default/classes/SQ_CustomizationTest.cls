@isTest
public class SQ_CustomizationTest {


    @testSetup
    static void setupData() {
        // Load CMDT records (make sure you have test data CSVs in your org)
        // Example CSVs must match SQ_Config__mdt and SQ_Threshold_Config__mdt fields.
        // Alternatively, if not possible in your org, just skip these lines and rely on existing CMDT.
        // Test.loadData(SQ_Config__mdt.sObjectType, 'SQ_Config_TestData');
         //Test.loadData(SQ_Enable_Setting__mdt.sObjectType, 'Config');
    }

    @isTest
    static void testHandlerAndQualityGate() {
        
         // Step 2: Create pipeline step record
         
        Flosum__PipelineStep__c stepRec  = new Flosum__PipelineStep__c(
            Flosum__Step__c = 'Automation Step',
            Flosum__Automation_Type__c = 'Flosum Scan'
            
        );
        insert stepRec;
        
        // Step 2: Create Automation log
        Flosum__Metadata_Log__c autoLog = new Flosum__Metadata_Log__c(
            
            Flosum__Deployment_Name__c = 'Pipeline-1',
            Flosum__Process_Type__c = 'Automation Step',
            Flosum__PipelineStepId__c = stepRec.Id,
            Flosum__Job_Completed__c = false
        );
        insert autoLog;

        // Step 3: Create Pause log (next step)
        Flosum__Metadata_Log__c pauseLog = new Flosum__Metadata_Log__c(
           
            Flosum__Deployment_Name__c = 'Pipeline-2',
            Flosum__Process_Type__c = 'Pause',
            Flosum__Job_Completed__c = false
        );
        insert pauseLog;

        // Step 4: Create Attachment with JSON body
        String jsonBody = '[{"type":"BUG","severity":"MAJOR","rule":"Rule-1","issueType":"BUG","message":"Test issue"}]';
        Attachment att = new Attachment(
            Name = 'Flosum Scan Issues',
            ParentId = autoLog.Id,
            Body = Blob.valueOf(jsonBody)
        );
        insert att;

        // Step 5: Simulate update (Job_Completed = false -> true)
        autoLog.Flosum__Job_Completed__c = true;

        Test.startTest();
        update autoLog;
        Test.stopTest();

        // Step 6: Validate Pause log is updated by SQ_QualityGate
        Flosum__Metadata_Log__c updatedPause = [
            SELECT Id, Flosum__Status__c, Flosum__Job_Completed__c, Flosum__Is_Error__c, Flosum__Succeed__c
            FROM Flosum__Metadata_Log__c
            WHERE Id = :pauseLog.Id
        ];

        System.assertEquals('Completed', updatedPause.Flosum__Status__c, 'Pause log should be marked completed');
        System.assertEquals(true, updatedPause.Flosum__Job_Completed__c, 'Pause log should be marked completed');
        System.assertNotEquals(null, updatedPause.Flosum__Succeed__c, 'Pause log should have pass/fail set');
    }

}