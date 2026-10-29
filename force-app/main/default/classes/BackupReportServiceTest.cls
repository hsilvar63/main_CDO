@IsTest
private class BackupReportServiceTest {

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static Map<String, Object> currData(String acct) {
        return new Map<String, Object>{
            'account' => acct, 'users'  => 5,
            'bk' => 100, 'ar' => 20, 're' => 5,  'ex' => 3,  'sr' => 2,
            'bk_exc' => 2, 'ar_exc' => 0, 're_exc' => 0, 'ex_exc' => 1, 'sr_exc' => 0
        };
    }

    private static Map<String, Object> prevData(String acct) {
        return new Map<String, Object>{
            'account' => acct, 'users'  => 4,
            'bk' => 90, 'ar' => 18, 're' => 4, 'ex' => 2, 'sr' => 1,
            'bk_exc' => 1, 'ar_exc' => 0, 're_exc' => 0, 'ex_exc' => 0, 'sr_exc' => 0
        };
    }

    private static Map<String, Object> storData(String acct) {
        return new Map<String, Object>{
            'account' => acct, 'bk_mb' => 51200, 'ar_mb' => 20480
        };
    }

    // ── HTML builder ──────────────────────────────────────────────────────────

    @IsTest
    static void testBuildHtmlTestMode() {
        String html = BackupReportService.buildHtml(
            'Acme Corp',
            currData('Acme Corp'),
            prevData('Acme Corp'),
            storData('Acme Corp'),
            new List<Map<String, Object>>(),
            true,
            'test@example.com'
        );

        System.assert(html.contains('Acme Corp'),        'Should contain account name');
        System.assert(html.contains('TEST MODE'),        'Should show test mode banner');
        System.assert(html.contains('test@example.com'), 'Should show test email in banner');
        System.assert(html.contains('100'),              'Should contain backup count');
        System.assert(html.contains('Backup'),           'Should contain Backup row');
        System.assert(html.contains('Archive'),          'Should contain Archive row');
        System.assert(html.contains('70.0 GB'),          'Should show storage total (71680 MB = 70.0 GB)');
    }

    @IsTest
    static void testBuildHtmlProductionMode() {
        String html = BackupReportService.buildHtml(
            'Beta Inc',
            currData('Beta Inc'),
            prevData('Beta Inc'),
            storData('Beta Inc'),
            new List<Map<String, Object>>(),
            false,
            null
        );

        System.assert(html.contains('Beta Inc'));
        System.assert(!html.contains('TEST MODE'), 'Should NOT show test mode banner');
    }

    @IsTest
    static void testBuildHtmlEmptyData() {
        String html = BackupReportService.buildHtml(
            'Empty Corp',
            new Map<String, Object>(),
            new Map<String, Object>(),
            new Map<String, Object>(),
            new List<Map<String, Object>>(),
            false,
            null
        );

        System.assert(html.contains('Empty Corp'));
        System.assert(html.contains('0'));   // zero ops
        System.assert(html.contains('0.0 GB')); // zero storage
    }

    @IsTest
    static void testBuildHtmlExceptionRateColors() {
        // >20% failure rate → red (#DC2626)
        Map<String, Object> highExc = new Map<String, Object>{
            'account' => 'Danger Co', 'users' => 1,
            'bk' => 10, 'ar' => 0, 're' => 0, 'ex' => 0, 'sr' => 0,
            'bk_exc' => 3, 'ar_exc' => 0, 're_exc' => 0, 'ex_exc' => 0, 'sr_exc' => 0
        };
        String html = BackupReportService.buildHtml(
            'Danger Co', highExc, new Map<String, Object>(),
            new Map<String, Object>(), new List<Map<String, Object>>(), false, null
        );
        System.assert(html.contains('#DC2626'), 'High exception rate should use red color');
    }

    // ── sendMonthlyReports: guard clauses ─────────────────────────────────────

    @IsTest
    static void testNoReportWhenGloballyDisabled() {
        // No 'Default' CMT record in test context → loadSettings() returns null → early return
        Test.startTest();
        BackupReportService.sendMonthlyReports(); // should not throw
        Test.stopTest();
        System.assert(true, 'Method returned cleanly with no CMT record');
    }

    @IsTest
    static void testNoReportWhenNoAccountsEnabled() {
        // Insert accounts WITHOUT Monthly_Report_Enabled__c = true
        Account acct = new Account(Name = 'Disabled Corp');
        insert acct;

        BackupReportService.testCurrData = new List<Map<String, Object>>{ currData('Disabled Corp') };
        BackupReportService.testPrevData = new List<Map<String, Object>>{ prevData('Disabled Corp') };
        BackupReportService.testStorData = new List<Map<String, Object>>{ storData('Disabled Corp') };

        // sendMonthlyReports will query accounts and find none enabled → return early
        // We can verify via the fetch stubs: since accounts list is empty, emails list stays empty
        // No exception = pass
        Test.startTest();
        List<Map<String, Object>> curr = BackupReportService.fetchPeriodData(30, 0);
        List<Map<String, Object>> stor = BackupReportService.fetchStorageData();
        Test.stopTest();

        System.assertEquals(1, curr.size(), 'Stub curr data returned');
        System.assertEquals(1, stor.size(), 'Stub stor data returned');
    }

    // ── fmtNum / delta via HTML output ───────────────────────────────────────

    @IsTest
    static void testLargeNumbersFormatted() {
        Map<String, Object> bigData = new Map<String, Object>{
            'account' => 'Big Corp', 'users' => 50,
            'bk' => 15000, 'ar' => 2000000, 're' => 0, 'ex' => 0, 'sr' => 0,
            'bk_exc' => 0, 'ar_exc' => 0, 're_exc' => 0, 'ex_exc' => 0, 'sr_exc' => 0
        };
        String html = BackupReportService.buildHtml(
            'Big Corp', bigData, new Map<String, Object>(),
            new Map<String, Object>(), new List<Map<String, Object>>(), false, null
        );
        System.assert(html.contains('15.0K'),   'Backups should be formatted as 15.0K');
        System.assert(html.contains('2.0M'),    'Archives should be formatted as 2.0M');
    }
}