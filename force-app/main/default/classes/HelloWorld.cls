public class HelloWorld {
    private String greeting = 'Hello World';
    //public variable
   // public String publicgreeting = 'My public greeting var';
    //private String gMorning = 'Good Morning';
    //private String gAfternoon = 'Good Afternoon';
    //private String gEvening = 'Good Evening';
    /*
    public void printGreeting() {
        System.debug(greeting);
    }
    public void printGoodMorning() {
        System.debug(gMorning);
    }
    public void printGoodAfternoon() {
        System.debug(gAfternoon);
    }
    public void pringGoodEvening() {
        System.debug(gEvening);
    }
    //get an error about access modifiers
    public void printPublicGreeting() {
        System.debug(publicgreeting);
    }*/
    public void printeMessage(String msg){
        System.debug(msg);
    }
	//returns a day based on dayNumber
    public String getDay(String dayAbrev){
        String dayString='';
        switch on dayAbrev {
            when 'Sun' {
                dayString = 'Sunday';
            }
            when 'Mon' {
                dayString = 'Monday';
            }
            when 'Tue' {
                dayString = 'Tuesday';
            }
            when 'Wed' {
                dayString = 'Wend';
            }
            when 'Th' {
                dayString = 'thur';
            }
            when 'Fri' {
                dayString = 'Friday';
            }
            when 'St' {
                dayString = 'Sat';
            }
            when else {
                dayString = 'not a valid day';
            }
        }
        //System.debug(msg);
return dayString;
    }
    
}