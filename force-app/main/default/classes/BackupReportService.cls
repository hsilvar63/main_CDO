/**
 * BackupReportService
 * Generates and delivers monthly Backup & Archive summary reports per account.
 *
 * Dependencies (must already be deployed to the same org):
 *   - PostHogService  (from flosum-analytics-lwc project)
 *
 * Controls:
 *   - Report_Settings__mdt record "Default"
 *       Reports_Globally_Enabled__c  → master on/off switch
 *       Test_Mode__c                 → when true, all emails route to Test_Email__c
 *       Test_Email__c                → override recipient in test mode
 *   - Account fields
 *       Monthly_Report_Enabled__c   → per-account on/off
 *       Report_Recipients__c        → comma/newline-separated emails for production delivery
 */
public with sharing class BackupReportService {

    private static final String PROJECT_ID = '267194';

    // Allows unit tests to inject period data without real callouts
    @TestVisible private static List<Map<String, Object>> testCurrData;
    @TestVisible private static List<Map<String, Object>> testPrevData;
    @TestVisible private static List<Map<String, Object>> testStorData;
    @TestVisible private static List<Map<String, Object>> testOrgTypeData;

    // ── Entry point ──────────────────────────────────────────────────────────

    public static void sendMonthlyReports() {
        Report_Settings__mdt cfg = loadSettings();
        if (cfg == null || !cfg.Reports_Globally_Enabled__c) return;

        Boolean testMode  = cfg.Test_Mode__c;
        String  testEmail = cfg.Test_Email__c;
        if (testMode && String.isBlank(testEmail)) return;

        List<Account> accounts = [
            SELECT Id, Name, Report_Recipients__c
            FROM Account
            WHERE Current_Paid_Customer__c  = true
              AND Monthly_Report_Enabled__c  = true
              AND Rollup_ARR__c              > 1
            ORDER BY Name
        ];
        if (accounts.isEmpty()) return;

        // 4 PostHog callouts that return data for ALL accounts at once
        Map<String, Map<String, Object>> currMap     = buildMap(fetchPeriodData(30, 0));
        Map<String, Map<String, Object>> prevMap     = buildMap(fetchPeriodData(60, 30));
        Map<String, Map<String, Object>> storMap     = buildMap(fetchStorageData());
        Map<String, List<Map<String, Object>>> orgTypeMap = buildOrgTypeMap(fetchOrgTypeData());

        String owEmailId = getOrgWideEmailId();
        List<Messaging.SingleEmailMessage> emails = new List<Messaging.SingleEmailMessage>();

        for (Account acct : accounts) {
            List<String> to = resolveRecipients(cfg, acct, testMode, testEmail);
            if (to.isEmpty()) continue;

            Map<String, Object> curr = currMap.containsKey(acct.Name) ? currMap.get(acct.Name) : new Map<String, Object>();
            Map<String, Object> prev = prevMap.containsKey(acct.Name) ? prevMap.get(acct.Name) : new Map<String, Object>();
            Map<String, Object> stor = storMap.containsKey(acct.Name) ? storMap.get(acct.Name) : new Map<String, Object>();
            List<Map<String, Object>> orgTypes = orgTypeMap.containsKey(acct.Name) ? orgTypeMap.get(acct.Name) : new List<Map<String, Object>>();

            Messaging.SingleEmailMessage msg = new Messaging.SingleEmailMessage();
            msg.setToAddresses(to);
            msg.setSubject('Flosum B&A Monthly Report — ' + acct.Name + ' · ' + monthLabel());
            msg.setHtmlBody(buildHtml(acct.Name, curr, prev, stor, orgTypes, testMode, testEmail));
            if (owEmailId != null) {
                msg.setOrgWideEmailAddressId(owEmailId);
            } else {
                msg.setSenderDisplayName('Flosum Analytics');
            }
            emails.add(msg);
        }

        if (!emails.isEmpty()) {
            Messaging.sendEmail(emails);
        }
    }

    // ── PostHog queries ──────────────────────────────────────────────────────

    @TestVisible
    static List<Map<String, Object>> fetchPeriodData(Integer fromDays, Integer toDays) {
        if (testCurrData != null && toDays == 0)   return testCurrData;
        if (testPrevData != null && toDays == 30)  return testPrevData;

        String dateFilter = 'timestamp >= now() - INTERVAL ' + fromDays + ' DAY' +
            (toDays > 0 ? ' AND timestamp < now() - INTERVAL ' + toDays + ' DAY' : '');

        String q =
            'SELECT properties.accountName AS account, ' +
            '  count(DISTINCT distinct_id)                                            AS users, ' +
            '  countIf(event = \'Backup\')                                           AS bk,  ' +
            '  countIf(event = \'Archive\')                                          AS ar,  ' +
            '  countIf(event = \'Restore Data\')                                     AS re,  ' +
            '  countIf(event = \'Export\')                                           AS ex,  ' +
            '  countIf(event = \'Search\')                                           AS sr,  ' +
            '  countIf(event = \'Backup\'       AND properties.status = \'Exception\') AS bk_exc, ' +
            '  countIf(event = \'Archive\'      AND properties.status = \'Exception\') AS ar_exc, ' +
            '  countIf(event = \'Restore Data\' AND properties.status = \'Exception\') AS re_exc, ' +
            '  countIf(event = \'Export\'       AND properties.status = \'Exception\') AS ex_exc, ' +
            '  countIf(event = \'Search\'       AND properties.status = \'Exception\') AS sr_exc  ' +
            'FROM events ' +
            'WHERE ' + dateFilter + ' ' +
            '  AND properties.accountName IS NOT NULL ' +
            '  AND properties.accountName != \'\' ' +
            '  AND event IN (\'Backup\', \'Archive\', \'Restore Data\', \'Export\', \'Search\') ' +
            'GROUP BY account ORDER BY bk DESC LIMIT 500';

        List<Map<String, Object>> result = new List<Map<String, Object>>();
        try {
            Map<String, Object> resp = PostHogService.queryPostHog(PROJECT_ID, q);
            List<Object> rows = (List<Object>) resp.get('results');
            if (rows == null) return result;
            for (Object rowObj : rows) {
                List<Object> row = (List<Object>) rowObj;
                if (row == null || row.size() < 12) continue;
                String acct = row[0] != null ? String.valueOf(row[0]) : '';
                if (String.isBlank(acct)) continue;
                result.add(new Map<String, Object>{
                    'account' => acct,
                    'users'   => toInt(row[1]),
                    'bk'      => toInt(row[2]),  'ar'     => toInt(row[3]),
                    're'      => toInt(row[4]),  'ex'     => toInt(row[5]),  'sr'     => toInt(row[6]),
                    'bk_exc'  => toInt(row[7]),  'ar_exc' => toInt(row[8]),
                    're_exc'  => toInt(row[9]),  'ex_exc' => toInt(row[10]), 'sr_exc' => toInt(row[11])
                });
            }
        } catch (Exception e) { /* skip on callout failure, return empty */ }
        return result;
    }

    @TestVisible
    static List<Map<String, Object>> fetchStorageData() {
        if (testStorData != null) return testStorData;

        String q =
            'SELECT account_name AS account, sum(backup_mb) AS bk_mb, sum(archive_mb) AS ar_mb ' +
            'FROM (' +
            '  SELECT ' +
            '    properties.accountName        AS account_name, ' +
            '    properties.organizationName   AS org_name, ' +
            '    argMax(properties.totalBackupsSize,  timestamp) AS backup_mb, ' +
            '    argMax(properties.totalArchivesSize, timestamp) AS archive_mb ' +
            '  FROM events ' +
            '  WHERE event = \'Backup organizations Metrics\' ' +
            '    AND timestamp >= now() - INTERVAL 365 DAY ' +
            '    AND properties.accountName IS NOT NULL ' +
            '    AND properties.accountName != \'\' ' +
            '  GROUP BY account_name, org_name ' +
            ') ' +
            'GROUP BY account ORDER BY bk_mb DESC LIMIT 500';

        List<Map<String, Object>> result = new List<Map<String, Object>>();
        try {
            Map<String, Object> resp = PostHogService.queryPostHog(PROJECT_ID, q);
            List<Object> rows = (List<Object>) resp.get('results');
            if (rows == null) return result;
            for (Object rowObj : rows) {
                List<Object> row = (List<Object>) rowObj;
                if (row == null || row.size() < 3) continue;
                String acct = row[0] != null ? String.valueOf(row[0]) : '';
                if (String.isBlank(acct)) continue;
                result.add(new Map<String, Object>{
                    'account' => acct,
                    'bk_mb'   => toDec(row[1]),
                    'ar_mb'   => toDec(row[2])
                });
            }
        } catch (Exception e) { /* skip */ }
        return result;
    }

    @TestVisible
    static List<Map<String, Object>> fetchOrgTypeData() {
        if (testOrgTypeData != null) return testOrgTypeData;

        String q =
            'SELECT properties.accountName  AS account, ' +
            '  properties.organizationName  AS org_name, ' +
            '  properties.type              AS org_type, ' +
            '  max(timestamp)               AS last_backup ' +
            'FROM events ' +
            'WHERE timestamp >= now() - INTERVAL 365 DAY ' +
            '  AND event = \'Backup\' ' +
            '  AND properties.accountName IS NOT NULL ' +
            '  AND properties.accountName != \'\' ' +
            '  AND properties.organizationName IS NOT NULL ' +
            'GROUP BY account, org_name, org_type ' +
            'ORDER BY account, org_name ' +
            'LIMIT 2000';

        List<Map<String, Object>> result = new List<Map<String, Object>>();
        try {
            Map<String, Object> resp = PostHogService.queryPostHog(PROJECT_ID, q);
            List<Object> rows = (List<Object>) resp.get('results');
            if (rows == null) return result;
            for (Object rowObj : rows) {
                List<Object> row = (List<Object>) rowObj;
                if (row == null || row.size() < 4) continue;
                String acct    = row[0] != null ? String.valueOf(row[0]) : '';
                String orgName = row[1] != null ? String.valueOf(row[1]) : '';
                String orgType = row[2] != null ? String.valueOf(row[2]) : '';
                String lastBk  = '';
                if (row[3] != null) {
                    String ts = String.valueOf(row[3]);
                    lastBk = ts.length() >= 10 ? ts.substring(0, 10) : ts;
                }
                if (String.isBlank(acct) || String.isBlank(orgName)) continue;
                result.add(new Map<String, Object>{
                    'account'     => acct,
                    'org_name'    => orgName,
                    'org_type'    => orgType,
                    'last_backup' => lastBk
                });
            }
        } catch (Exception e) { /* skip on callout failure */ }
        return result;
    }

    // ── HTML email builder ───────────────────────────────────────────────────

    @TestVisible
    static String buildHtml(
        String                       acctName,
        Map<String, Object>          curr,
        Map<String, Object>          prev,
        Map<String, Object>          stor,
        List<Map<String, Object>>    orgTypes,
        Boolean                      testMode,
        String                       testEmail
    ) {
        Integer users     = toInt(curr.get('users'));
        Integer prevUsers = toInt(prev.get('users'));
        Integer bk = toInt(curr.get('bk')); Integer ar = toInt(curr.get('ar'));
        Integer re = toInt(curr.get('re')); Integer ex = toInt(curr.get('ex')); Integer sr = toInt(curr.get('sr'));
        Integer bkExc = toInt(curr.get('bk_exc')); Integer arExc = toInt(curr.get('ar_exc'));
        Integer reExc = toInt(curr.get('re_exc')); Integer exExc = toInt(curr.get('ex_exc')); Integer srExc = toInt(curr.get('sr_exc'));
        Integer totalOps = bk + ar + re + ex + sr;
        Integer prevOps  = toInt(prev.get('bk')) + toInt(prev.get('ar')) + toInt(prev.get('re'))
                         + toInt(prev.get('ex')) + toInt(prev.get('sr'));
        Integer totalExc = bkExc + arExc + reExc + exExc + srExc;
        Decimal bkMb  = toDec(stor.get('bk_mb'));
        Decimal arMb  = toDec(stor.get('ar_mb'));
        Decimal storGb = (bkMb + arMb) / 1024;

        String overallRate  = totalOps > 0 ? ((Decimal)(totalExc * 100) / totalOps).setScale(1) + '%' : '—';
        String rateColor    = excColor(totalExc, totalOps);
        String period       = monthLabel();
        String prevPeriod   = prevMonthLabel();
        Decimal bkGb = bkMb / 1024;
        Decimal arGb = arMb / 1024;
        String storDetail   = bkGb.setScale(1) + ' bk · ' + arGb.setScale(1) + ' ar GB';

        return
            '<!DOCTYPE html><html>' +
            '<head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1"></head>' +
            '<body style="margin:0;padding:0;background:#F1F5F9;font-family:-apple-system,BlinkMacSystemFont,\'Segoe UI\',Arial,sans-serif">' +
            '<table width="100%" cellpadding="0" cellspacing="0" style="background:#F1F5F9;padding:32px 16px">' +
            '<tr><td align="center">' +
            '<table width="600" cellpadding="0" cellspacing="0" style="background:#FFFFFF;border-radius:8px;overflow:hidden">' +

            // ── Test-mode banner ──
            (testMode ?
                '<tr><td style="background:#FEF3C7;padding:10px 24px;border-bottom:2px solid #FCD34D">' +
                '<p style="margin:0;font-size:12px;color:#92400E;text-align:center">' +
                '&#9888; <strong>TEST MODE</strong> &nbsp;&mdash;&nbsp; ' +
                'Delivered to <strong>' + escHtml(testEmail) + '</strong> instead of real account recipients' +
                '</p></td></tr>'
                : '') +

            // ── Header ──
            '<tr><td style="background:#0D1B2A;padding:28px 32px">' +
            '<p style="margin:0;color:#FF355E;font-size:11px;font-weight:700;letter-spacing:2px">FLOSUM</p>' +
            '<h1 style="margin:6px 0 0;color:#FFFFFF;font-size:22px;font-weight:700;line-height:1.2">Backup &amp; Archive</h1>' +
            '<p style="margin:2px 0 0;color:#CBD5E1;font-size:14px;font-weight:400">Monthly Report</p>' +
            '<p style="margin:16px 0 0;color:#64748B;font-size:12px">' +
            escHtml(acctName) + ' &nbsp;&bull;&nbsp; ' + period +
            '</p></td></tr>' +

            // ── Metric cards ──
            '<tr><td style="padding:24px 32px 16px">' +
            '<table width="100%" cellpadding="0" cellspacing="4"><tr>' +
            card('Active Users',    String.valueOf(users),         delta(users, prevUsers),   deltaColor(users, prevUsers),  'vs. ' + prevPeriod) +
            card('Total Ops',       fmtNum(totalOps),              delta(totalOps, prevOps),  deltaColor(totalOps, prevOps), 'vs. ' + prevPeriod) +
            card('Exception Rate',  overallRate,                   '',                        rateColor,                     '') +
            card('Total Storage',   storGb.setScale(1) + ' GB',   storDetail,                '#94A3B8',                     '') +
            '</tr></table></td></tr>' +

            // ── Operations breakdown ──
            '<tr><td style="padding:0 32px 28px">' +
            '<p style="margin:0 0 12px;font-size:11px;font-weight:700;color:#94A3B8;letter-spacing:1.5px;text-transform:uppercase">Operations Breakdown</p>' +
            '<table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:13px">' +
            '<thead><tr style="background:#F8FAFC">' +
            '<th style="padding:10px 14px;text-align:left;color:#475569;font-weight:600;border-bottom:2px solid #E2E8F0">Type</th>' +
            '<th style="padding:10px 14px;text-align:right;color:#475569;font-weight:600;border-bottom:2px solid #E2E8F0">Ops</th>' +
            '<th style="padding:10px 14px;text-align:right;color:#475569;font-weight:600;border-bottom:2px solid #E2E8F0">Exceptions</th>' +
            '<th style="padding:10px 14px;text-align:right;color:#475569;font-weight:600;border-bottom:2px solid #E2E8F0">Failure Rate</th>' +
            '</tr></thead><tbody>' +
            opsRow('Backup',  bk, bkExc, false) +
            opsRow('Archive', ar, arExc, true)  +
            opsRow('Restore', re, reExc, false) +
            opsRow('Export',  ex, exExc, true)  +
            opsRow('Search',  sr, srExc, false) +
            totalRow(totalOps, totalExc) +
            '</tbody></table></td></tr>' +

            // ── Org coverage ──
            orgTypeSection(orgTypes) +

            // ── Footer ──
            '<tr><td style="background:#F8FAFC;padding:16px 32px;border-top:1px solid #E2E8F0">' +
            '<p style="margin:0;font-size:11px;color:#94A3B8;text-align:center">' +
            '<a href="https://login.flosum.app" style="color:#1E3A8A;text-decoration:none;font-weight:600">Login to Flosum</a>' +
            ' &nbsp;&bull;&nbsp; Flosum Analytics &nbsp;&bull;&nbsp; Auto-generated on ' + Date.today().format() +
            '</p></td></tr>' +

            '</table></td></tr></table></body></html>';
    }

    // ── HTML sub-builders ────────────────────────────────────────────────────

    private static String card(String label, String value, String dlt, String dltColor, String dltSuffix) {
        return
            '<td style="padding:0 4px">' +
            '<div style="background:#F8FAFC;border-radius:6px;padding:16px 8px;text-align:center;border:1px solid #E2E8F0">' +
            '<div style="font-size:22px;font-weight:700;color:#0D1B2A;line-height:1.2">' + escHtml(value) + '</div>' +
            '<div style="font-size:11px;color:#64748B;margin-top:4px">' + escHtml(label) + '</div>' +
            (String.isNotBlank(dlt)
                ? '<div style="font-size:11px;color:' + dltColor + ';margin-top:3px">' + dlt + (String.isNotBlank(dltSuffix) ? ' ' + escHtml(dltSuffix) : '') + '</div>'
                : '') +
            '</div></td>';
    }

    private static String opsRow(String label, Integer ops, Integer exc, Boolean shaded) {
        String bg      = shaded ? '#F9FAFB' : '#FFFFFF';
        String rate    = ops > 0 ? ((Decimal)(exc * 100) / ops).setScale(1) + '%' : '—';
        String rateCol = excColor(exc, ops);
        String excCol  = exc > 0 ? '#DC2626' : '#64748B';
        String excWt   = exc > 0 ? '600' : '400';
        return
            '<tr style="background:' + bg + '">' +
            '<td style="padding:9px 14px;color:#334155;border-bottom:1px solid #F1F5F9">' + label + '</td>' +
            '<td style="padding:9px 14px;text-align:right;color:#334155;border-bottom:1px solid #F1F5F9">' + fmtNum(ops) + '</td>' +
            '<td style="padding:9px 14px;text-align:right;color:' + excCol + ';font-weight:' + excWt + ';border-bottom:1px solid #F1F5F9">' + fmtNum(exc) + '</td>' +
            '<td style="padding:9px 14px;text-align:right;color:' + rateCol + ';font-weight:600;border-bottom:1px solid #F1F5F9">' + rate + '</td>' +
            '</tr>';
    }

    private static String totalRow(Integer ops, Integer exc) {
        String rate    = ops > 0 ? ((Decimal)(exc * 100) / ops).setScale(1) + '%' : '—';
        String rateCol = excColor(exc, ops);
        String excCol  = exc > 0 ? '#DC2626' : '#059669';
        return
            '<tr style="background:#F0F4FF">' +
            '<td style="padding:10px 14px;color:#0D1B2A;font-weight:700;border-top:2px solid #E2E8F0">Total</td>' +
            '<td style="padding:10px 14px;text-align:right;color:#0D1B2A;font-weight:700;border-top:2px solid #E2E8F0">' + fmtNum(ops) + '</td>' +
            '<td style="padding:10px 14px;text-align:right;color:' + excCol + ';font-weight:700;border-top:2px solid #E2E8F0">' + fmtNum(exc) + '</td>' +
            '<td style="padding:10px 14px;text-align:right;color:' + rateCol + ';font-weight:700;border-top:2px solid #E2E8F0">' + rate + '</td>' +
            '</tr>';
    }

    // ── Helpers ───────────────────────────────────────────────────────────────

    private static String getOrgWideEmailId() {
        List<OrgWideEmailAddress> addrs = [
            SELECT Id FROM OrgWideEmailAddress
            WHERE Address = 'hsilvar63@gmail.com'
            LIMIT 1
        ];
        return addrs.isEmpty() ? null : addrs[0].Id;
    }

    private static Report_Settings__mdt loadSettings() {
        List<Report_Settings__mdt> rows = [
            SELECT Reports_Globally_Enabled__c, Test_Mode__c, Test_Email__c
            FROM Report_Settings__mdt
            WHERE DeveloperName = 'Default'
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0];
    }

    private static Map<String, Map<String, Object>> buildMap(List<Map<String, Object>> rows) {
        Map<String, Map<String, Object>> m = new Map<String, Map<String, Object>>();
        for (Map<String, Object> r : rows) {
            String acct = (String) r.get('account');
            if (String.isNotBlank(acct)) m.put(acct, r);
        }
        return m;
    }

    private static Map<String, List<Map<String, Object>>> buildOrgTypeMap(List<Map<String, Object>> rows) {
        Map<String, List<Map<String, Object>>> m = new Map<String, List<Map<String, Object>>>();
        for (Map<String, Object> r : rows) {
            String acct = (String) r.get('account');
            if (String.isNotBlank(acct)) {
                if (!m.containsKey(acct)) m.put(acct, new List<Map<String, Object>>());
                m.get(acct).add(r);
            }
        }
        return m;
    }

    private static String orgTypeSection(List<Map<String, Object>> orgTypes) {
        if (orgTypes == null || orgTypes.isEmpty()) return '';

        String tableRows = '';
        Boolean shaded   = false;

        for (Map<String, Object> row : orgTypes) {
            String orgName  = escHtml(String.valueOf(row.get('org_name')));
            String orgType  = escHtml(String.valueOf(row.get('org_type')));
            String lastBk   = escHtml(String.valueOf(row.get('last_backup')));
            String bg = shaded ? '#F9FAFB' : '#FFFFFF';
            tableRows +=
                '<tr style="background:' + bg + '">' +
                '<td style="padding:9px 14px;color:#334155;border-bottom:1px solid #F1F5F9">' + orgName + '</td>' +
                '<td style="padding:9px 14px;color:#334155;border-bottom:1px solid #F1F5F9">' + orgType + '</td>' +
                '<td style="padding:9px 14px;text-align:right;color:#334155;border-bottom:1px solid #F1F5F9">' + lastBk + '</td>' +
                '</tr>';
            shaded = !shaded;
        }

        return
            '<tr><td style="padding:0 32px 28px">' +
            '<p style="margin:0 0 12px;font-size:11px;font-weight:700;color:#94A3B8;letter-spacing:1.5px;text-transform:uppercase">Org Coverage</p>' +
            '<table width="100%" cellpadding="0" cellspacing="0" style="border-collapse:collapse;font-size:13px">' +
            '<thead><tr style="background:#F8FAFC">' +
            '<th style="padding:10px 14px;text-align:left;color:#475569;font-weight:600;border-bottom:2px solid #E2E8F0">Organization Name</th>' +
            '<th style="padding:10px 14px;text-align:left;color:#475569;font-weight:600;border-bottom:2px solid #E2E8F0">Type</th>' +
            '<th style="padding:10px 14px;text-align:right;color:#475569;font-weight:600;border-bottom:2px solid #E2E8F0">Last Backup Date</th>' +
            '</tr></thead><tbody>' +
            tableRows +
            '</tbody></table></td></tr>';
    }

    private static List<String> resolveRecipients(
        Report_Settings__mdt cfg, Account acct, Boolean testMode, String testEmail
    ) {
        if (testMode) {
            return String.isBlank(testEmail)
                ? new List<String>()
                : new List<String>{ testEmail };
        }
        if (String.isBlank(acct.Report_Recipients__c)) return new List<String>();
        List<String> result = new List<String>();
        for (String s : acct.Report_Recipients__c.split('[,;\\n\\r\\s]+')) {
            String e = s.trim();
            if (String.isNotBlank(e) && e.contains('@')) result.add(e);
        }
        return result;
    }

    private static String excColor(Integer exc, Integer ops) {
        if (ops == 0 || exc == 0) return '#059669';
        Decimal r = (Decimal)(exc * 100) / ops;
        if (r > 20) return '#DC2626';
        if (r > 5)  return '#D97706';
        return '#0F172A';
    }

    private static String delta(Integer curr, Integer prev) {
        if (curr == 0 && prev == 0) return '';
        Integer d = curr - prev;
        if (d == 0) return '→ 0';
        return d > 0 ? '▲ +' + String.valueOf(d) : '▼ ' + String.valueOf(d);
    }

    private static String deltaColor(Integer curr, Integer prev) {
        Integer d = curr - prev;
        if (d > 0) return '#059669';
        if (d < 0) return '#DC2626';
        return '#64748B';
    }

    private static String monthLabel() {
        Date d = Date.today().addMonths(-1);
        List<String> months = new List<String>{
            'January','February','March','April','May','June',
            'July','August','September','October','November','December'
        };
        return months[d.month() - 1] + ' ' + String.valueOf(d.year());
    }

    private static String prevMonthLabel() {
        Date d = Date.today().addMonths(-2);
        List<String> months = new List<String>{
            'January','February','March','April','May','June',
            'July','August','September','October','November','December'
        };
        return months[d.month() - 1] + ' ' + String.valueOf(d.year());
    }

    private static String fmtNum(Integer n) {
        if (n == null || n == 0) return '0';
        if (n >= 1000000) return (Decimal.valueOf(n) / 1000000).setScale(1) + 'M';
        if (n >= 1000)    return (Decimal.valueOf(n) / 1000).setScale(1) + 'K';
        return String.valueOf(n);
    }

    private static String escHtml(String s) {
        if (s == null) return '';
        return s.replace('&', '&amp;').replace('<', '&lt;').replace('>', '&gt;').replace('"', '&quot;');
    }

    private static Integer toInt(Object val) {
        if (val == null) return 0;
        try { return ((Decimal) val).intValue(); }
        catch (Exception e) {
            try { return Integer.valueOf(String.valueOf(val)); }
            catch (Exception e2) { return 0; }
        }
    }

    private static Decimal toDec(Object val) {
        if (val == null) return 0;
        try { return (Decimal) val; }
        catch (Exception e) {
            try { return Decimal.valueOf(String.valueOf(val)); }
            catch (Exception e2) { return 0; }
        }
    }
}