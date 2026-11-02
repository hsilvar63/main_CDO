/**
 * Company Class
 * Stores information about the company
 * and its customers
 * */
public class Company {
	public String companyName;
    public String ceo;
    public Integer employeeCount;
    public Long revenue;

    // List of all customers
    private List<Client> customers = new List<Client>();


    // add new customer
    public void addNewCustomer(String clientName, String website, String email, Long Phone) {
        Client customer = new Client(clientName, website, email, Phone);
        
        customers.add(customer);
  
    }

    // print the list of all customers
    public void getAllCustomers(){
        for(Client customer : customers){
            System.debug('Customer Name: '+ customer.clientName +', Website '+ customer.clientName+', Email '+ customer.email);
        }
      
    }

    // private inner class to store customer information
    private class Client{
        public String clientName;
        public String website;
        public String email;
        public Long phone;
        
        Client(String clientName, String website, String email, Long Phone){
            this.clientName = clientName;
            this.website 	= website;
            this.email 		= email;
            this.phone 		= phone;
        }
    }
  
}