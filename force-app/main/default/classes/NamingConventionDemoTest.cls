@isTest
private class NamingConventionDemoTest {

    /**
     * Test method to verify the default instantiation and execution of the DemoFunction.
     * This test ensures the class can be instantiated and its public method can be called without throwing an exception.
     */
    @isTest
    static void testDemoFunction_Positive() {
        // Create an instance of the class to test.
        NamingConventionDemo demoInstance = new NamingConventionDemo();

        Test.startTest(); // Marks the beginning of the actual test execution.
        // Call the public method. The test passes if no exception is thrown.
        demoInstance.DemoFunction();
        Test.stopTest(); // Marks the end of the test execution.

        // Since the method has no return value or visible side effects, we primarily assert that we reached this point.
        System.assert(true, 'The DemoFunction method should execute without throwing an exception.');
    }

    /**
     * Test method to verify the class can be instantiated multiple times.
     * This is a basic test to ensure the constructor works correctly.
     */
    @isTest
    static void testClassInstantiation() {
        Test.startTest();
        NamingConventionDemo demoInstance1 = new NamingConventionDemo();
        NamingConventionDemo demoInstance2 = new NamingConventionDemo();
        Test.stopTest();

        // Assert that the instances are not null, confirming successful instantiation.
        System.assertNotEquals(null, demoInstance1, 'The first class instance should not be null.');
        System.assertNotEquals(null, demoInstance2, 'The second class instance should not be null.');
        // Assert that the two instances are different objects in memory.
        System.assertNotEquals(demoInstance1, demoInstance2, 'The two class instances should be separate objects.');
    }
}