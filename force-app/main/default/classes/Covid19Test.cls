@isTest
public class Covid19Test {
    @isTest
    public static void treatPatientTest(){
        //create the instance of the class
        Covid19 jaipur = new Covid19(11);
        
        //check if the count is 10 or not
        Integer treated = jaipur.getTreated();
        System.assertEquals(10,treated,'Treated count does not Match');
        
        
        //create the instance of the class
        Covid19 hyd = new Covid19(112);
        
        //check if the count is 112 or not
        treated = hyd.getTreated();
        System.assertEquals(112,treated,'Treated count does not Match');
        
        //check the count of recoveredInCoyntry, it should be 122
        System.assertEquals(122,Covid19.recoveredInCountry,'Treated count does not Match');
        
        jaipur.treatPatient();
        treated = jaipur.getTreated();
        System.assert(treated == 11,'Treated count does not Match');
        System.assert(Covid19.recoveredInCountry == 123,'Treated count does not Match');

    }
      @isTest
    public static void treatPatientTestNegative(){
        //create the instance of the class
        Covid19 jaipur = new Covid19(-10);
        
        //check if the count is 0 or not
        Integer treated = jaipur.getTreated();
        System.assertEquals(0,treated,'Treated count does not Match');
        
        
        

    }

}