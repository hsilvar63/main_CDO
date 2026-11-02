trigger DeployApprovalTrigger on Flosum__Deployment_Approval__c (before insert) {
ValidateRepoBeforeDeploy validateRepo = new ValidateRepoBeforeDeploy();
        validateRepo.executeBeforeInser(Trigger.new);
}