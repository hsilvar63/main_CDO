public class ValidateRepoBeforeDeploy {
public void executeBeforeInser(List<Flosum__Deployment_Approval__c> newRecList){
        List<Id> branchIdList = new List<Id>();
        //get branch Id from deployment approval record
        for(Flosum__Deployment_Approval__c aprrovalRec : newRecList){
            branchIdList.add(aprrovalRec.Flosum__Branch__c);
        }
        Map<Id,Flosum__Commit__c> commitMap = new Map<Id,Flosum__Commit__c>([Select Id,Flosum__Branch__c from Flosum__Commit__c where Flosum__Branch__c IN : branchIdList]);
        for(Flosum__Deployment_Approval__c aprroval : newRecList)
        {
            if((aprroval.Flosum__Org__c==Label.ProdOrgId1 || aprroval.Flosum__Org__c==Label.ProdOrgId2) && commitMap.size()==0){
               aprroval.addError('Before deploying this branch to Production environment you need to Commit this branch to the Repository.');
            }
        }
    }
}