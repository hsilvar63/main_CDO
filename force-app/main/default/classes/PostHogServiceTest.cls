@isTest
private class PostHogServiceTest {

    private class OkMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            res.setBody('{"results":[["Acme Corp",5]]}');
            return res;
        }
    }

    private class ErrorMock implements HttpCalloutMock {
        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(403);
            res.setBody('{"error":"Forbidden"}');
            return res;
        }
    }

    @isTest
    static void testQueryPostHog_success() {
        Test.setMock(HttpCalloutMock.class, new OkMock());

        Test.startTest();
        Map<String, Object> result = PostHogService.queryPostHog('259525', 'SELECT 1');
        Test.stopTest();

        Assert.isNotNull(result, 'Result map should not be null');
        Assert.isTrue(result.containsKey('results'), 'Response should contain results key');
        List<Object> rows = (List<Object>) result.get('results');
        Assert.isTrue(rows.size() == 1, 'Expected 1 row');
    }

    @isTest
    static void testQueryPostHog_nonOkStatus() {
        Test.setMock(HttpCalloutMock.class, new ErrorMock());

        Test.startTest();
        Boolean threw = false;
        try {
            PostHogService.queryPostHog('259525', 'SELECT 1');
        } catch (PostHogService.PostHogException e) {
            threw = true;
            Assert.isTrue(
                e.getMessage().contains('403'),
                'Exception message should contain status code, got: ' + e.getMessage()
            );
        }
        Test.stopTest();

        Assert.isTrue(threw, 'PostHogException should be thrown for non-200 status');
    }
}
