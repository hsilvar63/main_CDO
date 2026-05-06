public class Fitness {
  
    
    public static Decimal calculateBMI(Decimal weight, Decimal height){
        
        //System.debug('This is from apex calss'+bmi);
        if(height <=0 || weight <0){
            return -1;
        }else{
            Decimal bmi= weight / (height * height);
        	Decimal bmiRounded = bmi.setScale(2);
        	return bmiRounded;
        }
        
    }
     
    public static Decimal calculatePace(Decimal distanceInKm, Decimal timeInMinutes){
        if(distanceInKm< 0 || timeInMinutes <=0){
            return -1;
        }else{
             Decimal hr = timeInMinutes /60;
        
        	Decimal pace= distanceInKm / hr;
        	//System.debug('This is from apex calss'+bmi);
        	return pace;
        }
       
    }

}