/**
 * PostHogController
 * AuraEnabled Apex controller for the flosumUsageDashboard LWC.
 * Returns customer usage data from PostHog for Native Apps and Cloud Apps.
 */
public with sharing class PostHogController {

    // ─── Product → PostHog Project ID mapping ───────────────────────────────
    private static final Map<String, String> PROJECT_IDS = new Map<String, String>{
        'native_apps'    => '259525',
        'cloud_apps'     => '267194',
        'cloud_devops'   => '267194',
        'backup_archive' => '267194',
        'data_migrator'  => '267194'
    };

    // ─── Cloud sub-product → application property value ─────────────────────
    private static final Map<String, String> APP_FILTERS = new Map<String, String>{
        'cloud_devops'   => 'DevOps',
        'backup_archive' => 'Backup&Archive',
        'data_migrator'  => 'Data Migrator'
    };

    private static AuraHandledException auraEx(String msg) {
        AuraHandledException e = new AuraHandledException(msg);
        e.setMessage(msg);
        return e;
    }

    private static String acctProp(String productKey) {
        return productKey == 'native_apps' ? 'account_name' : 'accountName';
    }

    // ─── Internal / partner account filter ──────────────────────────────────
    private static final List<String> EXCLUDED_ACCOUNT_FRAGMENTS = new List<String>{
        'flosum', 'success craft', 'succraft'
    };

    private static Boolean isFlosumInternal(String accountName) {
        if (accountName == null) return false;
        String lower = accountName.toLowerCase();
        for (String fragment : EXCLUDED_ACCOUNT_FRAGMENTS) {
            if (lower.contains(fragment)) return true;
        }
        return false;
    }

    // ─── Active paid-customer filter (Salesforce Account) ───────────────────
    // Returns lowercase Account Names where Current_Paid_Customer__c = true
    // and Rollup_ARR__c > 1 so callers can do case-insensitive membership checks.
    private static Set<String> getActivePaidCustomerNames() {
        Set<String> names = new Set<String>();
        for (Account a : [
            SELECT Name
            FROM Account
            WHERE Current_Paid_Customer__c = true
              AND Rollup_ARR__c > 1
        ]) {
            if (!String.isBlank(a.Name)) {
                names.add(a.Name.toLowerCase());
            }
        }
        return names;
    }

    // Builds a HogQL fragment "AND lower(<prop>) IN ('a', 'b', ...)" from a
    // lowercase name set. Returns '' when the set is null or empty.
    private static String buildPaidCustomerFilter(String prop, Set<String> names) {
        if (names == null || names.isEmpty()) return '';
        List<String> quoted = new List<String>();
        for (String n : names) {
            quoted.add('\'' + n.replace('\'', '\\\'') + '\'');
        }
        return '  AND lower(' + prop + ') IN (' + String.join(quoted, ', ') + ') ';
    }

    // ─── Cohort logic (mirrors the HTML dashboard thresholds) ───────────────
    private static String getCohort(Integer users) {
        if (users >= 30) return 'Enterprise';
        if (users >= 11) return 'Growth';
        if (users >= 3)  return 'Emerging';
        return 'Early Stage';
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  PUBLIC AuraEnabled METHODS
    // ═══════════════════════════════════════════════════════════════════════

    /**
     * Distinct account names active in the last 365 days — used to populate
     * the account selector dropdown in flosumAccountDashboard.
     */
    @AuraEnabled(cacheable=false)
    public static String getAccountNames(String productKey) {
        try {
            Set<String> paidNames = getActivePaidCustomerNames();
            Set<String> nameSet = new Set<String>();
            collectNames(nameSet, '259525', 'account_name', paidNames);
            collectNames(nameSet, '267194', 'accountName', paidNames);
            List<String> names = new List<String>(nameSet);
            names.sort();
            return JSON.serialize(names);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    private static void collectNames(Set<String> nameSet, String projectId, String prop, Set<String> paidNames) {
        try {
            String query =
                'SELECT properties.' + prop + ' AS account ' +
                'FROM events ' +
                'WHERE timestamp >= now() - INTERVAL 365 DAY ' +
                '  AND properties.' + prop + ' IS NOT NULL ' +
                '  AND properties.' + prop + ' != \'\' ' +
                'GROUP BY account ORDER BY account LIMIT 500';
            Map<String, Object> resp = PostHogService.queryPostHog(projectId, query);
            List<Object> results = (List<Object>) resp.get('results');
            if (results != null) {
                for (Object rowObj : results) {
                    List<Object> row = (List<Object>) rowObj;
                    String name = (String) row[0];
                    if (!String.isBlank(name) && !isFlosumInternal(name)
                            && (paidNames.isEmpty() || paidNames.contains(name.toLowerCase()))) {
                        nameSet.add(name);
                    }
                }
            }
        } catch (Exception e) { /* skip failed project */ }
    }

    /**
     * Returns the list of product keys that have event data for the given account
     * in the past 365 days. Used to populate the product selector in flosumAccountDashboard.
     */
    @AuraEnabled(cacheable=false)
    public static String getAvailableProducts(String accountName) {
        try {
            String escaped = accountName.replace('\'', '\\\'');
            List<String> products = new List<String>();

            // Native Apps
            try {
                String q = 'SELECT count() FROM events ' +
                    'WHERE properties.account_name = \'' + escaped + '\' ' +
                    '  AND timestamp >= now() - INTERVAL 365 DAY LIMIT 1';
                Map<String, Object> r = PostHogService.queryPostHog('259525', q);
                List<Object> rows = (List<Object>) r.get('results');
                if (rows != null && !rows.isEmpty() && toInt(((List<Object>) rows[0])[0]) > 0) {
                    products.add('native_apps');
                }
            } catch (Exception e) { /* skip */ }

            // Cloud Apps — get distinct application values for this account
            try {
                String q = 'SELECT properties.application AS app, count() AS cnt ' +
                    'FROM events ' +
                    'WHERE properties.accountName = \'' + escaped + '\' ' +
                    '  AND timestamp >= now() - INTERVAL 365 DAY ' +
                    'GROUP BY app';
                Map<String, Object> r = PostHogService.queryPostHog('267194', q);
                List<Object> rows = (List<Object>) r.get('results');
                if (rows != null) {
                    for (Object rowObj : rows) {
                        List<Object> row = (List<Object>) rowObj;
                        String app = (String) row[0];
                        if (toInt(row[1]) > 0) {
                            if (app == 'DevOps')          products.add('cloud_devops');
                            else if (app == 'Backup&Archive') products.add('backup_archive');
                            else if (app == 'Data Migrator')  products.add('data_migrator');
                        }
                    }
                }
            } catch (Exception e) { /* skip */ }

            return JSON.serialize(products);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * Full account detail: event counts for 30/90/180/365-day windows plus
     * a daily heartbeat series for the past 365 days.
     */
    @AuraEnabled(cacheable=false)
    public static String getAccountDetail(String productKey, String accountName, String orgId) {
        try {
            String projectId = PROJECT_IDS.get(productKey);
            if (projectId == null) throw auraEx('Unknown product key: ' + productKey);

            Map<String, Object> windows = new Map<String, Object>();
            for (Integer days : new List<Integer>{ 30, 90, 180, 365 }) {
                String query = buildAccountQuery(productKey, accountName, days, orgId);
                Map<String, Object> resp = PostHogService.queryPostHog(projectId, query);
                List<Object> rows = (List<Object>) resp.get('results');
                if (rows != null && !rows.isEmpty()) {
                    windows.put(String.valueOf(days), parseAccountRow((List<Object>) rows[0], productKey));
                } else {
                    windows.put(String.valueOf(days), new Map<String, Object>());
                }
            }

            Map<String, Object> result = new Map<String, Object>{
                'windows'   => windows,
                'heartbeat' => fetchHeartbeat(projectId, productKey, accountName, orgId)
            };
            return JSON.serialize(result);

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * Fetch customer usage data.
     * @param productKey  'native_apps' | 'cloud_apps'
     * @param days        lookback window (30, 60, 90, 180, 365)
     * @return            JSON string of List<Map<String,Object>>
     */
    @AuraEnabled(cacheable=false)
    public static String getCustomerUsage(String productKey, Integer days) {
        try {
            String projectId = PROJECT_IDS.get(productKey);
            if (projectId == null) {
                throw auraEx('Unknown product key: ' + productKey);
            }

            Set<String> paidNames = getActivePaidCustomerNames();
            String hogQuery = buildQuery(productKey, days);
            Map<String, Object> response = PostHogService.queryPostHog(projectId, hogQuery);

            List<Object> results = (List<Object>) response.get('results');
            if (results == null) results = new List<Object>();

            List<Map<String, Object>> processed = processResults(results, productKey, paidNames);
            return JSON.serialize(processed);

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * Weekly time-series trend data across all accounts for the given product/window.
     */
    @AuraEnabled(cacheable=false)
    public static String getUsageTrends(String productKey, Integer days) {
        try {
            String projectId = PROJECT_IDS.get(productKey);
            if (projectId == null) throw auraEx('Unknown product key: ' + productKey);
            Set<String> paidNames = getActivePaidCustomerNames();
            String hogQuery = buildTrendQuery(productKey, days, null, null, paidNames);
            Map<String, Object> response = PostHogService.queryPostHog(projectId, hogQuery);
            List<Object> results = (List<Object>) response.get('results');
            if (results == null) results = new List<Object>();
            return JSON.serialize(parseTrendRows(results, productKey));
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * Per-account connected-org counts from Licenses and Limits events.
     * Always queries the native-apps project (259525) regardless of productKey,
     * since that is where L&L events are ingested for all customers.
     * Returns a JSON object keyed by account_name: { prod_orgs, sandbox_orgs }.
     */
    @AuraEnabled(cacheable=false)
    public static String getOrgSummary(String productKey, Integer days) {
        try {
            if (PROJECT_IDS.get(productKey) == null) throw auraEx('Unknown product key: ' + productKey);
            Set<String> paidNames = getActivePaidCustomerNames();
            String hogQuery = buildOrgSummaryQuery(days);
            Map<String, Object> response = PostHogService.queryPostHog('259525', hogQuery);
            List<Object> results = (List<Object>) response.get('results');
            if (results == null) results = new List<Object>();
            return JSON.serialize(parseOrgSummaryRows(results, paidNames));
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * Per-org detail rows for a single account, from the latest Licenses and Limits events.
     * Returns a JSON array of org objects with SF users, storage, sandbox entitlements, etc.
     */
    @AuraEnabled(cacheable=false)
    public static String getOrgAudit(String productKey, String accountName) {
        try {
            if (String.isBlank(accountName)) throw auraEx('accountName is required');
            String hogQuery = buildOrgAuditQuery(accountName);
            Map<String, Object> response = PostHogService.queryPostHog('259525', hogQuery);
            List<Object> results = (List<Object>) response.get('results');
            if (results == null) results = new List<Object>();
            return JSON.serialize(parseOrgAuditRows(results));
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * Weekly time-series trend data for a single account.
     */
    @AuraEnabled(cacheable=false)
    public static String getAccountTrends(String productKey, String accountName, Integer days, String orgId) {
        try {
            String projectId = PROJECT_IDS.get(productKey);
            if (projectId == null) throw auraEx('Unknown product key: ' + productKey);
            String hogQuery = buildTrendQuery(productKey, days, accountName, orgId, null);
            Map<String, Object> response = PostHogService.queryPostHog(projectId, hogQuery);
            List<Object> results = (List<Object>) response.get('results');
            if (results == null) results = new List<Object>();
            return JSON.serialize(parseTrendRows(results, productKey));
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════════════════
    //  PRIVATE HELPERS
    // ═══════════════════════════════════════════════════════════════════════

    private static String buildTrendQuery(String productKey, Integer days, String accountName, String orgId, Set<String> paidNames) {
        String interval = String.valueOf(days);
        String acctFilter = '';
        String orgFilter  = String.isBlank(orgId) ? '' : '  AND properties.salesforce_org_id = \'' + orgId.replace('\'', '\\\'') + '\' ';
        if (productKey == 'native_apps') {
            String paidFilter = accountName == null ? buildPaidCustomerFilter('properties.account_name', paidNames) : '';
            if (accountName != null) {
                String esc = accountName.replace('\'', '\\\'');
                acctFilter = '  AND properties.account_name = \'' + esc + '\' ';
            }
            return
                'SELECT ' +
                '  toStartOfWeek(timestamp) AS week, ' +
                '  countIf(event = \'Deploy\' AND properties.trigger_source = \'Manual\') AS deploys_manual, ' +
                '  countIf(event = \'Deploy\' AND properties.trigger_source = \'Pipeline\') AS deploys_pipeline, ' +
                '  countIf(event = \'Commit to Branch\') AS commits, ' +
                '  countIf(event = \'Branch Create\') AS branches, ' +
                '  countIf(event = \'Validate\') AS validates, ' +
                '  countIf(event = \'Pipeline Run\') AS pipeline_runs, ' +
                '  countIf(event = \'Peer Review Create\') AS peer_reviews, ' +
                '  countIf(event = \'Code Scan\') AS code_scans, ' +
                '  countIf(event = \'Rollback\') AS rollbacks, ' +
                '  countIf(event = \'Smart Merge\') AS smart_merges, ' +
                '  countIf(event = \'Code Coverage\') AS code_coverage, ' +
                '  countIf(event = \'Snapshot Create\') AS snapshots, ' +
                '  countIf(event = \'Overwrite Protection\') AS overwrite_protection ' +
                'FROM events ' +
                'WHERE timestamp >= now() - INTERVAL ' + interval + ' DAY ' +
                '  AND properties.account_name IS NOT NULL ' +
                '  AND properties.account_name != \'\' ' +
                acctFilter +
                orgFilter +
                paidFilter +
                'GROUP BY week ORDER BY week ASC';
        } else {
            String paidFilter = accountName == null ? buildPaidCustomerFilter('properties.accountName', paidNames) : '';
            if (accountName != null) {
                String esc = accountName.replace('\'', '\\\'');
                acctFilter = '  AND properties.accountName = \'' + esc + '\' ';
            }
            return
                'SELECT ' +
                '  toStartOfWeek(timestamp) AS week, ' +
                '  countIf(event = \'Deploy\') AS deploys_manual, ' +
                '  countIf(event = \'Commit to branch\') AS commits, ' +
                '  countIf(event = \'Create branch\') AS branches, ' +
                '  countIf(event = \'Validate\') AS validates, ' +
                '  countIf(event = \'Pipeline execute\') AS pipeline_runs, ' +
                '  countIf(event = \'Smart Merge\') AS smart_merges, ' +
                '  countIf(event = \'Code scan\') AS code_scans, ' +
                '  countIf(event = \'Rollback\') AS rollbacks, ' +
                '  countIf(event = \'Backup\') AS backups, ' +
                '  countIf(event = \'Archive\') AS archives, ' +
                '  countIf(event = \'Restore Data\') AS restores, ' +
                '  countIf(event = \'Export\') AS exports, ' +
                '  countIf(event = \'Complete Migrate\') AS migrations, ' +
                '  countIf(event = \'Retrieve\') AS retrieves ' +
                'FROM events ' +
                'WHERE timestamp >= now() - INTERVAL ' + interval + ' DAY ' +
                '  AND properties.accountName IS NOT NULL ' +
                '  AND properties.accountName != \'\' ' +
                acctFilter +
                paidFilter +
                'GROUP BY week ORDER BY week ASC';
        }
    }

    private static Map<String, Object> parseTrendRows(List<Object> rows, String productKey) {
        List<String>  weeks            = new List<String>();
        List<Integer> deploys_manual   = new List<Integer>();
        List<Integer> deploys_pipeline = new List<Integer>();
        List<Integer> commits          = new List<Integer>();
        List<Integer> branches         = new List<Integer>();
        List<Integer> validates        = new List<Integer>();
        List<Integer> pipeline_runs    = new List<Integer>();
        List<Integer> peer_reviews     = new List<Integer>();
        List<Integer> code_scans       = new List<Integer>();
        List<Integer> rollbacks        = new List<Integer>();
        List<Integer> smart_merges     = new List<Integer>();
        List<Integer> code_coverage    = new List<Integer>();
        List<Integer> snapshots        = new List<Integer>();
        List<Integer> overwrite_prot   = new List<Integer>();
        List<Integer> backups          = new List<Integer>();
        List<Integer> archives         = new List<Integer>();
        List<Integer> restores         = new List<Integer>();
        List<Integer> exports          = new List<Integer>();
        List<Integer> migrations       = new List<Integer>();
        List<Integer> retrieves        = new List<Integer>();

        for (Object rowObj : rows) {
            List<Object> row = (List<Object>) rowObj;
            if (row == null || row.isEmpty()) continue;
            weeks.add(String.valueOf(row[0]));
            if (productKey == 'native_apps') {
                deploys_manual.add(toInt(row[1]));
                deploys_pipeline.add(toInt(row[2]));
                commits.add(toInt(row[3]));
                branches.add(toInt(row[4]));
                validates.add(toInt(row[5]));
                pipeline_runs.add(toInt(row[6]));
                peer_reviews.add(toInt(row[7]));
                code_scans.add(toInt(row[8]));
                rollbacks.add(toInt(row[9]));
                smart_merges.add(toInt(row[10]));
                code_coverage.add(toInt(row[11]));
                snapshots.add(toInt(row[12]));
                overwrite_prot.add(toInt(row[13]));
            } else {
                deploys_manual.add(toInt(row[1]));
                commits.add(toInt(row[2]));
                branches.add(toInt(row[3]));
                validates.add(toInt(row[4]));
                pipeline_runs.add(toInt(row[5]));
                smart_merges.add(toInt(row[6]));
                code_scans.add(toInt(row[7]));
                rollbacks.add(toInt(row[8]));
                backups.add(toInt(row[9]));
                archives.add(toInt(row[10]));
                restores.add(toInt(row[11]));
                exports.add(toInt(row[12]));
                migrations.add(toInt(row[13]));
                retrieves.add(toInt(row[14]));
            }
        }

        return new Map<String, Object>{
            'weeks'                => weeks,
            'deploys_manual'       => deploys_manual,
            'deploys_pipeline'     => deploys_pipeline,
            'commits'              => commits,
            'branches'             => branches,
            'validates'            => validates,
            'pipeline_runs'        => pipeline_runs,
            'peer_reviews'         => peer_reviews,
            'code_scans'           => code_scans,
            'rollbacks'            => rollbacks,
            'smart_merges'         => smart_merges,
            'code_coverage'        => code_coverage,
            'snapshots'            => snapshots,
            'overwrite_protection' => overwrite_prot,
            'backups'              => backups,
            'archives'             => archives,
            'restores'             => restores,
            'exports'              => exports,
            'migrations'           => migrations,
            'retrieves'            => retrieves
        };
    }

    private static String buildQuery(String productKey, Integer days) {
        String interval = String.valueOf(days);

        if (productKey == 'native_apps') {
            // Full Native DevOps event breakdown
            return
                'SELECT ' +
                '  properties.account_name AS account, ' +
                '  count(DISTINCT distinct_id) AS unique_users, ' +
                '  countIf(event = \'Deploy\') AS deploys, ' +
                '  countIf(event = \'Commit to Branch\') AS commits, ' +
                '  countIf(event = \'Branch Create\') AS branches, ' +
                '  countIf(event = \'Validate\') AS validates, ' +
                '  countIf(event = \'Pipeline Run\') AS pipeline_runs, ' +
                '  countIf(event = \'Peer Review Create\') AS peer_reviews, ' +
                '  countIf(event = \'Code Scan\') AS code_scans, ' +
                '  countIf(event = \'Rollback\') AS rollbacks, ' +
                '  countIf(event = \'Smart Merge\') AS smart_merges, ' +
                '  countIf(event = \'Code Coverage\') AS code_coverage, ' +
                '  countIf(event = \'Snapshot Create\') AS snapshots, ' +
                '  countIf(event = \'Overwrite Protection\') AS overwrite_protection, ' +
                '  count() AS total_events, ' +
                '  toInt(argMaxIf(properties.flosum_licenses_total, timestamp, event = \'Licenses and Limits\')) AS licenses_total, ' +
                '  toInt(argMaxIf(properties.flosum_licenses_used, timestamp, event = \'Licenses and Limits\')) AS licenses_used, ' +
                '  argMaxIf(properties.flosum_package_version, timestamp, event = \'Licenses and Limits\') AS package_version ' +
                'FROM events ' +
                'WHERE timestamp >= now() - INTERVAL ' + interval + ' DAY ' +
                '  AND properties.account_name IS NOT NULL ' +
                '  AND properties.account_name != \'\' ' +
                'GROUP BY account ' +
                'ORDER BY unique_users DESC ' +
                'LIMIT 500';
        } else if (productKey == 'cloud_devops') {
            return
                'SELECT ' +
                '  properties.accountName AS account, ' +
                '  count(DISTINCT distinct_id) AS unique_users, ' +
                '  countIf(event = \'Deploy\') AS deploys, ' +
                '  countIf(event = \'Commit to branch\') AS commits, ' +
                '  countIf(event = \'Create branch\') AS branches, ' +
                '  countIf(event = \'Validate\') AS validates, ' +
                '  countIf(event = \'Pipeline execute\') AS pipeline_runs, ' +
                '  countIf(event = \'Smart Merge\') AS smart_merges, ' +
                '  countIf(event = \'Code scan\') AS code_scans, ' +
                '  countIf(event = \'Rollback\') AS rollbacks, ' +
                '  count() AS total_events ' +
                'FROM events ' +
                'WHERE timestamp >= now() - INTERVAL ' + interval + ' DAY ' +
                '  AND properties.accountName IS NOT NULL ' +
                '  AND properties.accountName != \'\' ' +
                '  AND properties.application = \'DevOps\' ' +
                'GROUP BY account ORDER BY unique_users DESC LIMIT 500';

        } else if (productKey == 'backup_archive') {
            return
                'SELECT ' +
                '  properties.accountName AS account, ' +
                '  count(DISTINCT distinct_id) AS unique_users, ' +
                '  countIf(event = \'Backup\') AS backups, ' +
                '  countIf(event = \'Archive\') AS archives, ' +
                '  countIf(event = \'Restore Data\') AS restores, ' +
                '  countIf(event = \'Export\') AS exports, ' +
                '  count() AS total_events ' +
                'FROM events ' +
                'WHERE timestamp >= now() - INTERVAL ' + interval + ' DAY ' +
                '  AND properties.accountName IS NOT NULL ' +
                '  AND properties.accountName != \'\' ' +
                '  AND properties.application = \'Backup&Archive\' ' +
                'GROUP BY account ORDER BY unique_users DESC LIMIT 500';

        } else if (productKey == 'data_migrator') {
            return
                'SELECT ' +
                '  properties.accountName AS account, ' +
                '  count(DISTINCT distinct_id) AS unique_users, ' +
                '  countIf(event = \'Complete Migrate\') AS migrations, ' +
                '  countIf(event = \'Retrieve\') AS retrieves, ' +
                '  count() AS total_events ' +
                'FROM events ' +
                'WHERE timestamp >= now() - INTERVAL ' + interval + ' DAY ' +
                '  AND properties.accountName IS NOT NULL ' +
                '  AND properties.accountName != \'\' ' +
                '  AND properties.application = \'Data Migrator\' ' +
                'GROUP BY account ORDER BY unique_users DESC LIMIT 500';

        } else {
            // cloud_apps — legacy catch-all (all cloud events combined)
            return
                'SELECT ' +
                '  properties.accountName AS account, ' +
                '  count(DISTINCT distinct_id) AS unique_users, ' +
                '  countIf(event = \'Deploy\') AS deploys, ' +
                '  countIf(event = \'Commit to branch\') AS commits, ' +
                '  countIf(event = \'Create branch\') AS branches, ' +
                '  countIf(event = \'Validate\') AS validates, ' +
                '  countIf(event = \'Pipeline execute\') AS pipeline_runs, ' +
                '  countIf(event = \'Smart Merge\') AS smart_merges, ' +
                '  countIf(event = \'Code scan\') AS code_scans, ' +
                '  countIf(event = \'Rollback\') AS rollbacks, ' +
                '  countIf(event = \'Backup\') AS backups, ' +
                '  countIf(event = \'Archive\') AS archives, ' +
                '  countIf(event = \'Restore Data\') AS restores, ' +
                '  countIf(event = \'Export\') AS exports, ' +
                '  countIf(event = \'Complete Migrate\') AS migrations, ' +
                '  countIf(event = \'Retrieve\') AS retrieves, ' +
                '  count() AS total_events ' +
                'FROM events ' +
                'WHERE timestamp >= now() - INTERVAL ' + interval + ' DAY ' +
                '  AND properties.accountName IS NOT NULL ' +
                '  AND properties.accountName != \'\' ' +
                'GROUP BY account ORDER BY unique_users DESC LIMIT 500';
        }
    }

    private static List<Map<String, Object>> processResults(
        List<Object> results,
        String productKey,
        Set<String> paidNames
    ) {
        List<Map<String, Object>> processed = new List<Map<String, Object>>();

        for (Object rowObj : results) {
            List<Object> row = (List<Object>) rowObj;
            if (row == null || row.isEmpty()) continue;

            String accountName = (String) row[0];
            if (String.isBlank(accountName)) continue;
            if (isFlosumInternal(accountName)) continue;
            if (!paidNames.isEmpty() && !paidNames.contains(accountName.toLowerCase())) continue;

            Map<String, Object> record = new Map<String, Object>();
            record.put('account', accountName);

            if (productKey == 'native_apps') {
                Integer users              = toInt(row[1]);
                Integer deploys            = toInt(row[2]);
                Integer commits            = toInt(row[3]);
                Integer branches           = toInt(row[4]);
                Integer validates          = toInt(row[5]);
                Integer pipeline_runs      = toInt(row[6]);
                Integer peer_reviews       = toInt(row[7]);
                Integer code_scans         = toInt(row[8]);
                Integer rollbacks          = toInt(row[9]);
                Integer smart_merges       = toInt(row[10]);
                Integer code_coverage      = toInt(row[11]);
                Integer snapshots          = toInt(row[12]);
                Integer overwrite          = toInt(row[13]);
                Integer total_events       = toInt(row[14]);
                Integer licenses_total     = toInt(row[15]);
                Integer licenses_used      = toInt(row[16]);
                String  pkg_version        = row.size() > 17 && row[17] != null ? String.valueOf(row[17]) : '';

                record.put('users',                users);
                record.put('deploys',              deploys);
                record.put('commits',              commits);
                record.put('branches',             branches);
                record.put('validates',            validates);
                record.put('pipeline_runs',        pipeline_runs);
                record.put('peer_reviews',         peer_reviews);
                record.put('code_scans',           code_scans);
                record.put('rollbacks',            rollbacks);
                record.put('smart_merges',         smart_merges);
                record.put('code_coverage',        code_coverage);
                record.put('snapshots',            snapshots);
                record.put('overwrite_protection', overwrite);
                record.put('total_events',         total_events);
                record.put('licenses_total',       licenses_total);
                record.put('licenses_used',        licenses_used);
                record.put('package_version',      pkg_version);
                record.put('cohort',               getCohort(users));
                Decimal dpu = users > 0 ? ((Decimal) deploys / users).setScale(1) : 0;
                record.put('deploys_per_user',     dpu);

            } else if (productKey == 'cloud_devops') {
                Integer users = toInt(row[1]);
                record.put('users',         users);
                record.put('deploys',       toInt(row[2]));
                record.put('commits',       toInt(row[3]));
                record.put('branches',      toInt(row[4]));
                record.put('validates',     toInt(row[5]));
                record.put('pipeline_runs', toInt(row[6]));
                record.put('smart_merges',  toInt(row[7]));
                record.put('code_scans',    toInt(row[8]));
                record.put('rollbacks',     toInt(row[9]));
                record.put('total_events',  toInt(row[10]));
                record.put('cohort',        getCohort(users));
                Decimal dpu = users > 0 ? ((Decimal) toInt(row[2]) / users).setScale(1) : 0;
                record.put('deploys_per_user', dpu);

            } else if (productKey == 'backup_archive') {
                Integer users = toInt(row[1]);
                record.put('users',        users);
                record.put('backups',      toInt(row[2]));
                record.put('archives',     toInt(row[3]));
                record.put('restores',     toInt(row[4]));
                record.put('exports',      toInt(row[5]));
                record.put('total_events', toInt(row[6]));
                record.put('cohort',       getCohort(users));

            } else if (productKey == 'data_migrator') {
                Integer users = toInt(row[1]);
                record.put('users',        users);
                record.put('migrations',   toInt(row[2]));
                record.put('retrieves',    toInt(row[3]));
                record.put('total_events', toInt(row[4]));
                record.put('cohort',       getCohort(users));

            } else {
                // cloud_apps — legacy catch-all (17 columns)
                Integer users         = toInt(row[1]);
                record.put('users',         users);
                record.put('deploys',       toInt(row[2]));
                record.put('commits',       toInt(row[3]));
                record.put('branches',      toInt(row[4]));
                record.put('validates',     toInt(row[5]));
                record.put('pipeline_runs', toInt(row[6]));
                record.put('smart_merges',  toInt(row[7]));
                record.put('code_scans',    toInt(row[8]));
                record.put('rollbacks',     toInt(row[9]));
                record.put('backups',       toInt(row[10]));
                record.put('archives',      toInt(row[11]));
                record.put('restores',      toInt(row[12]));
                record.put('exports',       toInt(row[13]));
                record.put('migrations',    toInt(row[14]));
                record.put('retrieves',     toInt(row[15]));
                record.put('total_events',  toInt(row[16]));
                record.put('cohort',        getCohort(users));
                Decimal dpu = users > 0 ? ((Decimal) toInt(row[2]) / users).setScale(1) : 0;
                record.put('deploys_per_user', dpu);
            }

            processed.add(record);
        }

        return processed;
    }

    // Safe cast from Decimal/Object to Integer
    private static Integer toInt(Object val) {
        if (val == null) return 0;
        try { return ((Decimal) val).intValue(); }
        catch (Exception e) { return 0; }
    }

    // Safe cast from any numeric Object to Decimal
    private static Decimal toDec(Object val) {
        if (val == null) return 0;
        try { return (Decimal) val; }
        catch (Exception e) {
            try { return Decimal.valueOf(String.valueOf(val)); }
            catch (Exception e2) { return 0; }
        }
    }

    // ── Account-detail helpers ───────────────────────────────────────────────

    private static String buildAccountQuery(String productKey, String accountName, Integer days, String orgId) {
        String interval   = String.valueOf(days);
        String escaped    = accountName.replace('\'', '\\\'');
        String prop       = acctProp(productKey);
        String appFilter  = APP_FILTERS.containsKey(productKey)
            ? '  AND properties.application = \'' + APP_FILTERS.get(productKey) + '\'\n'
            : '';
        String orgFilter  = String.isBlank(orgId) ? '' : '  AND properties.salesforce_org_id = \'' + orgId.replace('\'', '\\\'') + '\'\n';
        String whereClause = 'FROM events\nWHERE timestamp >= now() - INTERVAL ' + interval + ' DAY\n'
            + '  AND properties.' + prop + ' = \'' + escaped + '\'\n'
            + appFilter
            + orgFilter;

        if (productKey == 'native_apps') {
            return 'SELECT count(DISTINCT distinct_id) AS users,'
                + ' countIf(event=\'Deploy\') AS deploys,'
                + ' countIf(event=\'Commit to Branch\') AS commits,'
                + ' countIf(event=\'Branch Create\') AS branches,'
                + ' countIf(event=\'Validate\') AS validates,'
                + ' countIf(event=\'Pipeline Run\') AS pipeline_runs,'
                + ' countIf(event=\'Peer Review Create\') AS peer_reviews,'
                + ' countIf(event=\'Code Scan\') AS code_scans,'
                + ' countIf(event=\'Rollback\') AS rollbacks,'
                + ' countIf(event=\'Smart Merge\') AS smart_merges,'
                + ' countIf(event=\'Code Coverage\') AS code_coverage,'
                + ' countIf(event=\'Snapshot Create\') AS snapshots,'
                + ' countIf(event=\'Overwrite Protection\') AS overwrite_protection,'
                + ' count() AS total_events ' + whereClause;
        } else if (productKey == 'cloud_devops') {
            return 'SELECT count(DISTINCT distinct_id) AS users,'
                + ' countIf(event=\'Deploy\') AS deploys,'
                + ' countIf(event=\'Commit to branch\') AS commits,'
                + ' countIf(event=\'Create branch\') AS branches,'
                + ' countIf(event=\'Validate\') AS validates,'
                + ' countIf(event=\'Pipeline execute\') AS pipeline_runs,'
                + ' countIf(event=\'Smart Merge\') AS smart_merges,'
                + ' countIf(event=\'Code scan\') AS code_scans,'
                + ' countIf(event=\'Rollback\') AS rollbacks,'
                + ' count() AS total_events ' + whereClause;
        } else if (productKey == 'backup_archive') {
            return 'SELECT count(DISTINCT distinct_id) AS users,'
                + ' countIf(event=\'Backup\') AS backups,'
                + ' countIf(event=\'Archive\') AS archives,'
                + ' countIf(event=\'Restore Data\') AS restores,'
                + ' countIf(event=\'Export\') AS exports,'
                + ' count() AS total_events ' + whereClause;
        } else if (productKey == 'data_migrator') {
            return 'SELECT count(DISTINCT distinct_id) AS users,'
                + ' countIf(event=\'Complete Migrate\') AS migrations,'
                + ' countIf(event=\'Retrieve\') AS retrieves,'
                + ' count() AS total_events ' + whereClause;
        } else {
            // cloud_apps (legacy — used by the main dashboard)
            return 'SELECT count(DISTINCT distinct_id) AS users,'
                + ' countIf(event=\'Deploy\') AS deploys,'
                + ' countIf(event=\'Commit to branch\') AS commits,'
                + ' countIf(event=\'Create branch\') AS branches,'
                + ' countIf(event=\'Validate\') AS validates,'
                + ' countIf(event=\'Pipeline execute\') AS pipeline_runs,'
                + ' countIf(event=\'Smart Merge\') AS smart_merges,'
                + ' countIf(event=\'Code scan\') AS code_scans,'
                + ' countIf(event=\'Rollback\') AS rollbacks,'
                + ' countIf(event=\'Backup\') AS backups,'
                + ' countIf(event=\'Archive\') AS archives,'
                + ' countIf(event=\'Restore Data\') AS restores,'
                + ' countIf(event=\'Export\') AS exports,'
                + ' countIf(event=\'Complete Migrate\') AS migrations,'
                + ' countIf(event=\'Retrieve\') AS retrieves,'
                + ' count() AS total_events ' + whereClause;
        }
    }

    private static Map<String, Object> parseAccountRow(List<Object> row, String productKey) {
        Map<String, Object> r = new Map<String, Object>();
        if (row == null || row.isEmpty()) return r;

        if (productKey == 'native_apps') {
            r.put('users',                toInt(row[0]));
            r.put('deploys',              toInt(row[1]));
            r.put('commits',              toInt(row[2]));
            r.put('branches',             toInt(row[3]));
            r.put('validates',            toInt(row[4]));
            r.put('pipeline_runs',        toInt(row[5]));
            r.put('peer_reviews',         toInt(row[6]));
            r.put('code_scans',           toInt(row[7]));
            r.put('rollbacks',            toInt(row[8]));
            r.put('smart_merges',         toInt(row[9]));
            r.put('code_coverage',        toInt(row[10]));
            r.put('snapshots',            toInt(row[11]));
            r.put('overwrite_protection', toInt(row[12]));
            r.put('total_events',         toInt(row[13]));
        } else if (productKey == 'cloud_devops') {
            r.put('users',         toInt(row[0]));
            r.put('deploys',       toInt(row[1]));
            r.put('commits',       toInt(row[2]));
            r.put('branches',      toInt(row[3]));
            r.put('validates',     toInt(row[4]));
            r.put('pipeline_runs', toInt(row[5]));
            r.put('smart_merges',  toInt(row[6]));
            r.put('code_scans',    toInt(row[7]));
            r.put('rollbacks',     toInt(row[8]));
            r.put('total_events',  toInt(row[9]));
        } else if (productKey == 'backup_archive') {
            r.put('users',        toInt(row[0]));
            r.put('backups',      toInt(row[1]));
            r.put('archives',     toInt(row[2]));
            r.put('restores',     toInt(row[3]));
            r.put('exports',      toInt(row[4]));
            r.put('total_events', toInt(row[5]));
        } else if (productKey == 'data_migrator') {
            r.put('users',        toInt(row[0]));
            r.put('migrations',   toInt(row[1]));
            r.put('retrieves',    toInt(row[2]));
            r.put('total_events', toInt(row[3]));
        } else {
            // cloud_apps legacy
            r.put('users',         toInt(row[0]));
            r.put('deploys',       toInt(row[1]));
            r.put('commits',       toInt(row[2]));
            r.put('branches',      toInt(row[3]));
            r.put('validates',     toInt(row[4]));
            r.put('pipeline_runs', toInt(row[5]));
            r.put('smart_merges',  toInt(row[6]));
            r.put('code_scans',    toInt(row[7]));
            r.put('rollbacks',     toInt(row[8]));
            r.put('backups',       toInt(row[9]));
            r.put('archives',      toInt(row[10]));
            r.put('restores',      toInt(row[11]));
            r.put('exports',       toInt(row[12]));
            r.put('migrations',    toInt(row[13]));
            r.put('retrieves',     toInt(row[14]));
            r.put('total_events',  toInt(row[15]));
        }
        return r;
    }

    private static String buildOrgSummaryQuery(Integer days) {
        String interval = String.valueOf(days);
        return
            'SELECT account_name, ' +
            '  countIf(is_sandbox = false OR is_sandbox IS NULL) AS prod_orgs, ' +
            '  countIf(is_sandbox = true)  AS sandbox_orgs ' +
            'FROM (' +
            '  SELECT ' +
            '    properties.account_name      AS account_name, ' +
            '    properties.salesforce_org_id AS org_id, ' +
            '    argMaxIf(properties.is_sandbox, timestamp, event = \'Licenses and Limits\') AS is_sandbox ' +
            '  FROM events ' +
            '  WHERE timestamp >= now() - INTERVAL ' + interval + ' DAY ' +
            '    AND properties.account_name IS NOT NULL ' +
            '    AND properties.account_name != \'\' ' +
            '    AND properties.salesforce_org_id IS NOT NULL ' +
            '    AND properties.salesforce_org_id != \'\' ' +
            '  GROUP BY account_name, org_id' +
            ') ' +
            'GROUP BY account_name ' +
            'ORDER BY account_name ASC LIMIT 500';
    }

    private static String buildOrgAuditQuery(String accountName) {
        String escaped = accountName.replace('\'', '\\\'');
        // Scan all events (not just L&L) so every active org is detected via salesforce_org_id.
        // License/package data is pulled conditionally from Licenses and Limits events only.
        return
            'SELECT ' +
            '  properties.salesforce_org_id AS org_id, ' +
            '  argMax(properties.salesforce_org_name, timestamp) AS org_name, ' +
            '  argMaxIf(properties.is_sandbox, timestamp, event = \'Licenses and Limits\') AS is_sandbox, ' +
            '  toInt(argMaxIf(properties.salesforce_total_licenses, timestamp, event = \'Licenses and Limits\'))          AS sf_total, ' +
            '  toInt(argMaxIf(properties.salesforce_used_licenses, timestamp, event = \'Licenses and Limits\'))           AS sf_used, ' +
            '  toInt(argMaxIf(properties.salesforce_platform_total_licenses, timestamp, event = \'Licenses and Limits\')) AS plat_total, ' +
            '  toInt(argMaxIf(properties.salesforce_platform_used_licenses, timestamp, event = \'Licenses and Limits\'))  AS plat_used, ' +
            '  toInt(argMaxIf(properties.data_storage_mb_max, timestamp, event = \'Licenses and Limits\'))       AS data_mb_max, ' +
            '  toInt(argMaxIf(properties.data_storage_mb_remaining, timestamp, event = \'Licenses and Limits\'))  AS data_mb_rem, ' +
            '  toInt(argMaxIf(properties.file_storage_mb_max, timestamp, event = \'Licenses and Limits\'))       AS file_mb_max, ' +
            '  toInt(argMaxIf(properties.file_storage_mb_remaining, timestamp, event = \'Licenses and Limits\'))  AS file_mb_rem, ' +
            '  toInt(argMaxIf(properties.developer_sandbox_count, timestamp, event = \'Licenses and Limits\'))    AS dev_sb_ent, ' +
            '  toInt(argMaxIf(properties.partial_sandbox_count, timestamp, event = \'Licenses and Limits\'))      AS partial_sb_ent, ' +
            '  toInt(argMaxIf(properties.full_sandbox_count, timestamp, event = \'Licenses and Limits\'))         AS full_sb_ent, ' +
            '  toInt(argMaxIf(properties.developer_pro_sandbox_count, timestamp, event = \'Licenses and Limits\')) AS dev_pro_sb_ent, ' +
            '  formatDateTime(max(timestamp), \'%Y-%m-%d\') AS last_seen, ' +
            '  argMaxIf(properties.flosum_package_version, timestamp, event = \'Licenses and Limits\') AS pkg_version, ' +
            '  toInt(argMaxIf(properties.flosum_licenses_total, timestamp, event = \'Licenses and Limits\'))  AS licenses_total, ' +
            '  toInt(argMaxIf(properties.flosum_licenses_used, timestamp, event = \'Licenses and Limits\'))   AS licenses_used ' +
            'FROM events ' +
            'WHERE properties.account_name = \'' + escaped + '\' ' +
            '  AND properties.salesforce_org_id IS NOT NULL ' +
            '  AND properties.salesforce_org_id != \'\' ' +
            '  AND timestamp >= now() - INTERVAL 365 DAY ' +
            'GROUP BY org_id ' +
            'ORDER BY is_sandbox ASC, org_name ASC LIMIT 100';
    }

    private static Map<String, Object> parseOrgSummaryRows(List<Object> rows, Set<String> paidNames) {
        Map<String, Object> byAccount = new Map<String, Object>();
        for (Object rowObj : rows) {
            List<Object> row = (List<Object>) rowObj;
            if (row == null || row.size() < 3) continue;
            String acct = (String) row[0];
            if (String.isBlank(acct) || isFlosumInternal(acct)) continue;
            if (!paidNames.isEmpty() && !paidNames.contains(acct.toLowerCase())) continue;
            byAccount.put(acct, new Map<String, Object>{
                'prod_orgs'    => toInt(row[1]),
                'sandbox_orgs' => toInt(row[2])
            });
        }
        return byAccount;
    }

    private static List<Map<String, Object>> parseOrgAuditRows(List<Object> rows) {
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (Object rowObj : rows) {
            List<Object> row = (List<Object>) rowObj;
            if (row == null || row.size() < 16) continue;

            String  orgId    = row[0] != null ? String.valueOf(row[0]) : '';
            String  orgName  = row[1] != null ? String.valueOf(row[1]) : '';
            Boolean sandbox  = false;
            if (row[2] instanceof Boolean) {
                sandbox = (Boolean) row[2];
            } else if (row[2] != null) {
                sandbox = toInt(row[2]) != 0;
            }

            Integer sfTotal   = toInt(row[3]);
            Integer sfUsed    = toInt(row[4]);
            Integer platTotal = toInt(row[5]);
            Integer platUsed  = toInt(row[6]);
            Integer dataMbMax = toInt(row[7]);
            Integer dataMbRem = toInt(row[8]);
            Integer fileMbMax = toInt(row[9]);
            Integer fileMbRem = toInt(row[10]);
            Integer devSbEnt  = toInt(row[11]);
            Integer partSbEnt = toInt(row[12]);
            Integer fullSbEnt = toInt(row[13]);
            Integer dproSbEnt = toInt(row[14]);
            String  lastSeen  = row[15] != null ? String.valueOf(row[15]) : '';
            String  pkgVer    = row.size() > 16 && row[16] != null ? String.valueOf(row[16]) : '';
            Integer licTotal  = row.size() > 17 ? toInt(row[17]) : 0;
            Integer licUsed   = row.size() > 18 ? toInt(row[18]) : 0;

            Decimal dataGbMax  = dataMbMax > 0 ? ((Decimal) dataMbMax / 1024).setScale(2) : 0;
            Decimal dataGbUsed = dataMbMax > 0 ? ((Decimal)(dataMbMax - dataMbRem) / 1024).setScale(2) : 0;
            Decimal fileGbMax  = fileMbMax > 0 ? ((Decimal) fileMbMax / 1024).setScale(2) : 0;
            Decimal fileGbUsed = fileMbMax > 0 ? ((Decimal)(fileMbMax - fileMbRem) / 1024).setScale(2) : 0;

            result.add(new Map<String, Object>{
                'org_id'          => orgId,
                'org_name'        => orgName,
                'org_type'        => sandbox ? 'Sandbox' : 'Production',
                'sf_users_used'   => sfUsed,
                'sf_users_total'  => sfTotal,
                'plat_users_used' => platUsed,
                'plat_users_total'=> platTotal,
                'data_gb_used'    => dataGbUsed,
                'data_gb_total'   => dataGbMax,
                'file_gb_used'    => fileGbUsed,
                'file_gb_total'   => fileGbMax,
                'dev_sb_ent'      => devSbEnt,
                'partial_sb_ent'  => partSbEnt,
                'full_sb_ent'     => fullSbEnt,
                'dev_pro_sb_ent'  => dproSbEnt,
                'last_seen'       => lastSeen,
                'pkg_version'     => pkgVer,
                'licenses_total'  => licTotal,
                'licenses_used'   => licUsed
            });
        }
        return result;
    }

    private static List<Object> fetchHeartbeat(String projectId, String productKey, String accountName, String orgId) {
        String escaped   = accountName.replace('\'', '\\\'');
        String prop      = acctProp(productKey);
        String appFilter = APP_FILTERS.containsKey(productKey)
            ? '  AND properties.application = \'' + APP_FILTERS.get(productKey) + '\'\n'
            : '';
        String orgFilter = String.isBlank(orgId) ? '' : '  AND properties.salesforce_org_id = \'' + orgId.replace('\'', '\\\'') + '\'\n';
        String primaryEvent = productKey == 'backup_archive' ? 'Backup'
            : productKey == 'data_migrator' ? 'Complete Migrate'
            : 'Deploy';
        String query =
            'SELECT toDate(timestamp) AS day, countIf(event = \'' + primaryEvent + '\') AS value '
            + 'FROM events '
            + 'WHERE properties.' + prop + ' = \'' + escaped + '\' '
            + appFilter
            + orgFilter
            + '  AND timestamp >= now() - INTERVAL 365 DAY '
            + 'GROUP BY day ORDER BY day';
        try {
            Map<String, Object> resp = PostHogService.queryPostHog(projectId, query);
            List<Object> rows = (List<Object>) resp.get('results');
            return rows != null ? rows : new List<Object>();
        } catch (Exception e) {
            return new List<Object>();
        }
    }

    /**
     * Per-org backup metrics for a single Backup & Archive account.
     * Returns org name, type, backup/archive GB, and last metric date.
     */
    @AuraEnabled(cacheable=false)
    public static String getBackupOrgDetail(String accountName) {
        try {
            if (String.isBlank(accountName)) throw auraEx('accountName is required');
            String hogQuery = buildBackupOrgQuery(accountName);
            Map<String, Object> response = PostHogService.queryPostHog('267194', hogQuery);
            List<Object> results = (List<Object>) response.get('results');
            if (results == null) results = new List<Object>();
            return JSON.serialize(parseBackupOrgRows(results));
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    private static String buildBackupOrgQuery(String accountName) {
        String escaped = accountName.replace('\'', '\\\'');
        return
            'SELECT ' +
            '  properties.organizationName AS org_name, ' +
            '  argMaxIf(properties.organizationType, timestamp, event = \'Backup organizations Metrics\') AS org_type, ' +
            '  argMaxIf(properties.region, timestamp, event = \'Backup organizations Metrics\') AS region, ' +
            '  argMaxIf(properties.totalBackupsSize, timestamp, event = \'Backup organizations Metrics\') AS backup_mb, ' +
            '  argMaxIf(properties.totalArchivesSize, timestamp, event = \'Backup organizations Metrics\') AS archive_mb, ' +
            '  argMaxIf(properties.databaseStorage, timestamp, event = \'Backup organizations Metrics\') AS db_mb, ' +
            '  argMaxIf(properties.weeklyJobHours, timestamp, event = \'Backup organizations Metrics\') AS weekly_hours, ' +
            '  formatDateTime(maxIf(timestamp, event = \'Backup organizations Metrics\'), \'%Y-%m-%d\') AS last_seen, ' +
            '  formatDateTime(minIf(timestamp, event = \'Backup organizations Metrics\'), \'%Y-%m-%d\') AS connected_date, ' +
            '  countIf(event = \'Backup\') AS backups, ' +
            '  countIf(event = \'Archive\') AS archives, ' +
            '  countIf(event = \'Restore Data\') AS restores, ' +
            '  countIf(event = \'Export\') AS exports, ' +
            '  formatDateTime(maxIf(timestamp, event IN (\'Backup\', \'Archive\', \'Restore Data\', \'Export\')), \'%Y-%m-%d\') AS last_operation_date, ' +
            '  argMaxIf(properties.dataStorageUsed,      timestamp, event = \'Report organization analytics\') AS sf_data_mb_used, ' +
            '  argMaxIf(properties.dataStorageAvailable, timestamp, event = \'Report organization analytics\') AS sf_data_mb_avail, ' +
            '  argMaxIf(properties.fileStorageUsed,      timestamp, event = \'Report organization analytics\') AS sf_file_mb_used, ' +
            '  argMaxIf(properties.fileStorageAvailable, timestamp, event = \'Report organization analytics\') AS sf_file_mb_avail, ' +
            '  argMaxIf(properties.organizationEdition,  timestamp, event = \'Report organization analytics\') AS sf_edition, ' +
            '  formatDateTime(maxIf(timestamp, event = \'Backup\' AND properties.status != \'Exception\'), \'%Y-%m-%d\') AS last_backup_date ' +
            'FROM events ' +
            'WHERE properties.accountName = \'' + escaped + '\' ' +
            '  AND (event = \'Backup organizations Metrics\' OR event = \'Report organization analytics\' ' +
            '       OR event = \'Backup\' OR event = \'Archive\' OR event = \'Restore Data\' OR event = \'Export\') ' +
            '  AND timestamp >= now() - INTERVAL 365 DAY ' +
            'GROUP BY org_name ' +
            'ORDER BY org_type ASC, db_mb DESC ' +
            'LIMIT 100';
    }

    private static List<Map<String, Object>> parseBackupOrgRows(List<Object> rows) {
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (Object rowObj : rows) {
            List<Object> row = (List<Object>) rowObj;
            if (row == null || row.size() < 14) continue;
            String  orgName           = row[0] != null ? String.valueOf(row[0]) : '';
            String  orgType           = row[1] != null ? String.valueOf(row[1]) : '';
            String  region            = row[2] != null ? String.valueOf(row[2]) : '';
            Decimal backupMb          = toDec(row[3]);
            Decimal archiveMb         = toDec(row[4]);
            Decimal dbMb              = toDec(row[5]);
            Decimal weeklyHrs         = toDec(row[6]);
            String  lastSeen          = row[7] != null ? String.valueOf(row[7]) : '';
            String  connectedDate     = row[8] != null ? String.valueOf(row[8]) : '';
            Integer backups           = toInt(row[9]);
            Integer archives          = toInt(row[10]);
            Integer restores          = toInt(row[11]);
            Integer exports           = toInt(row[12]);
            String  lastOperationDate = row[13] != null ? String.valueOf(row[13]) : '';
            Decimal sfDataMbUsed      = row.size() > 14 ? toDec(row[14]) : 0;
            Decimal sfDataMbAvail     = row.size() > 15 ? toDec(row[15]) : 0;
            Decimal sfFileMbUsed      = row.size() > 16 ? toDec(row[16]) : 0;
            Decimal sfFileMbAvail     = row.size() > 17 ? toDec(row[17]) : 0;
            String  sfEdition         = row.size() > 18 && row[18] != null ? String.valueOf(row[18]) : '';
            String  lastBackupDate    = row.size() > 19 && row[19] != null ? String.valueOf(row[19]) : '';
            if (String.isBlank(orgName)) continue;
            result.add(new Map<String, Object>{
                'org_name'            => orgName,
                'org_type'            => orgType,
                'region'              => region,
                'backup_mb'           => backupMb,
                'archive_mb'          => archiveMb,
                'db_mb'               => dbMb,
                'weekly_hours'        => weeklyHrs.setScale(2),
                'last_seen'           => lastSeen,
                'connected_date'      => connectedDate,
                'backups'             => backups,
                'archives'            => archives,
                'restores'            => restores,
                'exports'             => exports,
                'last_operation_date' => lastOperationDate,
                'sf_data_mb_used'     => sfDataMbUsed,
                'sf_data_mb_avail'    => sfDataMbAvail,
                'sf_file_mb_used'     => sfFileMbUsed,
                'sf_file_mb_avail'    => sfFileMbAvail,
                'sf_edition'          => sfEdition,
                'last_backup_date'    => lastBackupDate
            });
        }
        return result;
    }

    /**
     * Per-org exception breakdown for a single account.
     * Returns org name, type, exception/total counts for each operation type,
     * and the date of the most recent exception.
     */
    @AuraEnabled(cacheable=false)
    public static String getBackupOrgExceptions(String accountName) {
        try {
            if (String.isBlank(accountName)) throw auraEx('accountName is required');
            String hogQuery = buildBackupOrgExceptionQuery(accountName);
            Map<String, Object> response = PostHogService.queryPostHog('267194', hogQuery);
            List<Object> results = (List<Object>) response.get('results');
            if (results == null) results = new List<Object>();
            return JSON.serialize(parseBackupOrgExceptionRows(results));
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    private static String buildBackupOrgExceptionQuery(String accountName) {
        String escaped = accountName.replace('\'', '\\\'');
        return
            'SELECT ' +
            '  properties.organizationName AS org_name, ' +
            '  argMaxIf(properties.organizationType, timestamp, event = \'Backup organizations Metrics\') AS org_type, ' +
            '  countIf(event = \'Backup\'       AND properties.status = \'Exception\') AS backup_exceptions, ' +
            '  countIf(event = \'Backup\')                                             AS total_backups, ' +
            '  countIf(event = \'Archive\'      AND properties.status = \'Exception\') AS archive_exceptions, ' +
            '  countIf(event = \'Archive\')                                            AS total_archives, ' +
            '  countIf(event = \'Restore Data\' AND properties.status = \'Exception\') AS restore_exceptions, ' +
            '  countIf(event = \'Restore Data\')                                       AS total_restores, ' +
            '  countIf(event = \'Export\'       AND properties.status = \'Exception\') AS export_exceptions, ' +
            '  countIf(event = \'Export\')                                             AS total_exports, ' +
            '  countIf(event = \'Search\'       AND properties.status = \'Exception\') AS search_exceptions, ' +
            '  countIf(event = \'Search\')                                             AS total_searches, ' +
            '  formatDateTime(maxIf(timestamp, properties.status = \'Exception\'), \'%Y-%m-%d\') AS last_exception_date ' +
            'FROM events ' +
            'WHERE properties.accountName = \'' + escaped + '\' ' +
            '  AND event IN (\'Backup\', \'Archive\', \'Restore Data\', \'Export\', \'Search\', \'Backup organizations Metrics\') ' +
            '  AND timestamp >= now() - INTERVAL 365 DAY ' +
            'GROUP BY org_name ' +
            'HAVING (backup_exceptions + archive_exceptions + restore_exceptions + export_exceptions + search_exceptions) > 0 ' +
            '  AND maxIf(timestamp, event = \'Backup organizations Metrics\') >= now() - INTERVAL 30 DAY ' +
            'ORDER BY (backup_exceptions + archive_exceptions + restore_exceptions + export_exceptions + search_exceptions) DESC ' +
            'LIMIT 100';
    }

    private static List<Map<String, Object>> parseBackupOrgExceptionRows(List<Object> rows) {
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (Object rowObj : rows) {
            List<Object> row = (List<Object>) rowObj;
            if (row == null || row.size() < 13) continue;
            String orgName = row[0] != null ? String.valueOf(row[0]) : '';
            if (String.isBlank(orgName)) continue;
            String orgType = row[1] != null ? String.valueOf(row[1]) : '';
            result.add(new Map<String, Object>{
                'org_name'           => orgName,
                'org_type'           => orgType,
                'backup_exceptions'  => toInt(row[2]),
                'total_backups'      => toInt(row[3]),
                'archive_exceptions' => toInt(row[4]),
                'total_archives'     => toInt(row[5]),
                'restore_exceptions' => toInt(row[6]),
                'total_restores'     => toInt(row[7]),
                'export_exceptions'  => toInt(row[8]),
                'total_exports'      => toInt(row[9]),
                'search_exceptions'  => toInt(row[10]),
                'total_searches'     => toInt(row[11]),
                'last_exception_date'=> row[12] != null ? String.valueOf(row[12]) : ''
            });
        }
        return result;
    }

    /**
     * Per-account exception counts and operation totals for Backup, Archive,
     * Restore Data, Export, and Search events. Used by the Exceptions subtab.
     */
    @AuraEnabled(cacheable=false)
    public static String getBackupExceptionSummary() {
        try {
            Set<String> paidNames = getActivePaidCustomerNames();
            String hogQuery = buildBackupExceptionQuery();
            Map<String, Object> response = PostHogService.queryPostHog('267194', hogQuery);
            List<Object> results = (List<Object>) response.get('results');
            if (results == null) results = new List<Object>();
            return JSON.serialize(parseBackupExceptionRows(results, paidNames));
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    private static String buildBackupExceptionQuery() {
        String curr = 'timestamp >= now() - INTERVAL 30 DAY';
        String prev = 'timestamp < now() - INTERVAL 30 DAY';
        return
            'SELECT ' +
            '  properties.accountName AS account_name, ' +
            '  countIf(' + curr + ' AND event = \'Backup\'       AND properties.status = \'Exception\') AS backup_exceptions, ' +
            '  countIf(' + curr + ' AND event = \'Backup\')                                             AS total_backups, ' +
            '  countIf(' + curr + ' AND event = \'Archive\'      AND properties.status = \'Exception\') AS archive_exceptions, ' +
            '  countIf(' + curr + ' AND event = \'Archive\')                                            AS total_archives, ' +
            '  countIf(' + curr + ' AND event = \'Restore Data\' AND properties.status = \'Exception\') AS restore_exceptions, ' +
            '  countIf(' + curr + ' AND event = \'Restore Data\')                                       AS total_restores, ' +
            '  countIf(' + curr + ' AND event = \'Export\'       AND properties.status = \'Exception\') AS export_exceptions, ' +
            '  countIf(' + curr + ' AND event = \'Export\')                                             AS total_exports, ' +
            '  countIf(' + curr + ' AND event = \'Search\'       AND properties.status = \'Exception\') AS search_exceptions, ' +
            '  countIf(' + curr + ' AND event = \'Search\')                                             AS total_searches, ' +
            '  countIf(' + prev + ' AND event = \'Backup\'       AND properties.status = \'Exception\') AS prev_backup_exceptions, ' +
            '  countIf(' + prev + ' AND event = \'Backup\')                                             AS prev_total_backups, ' +
            '  countIf(' + prev + ' AND event = \'Archive\'      AND properties.status = \'Exception\') AS prev_archive_exceptions, ' +
            '  countIf(' + prev + ' AND event = \'Archive\')                                            AS prev_total_archives, ' +
            '  countIf(' + prev + ' AND event = \'Restore Data\' AND properties.status = \'Exception\') AS prev_restore_exceptions, ' +
            '  countIf(' + prev + ' AND event = \'Restore Data\')                                       AS prev_total_restores, ' +
            '  countIf(' + prev + ' AND event = \'Export\'       AND properties.status = \'Exception\') AS prev_export_exceptions, ' +
            '  countIf(' + prev + ' AND event = \'Export\')                                             AS prev_total_exports, ' +
            '  countIf(' + prev + ' AND event = \'Search\'       AND properties.status = \'Exception\') AS prev_search_exceptions, ' +
            '  countIf(' + prev + ' AND event = \'Search\')                                             AS prev_total_searches ' +
            'FROM events ' +
            'WHERE timestamp >= now() - INTERVAL 60 DAY ' +
            '  AND properties.accountName IS NOT NULL ' +
            '  AND properties.accountName != \'\' ' +
            '  AND event IN (\'Backup\', \'Archive\', \'Restore Data\', \'Export\', \'Search\') ' +
            '  AND properties.organizationName IN ( ' +
            '    SELECT DISTINCT properties.organizationName ' +
            '    FROM events ' +
            '    WHERE event = \'Backup organizations Metrics\' ' +
            '      AND timestamp >= now() - INTERVAL 30 DAY ' +
            '      AND properties.organizationName IS NOT NULL ' +
            '      AND properties.organizationName != \'\' ' +
            '  ) ' +
            'GROUP BY account_name ' +
            'ORDER BY (backup_exceptions + archive_exceptions + restore_exceptions + export_exceptions + search_exceptions) DESC ' +
            'LIMIT 500';
    }

    private static List<Map<String, Object>> parseBackupExceptionRows(List<Object> rows, Set<String> paidNames) {
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (Object rowObj : rows) {
            List<Object> row = (List<Object>) rowObj;
            if (row == null || row.size() < 21) continue;
            String acct = row[0] != null ? String.valueOf(row[0]) : '';
            if (String.isBlank(acct) || isFlosumInternal(acct)) continue;
            if (!paidNames.isEmpty() && !paidNames.contains(acct.toLowerCase())) continue;
            Integer prevTotalEx  = toInt(row[11]) + toInt(row[13]) + toInt(row[15]) + toInt(row[17]) + toInt(row[19]);
            Integer prevTotalOps = toInt(row[12]) + toInt(row[14]) + toInt(row[16]) + toInt(row[18]) + toInt(row[20]);
            result.add(new Map<String, Object>{
                'account'                 => acct,
                'backup_exceptions'       => toInt(row[1]),
                'total_backups'           => toInt(row[2]),
                'archive_exceptions'      => toInt(row[3]),
                'total_archives'          => toInt(row[4]),
                'restore_exceptions'      => toInt(row[5]),
                'total_restores'          => toInt(row[6]),
                'export_exceptions'       => toInt(row[7]),
                'total_exports'           => toInt(row[8]),
                'search_exceptions'       => toInt(row[9]),
                'total_searches'          => toInt(row[10]),
                'prev_backup_exceptions'  => toInt(row[11]),
                'prev_total_backups'      => toInt(row[12]),
                'prev_archive_exceptions' => toInt(row[13]),
                'prev_total_archives'     => toInt(row[14]),
                'prev_restore_exceptions' => toInt(row[15]),
                'prev_total_restores'     => toInt(row[16]),
                'prev_export_exceptions'  => toInt(row[17]),
                'prev_total_exports'      => toInt(row[18]),
                'prev_search_exceptions'  => toInt(row[19]),
                'prev_total_searches'     => toInt(row[20]),
                'prev_total_exceptions'   => prevTotalEx,
                'prev_total_ops'          => prevTotalOps
            });
        }
        return result;
    }

    /**
     * Aggregated backup org inventory across all accounts.
     * Returns per-account prod/sandbox org counts and total DB storage MB.
     * Used by the Org Inventory and Storage subtabs in flosumUsageDashboard.
     */
    @AuraEnabled(cacheable=false)
    public static String getBackupOrgSummary() {
        try {
            Set<String> paidNames = getActivePaidCustomerNames();
            String hogQuery = buildBackupOrgSummaryQuery();
            Map<String, Object> response = PostHogService.queryPostHog('267194', hogQuery);
            List<Object> results = (List<Object>) response.get('results');
            if (results == null) results = new List<Object>();
            return JSON.serialize(parseBackupOrgSummaryRows(results, paidNames));
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    private static String buildBackupOrgSummaryQuery() {
        return
            'SELECT ' +
            '  account_name, ' +
            '  countIf(period = \'current\'  AND org_type = \'Production\')  AS curr_prod_orgs, ' +
            '  countIf(period = \'previous\' AND org_type = \'Production\')  AS prev_prod_orgs, ' +
            '  countIf(period = \'current\'  AND org_type != \'Production\') AS curr_sandbox_orgs, ' +
            '  countIf(period = \'previous\' AND org_type != \'Production\') AS prev_sandbox_orgs, ' +
            '  sumIf(backup_mb,  period = \'current\')  AS total_backup_mb, ' +
            '  sumIf(archive_mb, period = \'current\')  AS total_archive_mb, ' +
            '  sumIf(backup_mb,  period = \'previous\') AS prev_backup_mb, ' +
            '  sumIf(archive_mb, period = \'previous\') AS prev_archive_mb ' +
            'FROM (' +
            '  SELECT ' +
            '    properties.accountName AS account_name, ' +
            '    properties.organizationName AS org_name, ' +
            '    if(timestamp >= now() - INTERVAL 30 DAY, \'current\', \'previous\') AS period, ' +
            '    argMax(properties.organizationType, timestamp)  AS org_type, ' +
            '    argMax(properties.totalBackupsSize, timestamp)  AS backup_mb, ' +
            '    argMax(properties.totalArchivesSize, timestamp) AS archive_mb ' +
            '  FROM events ' +
            '  WHERE event = \'Backup organizations Metrics\' ' +
            '    AND timestamp >= now() - INTERVAL 60 DAY ' +
            '    AND properties.accountName IS NOT NULL ' +
            '    AND properties.accountName != \'\' ' +
            '    AND properties.organizationName IS NOT NULL ' +
            '    AND properties.organizationName != \'\' ' +
            '  GROUP BY account_name, org_name, period' +
            ') ' +
            'GROUP BY account_name ' +
            'ORDER BY (total_backup_mb + total_archive_mb) DESC ' +
            'LIMIT 500';
    }

    private static List<Map<String, Object>> parseBackupOrgSummaryRows(List<Object> rows, Set<String> paidNames) {
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (Object rowObj : rows) {
            List<Object> row = (List<Object>) rowObj;
            if (row == null || row.size() < 9) continue;
            String acct = row[0] != null ? String.valueOf(row[0]) : '';
            if (String.isBlank(acct) || isFlosumInternal(acct)) continue;
            if (!paidNames.isEmpty() && !paidNames.contains(acct.toLowerCase())) continue;
            result.add(new Map<String, Object>{
                'account'           => acct,
                'prod_orgs'         => toInt(row[1]),
                'prev_prod_orgs'    => toInt(row[2]),
                'sandbox_orgs'      => toInt(row[3]),
                'prev_sandbox_orgs' => toInt(row[4]),
                'total_backup_mb'   => toDec(row[5]),
                'total_archive_mb'  => toDec(row[6]),
                'prev_backup_mb'    => toDec(row[7]),
                'prev_archive_mb'   => toDec(row[8])
            });
        }
        return result;
    }

    /**
     * Per-account active user counts and last activity date.
     * Counts distinct users who performed any Backup/Archive/Restore/Export/Search operation.
     */
    @AuraEnabled(cacheable=false)
    public static String getBackupActiveUserSummary() {
        try {
            Set<String> paidNames = getActivePaidCustomerNames();
            String hogQuery =
                'SELECT ' +
                '  account_name, ' +
                '  countIf(period = \'current\')  AS active_users, ' +
                '  countIf(period = \'previous\') AS prev_active_users, ' +
                '  formatDateTime(max(last_ts), \'%Y-%m-%d\') AS last_activity ' +
                'FROM (' +
                '  SELECT ' +
                '    properties.accountName AS account_name, ' +
                '    distinct_id, ' +
                '    if(timestamp >= now() - INTERVAL 30 DAY, \'current\', \'previous\') AS period, ' +
                '    max(timestamp) AS last_ts ' +
                '  FROM events ' +
                '  WHERE timestamp >= now() - INTERVAL 60 DAY ' +
                '    AND properties.accountName IS NOT NULL ' +
                '    AND properties.accountName != \'\' ' +
                '    AND event IN (\'Backup\', \'Archive\', \'Restore Data\', \'Export\', \'Search\') ' +
                '  GROUP BY account_name, distinct_id, period' +
                ') ' +
                'GROUP BY account_name ' +
                'ORDER BY active_users DESC ' +
                'LIMIT 500';
            Map<String, Object> response = PostHogService.queryPostHog('267194', hogQuery);
            List<Object> results = (List<Object>) response.get('results');
            if (results == null) results = new List<Object>();
            List<Map<String, Object>> parsed = new List<Map<String, Object>>();
            for (Object rowObj : results) {
                List<Object> row = (List<Object>) rowObj;
                if (row == null || row.size() < 4) continue;
                String acct = row[0] != null ? String.valueOf(row[0]) : '';
                if (String.isBlank(acct) || isFlosumInternal(acct)) continue;
                if (!paidNames.isEmpty() && !paidNames.contains(acct.toLowerCase())) continue;
                String lastAct = row[3] != null ? String.valueOf(row[3]) : '';
                if (lastAct.startsWith('1970')) lastAct = '';
                parsed.add(new Map<String, Object>{
                    'account'           => acct,
                    'active_users'      => toInt(row[1]),
                    'prev_active_users' => toInt(row[2]),
                    'last_activity'     => lastAct
                });
            }
            return JSON.serialize(parsed);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    /**
     * All orgs of a given type (Production or Sandbox) across all accounts.
     * Used when the user clicks a slice of the breakdown donut on the Org Inventory tab.
     */
    @AuraEnabled(cacheable=false)
    public static String getBackupAllOrgsByType(String orgType) {
        try {
            if (String.isBlank(orgType)) throw auraEx('orgType is required');
            Set<String> paidNames = getActivePaidCustomerNames();
            String hogQuery = buildBackupAllOrgsQuery(orgType);
            Map<String, Object> response = PostHogService.queryPostHog('267194', hogQuery);
            List<Object> results = (List<Object>) response.get('results');
            if (results == null) results = new List<Object>();
            return JSON.serialize(parseBackupAllOrgRows(results, paidNames));
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    private static String buildBackupAllOrgsQuery(String orgType) {
        String typeFilter = orgType == 'Production'
            ? 'org_type = \'Production\''
            : 'org_type != \'Production\'';
        return
            'SELECT ' +
            '  properties.accountName AS account_name, ' +
            '  properties.organizationName AS org_name, ' +
            '  argMaxIf(properties.organizationType, timestamp, event = \'Backup organizations Metrics\') AS org_type, ' +
            '  argMaxIf(properties.totalBackupsSize, timestamp, event = \'Backup organizations Metrics\') AS backup_mb, ' +
            '  argMaxIf(properties.totalArchivesSize, timestamp, event = \'Backup organizations Metrics\') AS archive_mb, ' +
            '  formatDateTime(minIf(timestamp, event = \'Backup organizations Metrics\'), \'%Y-%m-%d\') AS connected_date, ' +
            '  countIf(event = \'Backup\') AS backups, ' +
            '  countIf(event = \'Archive\') AS archives, ' +
            '  countIf(event = \'Restore Data\') AS restores, ' +
            '  countIf(event = \'Export\') AS exports, ' +
            '  formatDateTime(maxIf(timestamp, event IN (\'Backup\', \'Archive\', \'Restore Data\', \'Export\')), \'%Y-%m-%d\') AS last_operation_date, ' +
            '  argMaxIf(properties.dataStorageUsed,      timestamp, event = \'Report organization analytics\') AS sf_data_mb_used, ' +
            '  argMaxIf(properties.dataStorageAvailable, timestamp, event = \'Report organization analytics\') AS sf_data_mb_avail, ' +
            '  argMaxIf(properties.fileStorageUsed,      timestamp, event = \'Report organization analytics\') AS sf_file_mb_used, ' +
            '  argMaxIf(properties.fileStorageAvailable, timestamp, event = \'Report organization analytics\') AS sf_file_mb_avail, ' +
            '  argMaxIf(properties.organizationEdition,  timestamp, event = \'Report organization analytics\') AS sf_edition, ' +
            '  formatDateTime(maxIf(timestamp, event = \'Backup\' AND properties.status != \'Exception\'), \'%Y-%m-%d\') AS last_backup_date ' +
            'FROM events ' +
            'WHERE (event = \'Backup organizations Metrics\' OR event = \'Report organization analytics\' ' +
            '       OR event = \'Backup\' OR event = \'Archive\' OR event = \'Restore Data\' OR event = \'Export\') ' +
            '  AND timestamp >= now() - INTERVAL 365 DAY ' +
            '  AND properties.accountName IS NOT NULL ' +
            '  AND properties.accountName != \'\' ' +
            '  AND properties.organizationName IS NOT NULL ' +
            '  AND properties.organizationName != \'\' ' +
            'GROUP BY account_name, org_name ' +
            'HAVING ' + typeFilter + ' ' +
            'ORDER BY account_name ASC, org_name ASC ' +
            'LIMIT 500';
    }

    private static List<Map<String, Object>> parseBackupAllOrgRows(List<Object> rows, Set<String> paidNames) {
        List<Map<String, Object>> result = new List<Map<String, Object>>();
        for (Object rowObj : rows) {
            List<Object> row = (List<Object>) rowObj;
            if (row == null || row.size() < 11) continue;
            String acct    = row[0] != null ? String.valueOf(row[0]) : '';
            String orgName = row[1] != null ? String.valueOf(row[1]) : '';
            if (String.isBlank(acct) || String.isBlank(orgName)) continue;
            if (isFlosumInternal(acct)) continue;
            if (!paidNames.isEmpty() && !paidNames.contains(acct.toLowerCase())) continue;
            String  orgType   = row[2]  != null ? String.valueOf(row[2])  : '';
            Decimal backupMb  = toDec(row[3]);
            Decimal archiveMb = toDec(row[4]);
            String  connDate  = row[5]  != null ? String.valueOf(row[5])  : '';
            String  lastOp    = row[10] != null ? String.valueOf(row[10]) : '';
            Decimal sfDataMbUsed  = row.size() > 11 ? toDec(row[11]) : 0;
            Decimal sfDataMbAvail = row.size() > 12 ? toDec(row[12]) : 0;
            Decimal sfFileMbUsed  = row.size() > 13 ? toDec(row[13]) : 0;
            Decimal sfFileMbAvail = row.size() > 14 ? toDec(row[14]) : 0;
            String  sfEdition      = row.size() > 15 && row[15] != null ? String.valueOf(row[15]) : '';
            String  lastBackupDate = row.size() > 16 && row[16] != null ? String.valueOf(row[16]) : '';
            result.add(new Map<String, Object>{
                'account_name'        => acct,
                'org_name'            => orgName,
                'org_type'            => orgType,
                'backup_mb'           => backupMb,
                'archive_mb'          => archiveMb,
                'connected_date'      => connDate,
                'backups'             => toInt(row[6]),
                'archives'            => toInt(row[7]),
                'restores'            => toInt(row[8]),
                'exports'             => toInt(row[9]),
                'last_operation_date' => lastOp,
                'sf_data_mb_used'     => sfDataMbUsed,
                'sf_data_mb_avail'    => sfDataMbAvail,
                'sf_file_mb_used'     => sfFileMbUsed,
                'sf_file_mb_avail'    => sfFileMbAvail,
                'sf_edition'          => sfEdition,
                'last_backup_date'    => lastBackupDate
            });
        }
        return result;
    }

    /**
     * Per-user operation breakdown for a single Backup & Archive account.
     * Returns user identity, operation counts, and last activity date.
     */
    @AuraEnabled(cacheable=false)
    public static String getBackupUserDetail(String accountName) {
        try {
            if (String.isBlank(accountName)) throw auraEx('accountName is required');
            String escaped = accountName.replace('\'', '\\\'');
            String hogQuery =
                'SELECT ' +
                '  argMax(properties.email, timestamp)      AS email, ' +
                '  argMax(properties.createdBy, timestamp)  AS created_by, ' +
                '  distinct_id, ' +
                '  countIf(event = \'Backup\')       AS backups, ' +
                '  countIf(event = \'Archive\')      AS archives, ' +
                '  countIf(event = \'Restore Data\') AS restores, ' +
                '  countIf(event = \'Export\')       AS exports, ' +
                '  countIf(event = \'Search\')       AS searches, ' +
                '  count()                           AS total_ops, ' +
                '  formatDateTime(max(timestamp), \'%Y-%m-%d\') AS last_activity ' +
                'FROM events ' +
                'WHERE properties.accountName = \'' + escaped + '\' ' +
                '  AND event IN (\'Backup\', \'Archive\', \'Restore Data\', \'Export\', \'Search\') ' +
                '  AND timestamp >= now() - INTERVAL 365 DAY ' +
                'GROUP BY distinct_id ' +
                'ORDER BY total_ops DESC ' +
                'LIMIT 100';
            Map<String, Object> response = PostHogService.queryPostHog('267194', hogQuery);
            List<Object> results = (List<Object>) response.get('results');
            if (results == null) results = new List<Object>();
            List<Map<String, Object>> parsed = new List<Map<String, Object>>();
            for (Object rowObj : results) {
                List<Object> row = (List<Object>) rowObj;
                if (row == null || row.size() < 10) continue;
                String email      = row[0] != null ? String.valueOf(row[0]) : '';
                String createdBy  = row[1] != null ? String.valueOf(row[1]) : '';
                String distinctId = row[2] != null ? String.valueOf(row[2]) : '';
                String lastAct    = row[9] != null ? String.valueOf(row[9]) : '';
                if (lastAct.startsWith('1970')) lastAct = '';
                String displayName = !String.isBlank(email)     ? email
                                   : !String.isBlank(createdBy) ? createdBy
                                   : distinctId;
                if (String.isBlank(displayName)) continue;
                parsed.add(new Map<String, Object>{
                    'user'          => displayName,
                    'email'         => email,
                    'created_by'    => createdBy,
                    'distinct_id'   => distinctId,
                    'backups'       => toInt(row[3]),
                    'archives'      => toInt(row[4]),
                    'restores'      => toInt(row[5]),
                    'exports'       => toInt(row[6]),
                    'searches'      => toInt(row[7]),
                    'total_ops'     => toInt(row[8]),
                    'last_activity' => lastAct
                });
            }
            return JSON.serialize(parsed);
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException(e.getMessage());
        }
    }

    // ── Customer Compliance — License Types from Salesforce Opportunities ───────

    @AuraEnabled(cacheable=false)
    public static String getBackupLicenseTypes() {
        try {
            Map<String, Integer> tierMap    = new Map<String, Integer>();
            Map<String, String>  licenseMap = new Map<String, String>();

            for (OpportunityLineItem oli : [
                SELECT Opportunity.Account.Name,
                       PricebookEntry.Product2.Name,
                       PricebookEntry.ProductCode
                FROM OpportunityLineItem
                WHERE Opportunity.IsWon = true
                  AND (
                    PricebookEntry.Product2.Name LIKE '%Backup Only%'
                    OR PricebookEntry.Product2.Name LIKE '%Essentials%'
                    OR PricebookEntry.Product2.Name LIKE '%Enterprise%'
                    OR PricebookEntry.Product2.Name LIKE '%Backup & Archive%'
                    OR PricebookEntry.Product2.Name LIKE '%Backup %Archive%'
                    OR PricebookEntry.ProductCode   LIKE 'F-DBR%'
                  )
                ORDER BY Opportunity.CloseDate DESC
                LIMIT 2000
            ]) {
                String acct    = oli.Opportunity.Account.Name;
                String product = oli.PricebookEntry != null ? oli.PricebookEntry.Product2.Name : null;
                String code    = oli.PricebookEntry != null && oli.PricebookEntry.ProductCode != null
                                 ? oli.PricebookEntry.ProductCode.toUpperCase() : '';
                if (String.isBlank(acct) || (String.isBlank(product) && String.isBlank(code))) continue;

                String licenseType;
                Integer tier;
                String pLower = product != null ? product.toLowerCase() : '';
                if      (pLower.contains('enterprise plus'))            { licenseType = 'Enterprise Plus'; tier = 5; }
                else if (pLower.contains('enterprise'))                  { licenseType = 'Enterprise';       tier = 4; }
                else if (pLower.contains('essentials'))                  { licenseType = 'Essentials';       tier = 3; }
                else if (pLower.contains('backup only'))                 { licenseType = 'Backup Only';      tier = 1; }
                else if (pLower.contains('backup') || code.startsWith('F-DBR')) {
                    licenseType = 'Commercial'; tier = 2;
                }
                else continue;

                Integer existing = tierMap.get(acct);
                if (existing == null || tier > existing) {
                    tierMap.put(acct, tier);
                    licenseMap.put(acct, licenseType);
                }
            }

            List<Map<String, Object>> result = new List<Map<String, Object>>();
            for (String acct : licenseMap.keySet()) {
                result.add(new Map<String, Object>{
                    'account'      => acct,
                    'license_type' => licenseMap.get(acct),
                    'license_tier' => tierMap.get(acct)
                });
            }
            return JSON.serialize(result);
        } catch (AuraHandledException e) { throw e; }
        catch (Exception e) { throw new AuraHandledException(e.getMessage()); }
    }

    // ── Customer Compliance — Stale Production Orgs (last backup > 30 days) ────

    @AuraEnabled(cacheable=false)
    public static String getBackupStaleProdOrgs() {
        try {
            Set<String> paidNames = getActivePaidCustomerNames();
            String hogQuery = buildStaleProdOrgsQuery();
            Map<String, Object> response = PostHogService.queryPostHog('267194', hogQuery);
            List<Object> results = (List<Object>) response.get('results');
            if (results == null) results = new List<Object>();
            return JSON.serialize(parseStaleProdOrgRows(results, paidNames));
        } catch (AuraHandledException e) { throw e; }
        catch (Exception e) { throw new AuraHandledException(e.getMessage()); }
    }

    private static String buildStaleProdOrgsQuery() {
        // Inner: latest org type + last SUCCESSFUL Backup timestamp per (account, org)
        //   HAVING filters to orgs still sending Backup organizations Metrics in last 30 days,
        //   so deleted/removed orgs are excluded from the stale counts.
        // Outer: two counts — warn (30+ days) and critical (60+ days)
        // status != 'Exception' filters out failed attempts; epoch (no successes) → always stale
        return
            'SELECT account_name, ' +
            '  countIf(org_type = \'Production\' AND last_backup < now() - INTERVAL 30 DAY) AS stale_30, ' +
            '  countIf(org_type = \'Production\' AND last_backup < now() - INTERVAL 60 DAY) AS stale_60 ' +
            'FROM ( ' +
            '  SELECT ' +
            '    properties.accountName AS account_name, ' +
            '    argMaxIf(properties.organizationType, timestamp, event = \'Backup organizations Metrics\') AS org_type, ' +
            '    maxIf(timestamp, event = \'Backup\' AND properties.status != \'Exception\') AS last_backup ' +
            '  FROM events ' +
            '  WHERE (event = \'Backup organizations Metrics\' OR event = \'Backup\') ' +
            '    AND timestamp >= now() - INTERVAL 365 DAY ' +
            '    AND properties.accountName IS NOT NULL ' +
            '    AND properties.accountName != \'\' ' +
            '  GROUP BY account_name, properties.organizationName ' +
            '  HAVING maxIf(timestamp, event = \'Backup organizations Metrics\') >= now() - INTERVAL 30 DAY ' +
            ') ' +
            'GROUP BY account_name ' +
            'HAVING stale_30 > 0 ' +
            'ORDER BY stale_60 DESC, stale_30 DESC ' +
            'LIMIT 500';
    }

    private static List<Map<String, Object>> parseStaleProdOrgRows(List<Object> results, Set<String> paidNames) {
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        for (Object rowObj : results) {
            List<Object> row = (List<Object>) rowObj;
            if (row == null || row.size() < 3) continue;
            String account = row[0] != null ? String.valueOf(row[0]) : '';
            if (String.isBlank(account) || !paidNames.contains(account.toLowerCase())) continue;
            Integer stale30 = toInt(row[1]);
            Integer stale60 = toInt(row[2]);
            if (stale30 == null || stale30 <= 0) continue;
            rows.add(new Map<String, Object>{
                'account'  => account,
                'stale_30' => stale30,
                'stale_60' => stale60 != null ? stale60 : 0
            });
        }
        return rows;
    }

    // ── Customer Health Summary ──────────────────────────────────────────────

    @AuraEnabled(cacheable=false)
    public static String getBackupCustomerHealthSummary() {
        try {
            String hogQuery = buildCustomerHealthQuery();
            Map<String, Object> response = PostHogService.queryPostHog('267194', hogQuery);
            List<Object> results = (List<Object>) response.get('results');
            if (results == null) results = new List<Object>();
            return JSON.serialize(parseCustomerHealthRows(results));
        } catch (AuraHandledException e) { throw e; }
        catch (Exception e) { throw new AuraHandledException(e.getMessage()); }
    }

    private static String buildCustomerHealthQuery() {
        return
            'SELECT ' +
            '  account_name, ' +
            '  avgOrNull(data_util)  AS avg_data_util, ' +
            '  avgOrNull(file_util)  AS avg_file_util, ' +
            '  sumIf(1, data_util > 0.9)                             AS data_critical_count, ' +
            '  sumIf(1, data_util >= 0.75 AND data_util <= 0.9)      AS data_warning_count, ' +
            '  sumIf(1, file_util > 0.9)                             AS file_critical_count, ' +
            '  sumIf(1, file_util >= 0.75 AND file_util <= 0.9)      AS file_warning_count, ' +
            '  count() AS orgs_with_data ' +
            'FROM ( ' +
            '  SELECT ' +
            '    properties.accountName      AS account_name, ' +
            '    properties.organizationName AS org_name, ' +
            '    argMax( ' +
            '      if(toFloat64OrZero(toString(properties.dataStorageUsed)) + toFloat64OrZero(toString(properties.dataStorageAvailable)) > 0, ' +
            '         toFloat64OrZero(toString(properties.dataStorageUsed)) / ' +
            '         (toFloat64OrZero(toString(properties.dataStorageUsed)) + toFloat64OrZero(toString(properties.dataStorageAvailable))), ' +
            '         null), ' +
            '      timestamp ' +
            '    ) AS data_util, ' +
            '    argMax( ' +
            '      if(toFloat64OrZero(toString(properties.fileStorageUsed)) + toFloat64OrZero(toString(properties.fileStorageAvailable)) > 0, ' +
            '         toFloat64OrZero(toString(properties.fileStorageUsed)) / ' +
            '         (toFloat64OrZero(toString(properties.fileStorageUsed)) + toFloat64OrZero(toString(properties.fileStorageAvailable))), ' +
            '         null), ' +
            '      timestamp ' +
            '    ) AS file_util ' +
            '  FROM events ' +
            '  WHERE event = \'Report organization analytics\' ' +
            '    AND timestamp >= now() - INTERVAL 365 DAY ' +
            '    AND properties.accountName IS NOT NULL ' +
            '    AND properties.accountName != \'\' ' +
            '  GROUP BY account_name, org_name ' +
            ') ' +
            'GROUP BY account_name ' +
            'ORDER BY avg_data_util DESC NULLS LAST ' +
            'LIMIT 500';
    }

    private static List<Map<String, Object>> parseCustomerHealthRows(List<Object> results) {
        List<Map<String, Object>> rows = new List<Map<String, Object>>();
        for (Object rowObj : results) {
            List<Object> row = (List<Object>) rowObj;
            if (row == null || row.size() < 8) continue;
            String account = row[0] != null ? String.valueOf(row[0]) : '';
            if (String.isBlank(account)) continue;
            // Don't filter by paid names here — the JS join against backupAllRowsBase already
            // limits display to paid customers, and strict name matching would drop valid data
            Decimal avgDataUtil  = toDec(row[1]);
            Decimal avgFileUtil  = toDec(row[2]);
            Integer dataCritical = toInt(row[3]);
            Integer dataWarning  = toInt(row[4]);
            Integer fileCritical = toInt(row[5]);
            Integer fileWarning  = toInt(row[6]);
            Integer orgsWithData = toInt(row[7]);
            rows.add(new Map<String, Object>{
                'account'        => account,
                'avg_data_util'  => avgDataUtil,
                'avg_file_util'  => avgFileUtil,
                'data_critical'  => dataCritical,
                'data_warning'   => dataWarning,
                'file_critical'  => fileCritical,
                'file_warning'   => fileWarning,
                'orgs_with_data' => orgsWithData
            });
        }
        return rows;
    }

    // ── Who Uses What — cross-product adoption view ──────────────────────────

    @AuraEnabled(cacheable=false)
    public static String getCrossProductUsage(Integer days) {
        try {
            if (days == null) days = 90;
            String interval = String.valueOf(days);
            Set<String> paidNames = getActivePaidCustomerNames();

            Map<String, Map<String, Object>> acctMap = new Map<String, Map<String, Object>>();

            // ── Query 1: Native Apps (project 259525) ────────────────────────
            String nativeFilter = buildPaidCustomerFilter('properties.account_name', paidNames);
            String nativeQ =
                'SELECT properties.account_name AS account, ' +
                '  count(DISTINCT distinct_id) AS users, count() AS events ' +
                'FROM events ' +
                'WHERE timestamp >= now() - INTERVAL ' + interval + ' DAY ' +
                '  AND properties.account_name IS NOT NULL ' +
                '  AND properties.account_name != \'\' ' +
                nativeFilter +
                'GROUP BY account ORDER BY events DESC LIMIT 1000';

            Map<String, Object> nr = PostHogService.queryPostHog('259525', nativeQ);
            List<Object> nativeRows = (List<Object>) nr.get('results');
            if (nativeRows != null) {
                for (Object rowObj : nativeRows) {
                    List<Object> row = (List<Object>) rowObj;
                    if (row == null || row.size() < 3) continue;
                    String acct = row[0] != null ? String.valueOf(row[0]).trim() : '';
                    if (String.isBlank(acct) || isFlosumInternal(acct)) continue;
                    acctMap.put(acct.toLowerCase(), new Map<String, Object>{
                        'account'             => acct,
                        'native_users'        => toInt(row[1]),
                        'native_events'       => toInt(row[2]),
                        'cloud_devops_users'  => 0, 'cloud_devops_events' => 0,
                        'ba_users'            => 0, 'ba_events'           => 0,
                        'dm_users'            => 0, 'dm_events'           => 0
                    });
                }
            }

            // ── Query 2: Cloud Apps — DevOps + B&A + Data Migrator ───────────
            String cloudFilter = buildPaidCustomerFilter('properties.accountName', paidNames);
            String cloudQ =
                'SELECT properties.accountName AS account, properties.application AS app, ' +
                '  count(DISTINCT distinct_id) AS users, count() AS events ' +
                'FROM events ' +
                'WHERE timestamp >= now() - INTERVAL ' + interval + ' DAY ' +
                '  AND properties.accountName IS NOT NULL ' +
                '  AND properties.accountName != \'\' ' +
                '  AND properties.application IN (\'DevOps\', \'Backup&Archive\', \'Data Migrator\') ' +
                cloudFilter +
                'GROUP BY account, app ORDER BY account, events DESC LIMIT 3000';

            Map<String, Object> cr = PostHogService.queryPostHog('267194', cloudQ);
            List<Object> cloudRows = (List<Object>) cr.get('results');
            if (cloudRows != null) {
                for (Object rowObj : cloudRows) {
                    List<Object> row = (List<Object>) rowObj;
                    if (row == null || row.size() < 4) continue;
                    String acct = row[0] != null ? String.valueOf(row[0]).trim() : '';
                    String app  = row[1] != null ? String.valueOf(row[1]) : '';
                    if (String.isBlank(acct) || isFlosumInternal(acct)) continue;
                    String key = acct.toLowerCase();
                    if (!acctMap.containsKey(key)) {
                        acctMap.put(key, new Map<String, Object>{
                            'account'             => acct,
                            'native_users'        => 0, 'native_events'       => 0,
                            'cloud_devops_users'  => 0, 'cloud_devops_events' => 0,
                            'ba_users'            => 0, 'ba_events'           => 0,
                            'dm_users'            => 0, 'dm_events'           => 0
                        });
                    }
                    Map<String, Object> entry = acctMap.get(key);
                    Integer u = toInt(row[2]);
                    Integer e = toInt(row[3]);
                    if (app == 'DevOps') {
                        entry.put('cloud_devops_users',  u);
                        entry.put('cloud_devops_events', e);
                    } else if (app == 'Backup&Archive') {
                        entry.put('ba_users',  u);
                        entry.put('ba_events', e);
                    } else if (app == 'Data Migrator') {
                        entry.put('dm_users',  u);
                        entry.put('dm_events', e);
                    }
                }
            }

            // ── Compute derived fields ────────────────────────────────────────
            List<Map<String, Object>> result = new List<Map<String, Object>>();
            for (Map<String, Object> entry : acctMap.values()) {
                Integer nU  = (Integer) entry.get('native_users');
                Integer cdU = (Integer) entry.get('cloud_devops_users');
                Integer baU = (Integer) entry.get('ba_users');
                Integer dmU = (Integer) entry.get('dm_users');
                Integer productCount = (nU > 0 ? 1 : 0) + (cdU > 0 ? 1 : 0)
                                     + (baU > 0 ? 1 : 0) + (dmU > 0 ? 1 : 0);
                Integer maxUsers  = Math.max(nU, Math.max(cdU, Math.max(baU, dmU)));
                Integer totalEvts = (Integer) entry.get('native_events')
                                  + (Integer) entry.get('cloud_devops_events')
                                  + (Integer) entry.get('ba_events')
                                  + (Integer) entry.get('dm_events');
                entry.put('product_count', productCount);
                entry.put('total_users',   maxUsers);
                entry.put('total_events',  totalEvts);
                entry.put('cohort',        getCohort(maxUsers));
                result.add(entry);
            }

            return JSON.serialize(result);
        } catch (AuraHandledException e) { throw e; }
        catch (Exception e) { throw new AuraHandledException(e.getMessage()); }
    }

    // ── Who Uses What — user-level drill-down for a single account ───────────

    @AuraEnabled(cacheable=false)
    public static String getCrossProductUserDetail(String accountName, Integer days) {
        try {
            if (String.isBlank(accountName)) throw auraEx('accountName is required');
            if (days == null) days = 90;
            String interval  = String.valueOf(days);
            String safeAcct  = accountName.toLowerCase().replace('\'', '\\\'');

            Map<String, Map<String, Object>> userMap = new Map<String, Map<String, Object>>();

            // ── Native Apps ───────────────────────────────────────────────────
            String nativeQ =
                'SELECT distinct_id AS usr, count() AS events ' +
                'FROM events ' +
                'WHERE timestamp >= now() - INTERVAL ' + interval + ' DAY ' +
                '  AND lower(properties.account_name) = \'' + safeAcct + '\' ' +
                'GROUP BY usr ORDER BY events DESC LIMIT 100';

            Map<String, Object> nr = PostHogService.queryPostHog('259525', nativeQ);
            List<Object> nativeRows = (List<Object>) nr.get('results');
            if (nativeRows != null) {
                for (Object rowObj : nativeRows) {
                    List<Object> row = (List<Object>) rowObj;
                    if (row == null || row.size() < 2) continue;
                    String usr = row[0] != null ? String.valueOf(row[0]).trim() : '';
                    if (String.isBlank(usr)) continue;
                    userMap.put(usr, new Map<String, Object>{
                        'user' => usr,
                        'native_events'       => toInt(row[1]),
                        'cloud_devops_events' => 0,
                        'ba_events'           => 0,
                        'dm_events'           => 0
                    });
                }
            }

            // ── Cloud Apps (all 3 products) ───────────────────────────────────
            String cloudQ =
                'SELECT distinct_id AS usr, properties.application AS app, count() AS events ' +
                'FROM events ' +
                'WHERE timestamp >= now() - INTERVAL ' + interval + ' DAY ' +
                '  AND lower(properties.accountName) = \'' + safeAcct + '\' ' +
                '  AND properties.application IN (\'DevOps\', \'Backup&Archive\', \'Data Migrator\') ' +
                'GROUP BY usr, app ORDER BY usr, events DESC LIMIT 500';

            Map<String, Object> cr = PostHogService.queryPostHog('267194', cloudQ);
            List<Object> cloudRows = (List<Object>) cr.get('results');
            if (cloudRows != null) {
                for (Object rowObj : cloudRows) {
                    List<Object> row = (List<Object>) rowObj;
                    if (row == null || row.size() < 3) continue;
                    String usr = row[0] != null ? String.valueOf(row[0]).trim() : '';
                    String app = row[1] != null ? String.valueOf(row[1]) : '';
                    if (String.isBlank(usr)) continue;
                    if (!userMap.containsKey(usr)) {
                        userMap.put(usr, new Map<String, Object>{
                            'user' => usr,
                            'native_events' => 0, 'cloud_devops_events' => 0,
                            'ba_events' => 0, 'dm_events' => 0
                        });
                    }
                    Map<String, Object> entry = userMap.get(usr);
                    Integer e = toInt(row[2]);
                    if (app == 'DevOps')          entry.put('cloud_devops_events', e);
                    else if (app == 'Backup&Archive') entry.put('ba_events', e);
                    else if (app == 'Data Migrator')  entry.put('dm_events', e);
                }
            }

            // ── Totals ────────────────────────────────────────────────────────
            List<Map<String, Object>> result = new List<Map<String, Object>>();
            for (Map<String, Object> entry : userMap.values()) {
                Integer nE  = (Integer) entry.get('native_events');
                Integer cdE = (Integer) entry.get('cloud_devops_events');
                Integer baE = (Integer) entry.get('ba_events');
                Integer dmE = (Integer) entry.get('dm_events');
                entry.put('total_events', nE + cdE + baE + dmE);
                result.add(entry);
            }
            return JSON.serialize(result);
        } catch (AuraHandledException e) { throw e; }
        catch (Exception e) { throw new AuraHandledException(e.getMessage()); }
    }

    // ── Who Uses What — new tenant registrations ─────────────────────────────

    @AuraEnabled(cacheable=false)
    public static String getNewTenants(Integer days) {
        try {
            if (days == null) days = 90;
            String interval = String.valueOf(days);

            // No paidNames filter here — tenant events may predate the account
            // being marked as a paid customer, and the accountName property may
            // not be present on all create events.

            List<Map<String, Object>> result = new List<Map<String, Object>>();

            // Helper: process rows from either project
            // col layout: account(0), usr(1), first_seen(2), country(3), country_code(4), city(5)
            String selectCols =
                '  formatDateTime(min(timestamp), \'%Y-%m-%d\') AS first_seen, ' +
                '  any(properties.$geoip_country_name) AS country, ' +
                '  any(properties.$geoip_country_code) AS country_code, ' +
                '  any(properties.$geoip_city_name) AS city ';

            // ── Cloud project (267194) — accountName property ─────────────────
            String cloudQ =
                'SELECT ' +
                '  coalesce(properties.accountName, \'\') AS account, ' +
                '  distinct_id AS usr, ' +
                selectCols +
                'FROM events ' +
                'WHERE event ilike \'%tenant%create%\' ' +
                '  AND timestamp >= now() - INTERVAL ' + interval + ' DAY ' +
                'GROUP BY account, usr ' +
                'ORDER BY min(timestamp) DESC LIMIT 500';

            try {
                Map<String, Object> cr = PostHogService.queryPostHog('267194', cloudQ);
                List<Object> cloudRows = (List<Object>) cr.get('results');
                if (cloudRows != null) processNewTenantRows(cloudRows, result);
            } catch (Exception ex) { /* project may have no matching events */ }

            // ── Native project (259525) — account_name property ───────────────
            String nativeQ =
                'SELECT ' +
                '  coalesce(properties.account_name, \'\') AS account, ' +
                '  distinct_id AS usr, ' +
                selectCols +
                'FROM events ' +
                'WHERE event ilike \'%tenant%create%\' ' +
                '  AND timestamp >= now() - INTERVAL ' + interval + ' DAY ' +
                'GROUP BY account, usr ' +
                'ORDER BY min(timestamp) DESC LIMIT 500';

            try {
                Map<String, Object> nr = PostHogService.queryPostHog('259525', nativeQ);
                List<Object> nativeRows = (List<Object>) nr.get('results');
                if (nativeRows != null) processNewTenantRows(nativeRows, result);
            } catch (Exception ex) { /* project may have no matching events */ }

            // If still empty, run a discovery query so the caller knows the actual event name
            if (result.isEmpty()) {
                result.add(new Map<String, Object>{
                    'account'    => '__diagnostic__',
                    'user'       => discoverTenantEventNames(interval),
                    'domain'     => '',
                    'first_seen' => '',
                    'country'    => '',
                    'country_code' => '',
                    'city'       => ''
                });
            }

            return JSON.serialize(result);
        } catch (AuraHandledException e) { throw e; }
        catch (Exception e) { throw new AuraHandledException(e.getMessage()); }
    }

    private static void processNewTenantRows(List<Object> rows, List<Map<String, Object>> result) {
        for (Object rowObj : rows) {
            List<Object> row = (List<Object>) rowObj;
            if (row == null || row.size() < 4) continue;
            String acct = row[0] != null ? String.valueOf(row[0]).trim() : '';
            String usr  = row[1] != null ? String.valueOf(row[1]).trim() : '';
            if (isFlosumInternal(acct) || isFlosumInternal(usr)) continue;
            String domain = '';
            if (usr.contains('@')) domain = usr.substring(usr.indexOf('@') + 1);
            result.add(new Map<String, Object>{
                'account'      => acct,
                'user'         => usr,
                'domain'       => domain,
                'first_seen'   => row[2] != null ? String.valueOf(row[2]) : '',
                'country'      => row[3] != null ? String.valueOf(row[3]) : '',
                'country_code' => row[4] != null ? String.valueOf(row[4]) : '',
                'city'         => row[5] != null ? String.valueOf(row[5]) : ''
            });
        }
    }

    private static String discoverTenantEventNames(String interval) {
        // Returns a comma-separated list of event names that could relate to
        // tenant/org creation so we can pinpoint the correct event name.
        try {
            String q =
                'SELECT event, count() AS cnt ' +
                'FROM events ' +
                'WHERE (event ilike \'%tenant%\' OR event ilike \'%register%\' ' +
                '        OR event ilike \'%signup%\' OR event ilike \'%provision%\' ' +
                '        OR event ilike \'%onboard%\') ' +
                '  AND timestamp >= now() - INTERVAL ' + interval + ' DAY ' +
                'GROUP BY event ORDER BY cnt DESC LIMIT 20';
            Map<String, Object> resp = PostHogService.queryPostHog('267194', q);
            List<Object> rows = (List<Object>) resp.get('results');
            List<String> names = new List<String>();
            if (rows != null) {
                for (Object r : rows) {
                    List<Object> row = (List<Object>) r;
                    if (row != null && row[0] != null) names.add(String.valueOf(row[0]));
                }
            }
            return names.isEmpty() ? 'no matching events found in cloud project' : String.join(names, ', ');
        } catch (Exception e) {
            return 'discovery error: ' + e.getMessage();
        }
    }
}
