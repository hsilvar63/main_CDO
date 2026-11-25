import { LightningElement, api, track } from 'lwc';
import getCustomerUsage    from '@salesforce/apex/PostHogController.getCustomerUsage';
import getUsageTrends      from '@salesforce/apex/PostHogController.getUsageTrends';
import getOrgSummary       from '@salesforce/apex/PostHogController.getOrgSummary';
import getBackupOrgSummary       from '@salesforce/apex/PostHogController.getBackupOrgSummary';
import getBackupOrgDetail        from '@salesforce/apex/PostHogController.getBackupOrgDetail';
import getBackupExceptionSummary  from '@salesforce/apex/PostHogController.getBackupExceptionSummary';
import getBackupOrgExceptions     from '@salesforce/apex/PostHogController.getBackupOrgExceptions';
import getBackupActiveUserSummary from '@salesforce/apex/PostHogController.getBackupActiveUserSummary';
import getBackupUserDetail        from '@salesforce/apex/PostHogController.getBackupUserDetail';
import getBackupAllOrgsByType   from '@salesforce/apex/PostHogController.getBackupAllOrgsByType';
import getBackupLicenseTypes    from '@salesforce/apex/PostHogController.getBackupLicenseTypes';
import getBackupStaleProdOrgs   from '@salesforce/apex/PostHogController.getBackupStaleProdOrgs';
import getCrossProductUsage     from '@salesforce/apex/PostHogController.getCrossProductUsage';
import getCrossProductUserDetail from '@salesforce/apex/PostHogController.getCrossProductUserDetail';
import getNewTenants             from '@salesforce/apex/PostHogController.getNewTenants';

// ─── Constants ────────────────────────────────────────────────────────────────

const PRODUCTS = [
    { key: 'native_apps',    label: 'Native DevOps'    },
    { key: 'cloud_devops',   label: 'Cloud DevOps'     },
    { key: 'backup_archive', label: 'Backup & Archive'  },
    { key: 'data_migrator',  label: 'Data Migrator'    },
    { key: 'who_uses_what',  label: 'Who Uses What'    }
];

const TIME_RANGES = [
    { days: 30,  label: '30d'  },
    { days: 60,  label: '60d'  },
    { days: 90,  label: '90d'  },
    { days: 180, label: '180d' },
    { days: 365, label: '1 yr' }
];

const COHORT_ORDER  = ['Enterprise', 'Growth', 'Emerging', 'Early Stage'];
const COHORT_COLORS = {
    'Enterprise'  : '#FF355E',
    'Growth'      : '#1E3A8A',
    'Emerging'    : '#7C2D5C',
    'Early Stage' : '#94A3B8'
};



// ─── Helper ───────────────────────────────────────────────────────────────────

function fmt(n) {
    if (n == null) return '0';
    if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
    if (n >= 1000)    return (n / 1000).toFixed(1) + 'K';
    return String(n);
}

// ─── Component ────────────────────────────────────────────────────────────────

export default class FlosumUsageDashboard extends LightningElement {

    // Designer properties (configurable in App Builder)
    @api defaultProduct = 'native_apps';
    @api defaultDays    = 90;

    // Selections
    @track selectedProduct;
    @track selectedDays;

    // Data
    @track rawData          = [];
    @track filteredData     = [];
    @track isLoading        = false;
    @track error            = null;

    // Table state
    @track searchTerm       = '';
    @track selectedCohort   = 'All';
    @track sortField        = 'users';
    @track sortAsc          = false;

    // Account detail modal
    @track acctModalAccount    = null;
    @track acctModalProduct    = null;
    @track isAccountModalOpen  = false;

    // Trend data
    @track trendData        = null;
    @track trendLoading     = false;
    @track expandedChart    = null;

    // Org data
    @track orgSummaryMap    = {};

    // Backup & Archive subtab data
    @track selectedBackupTab         = 'org_inventory';
    @track backupOrgSummary          = [];
    @track backupExceptionSummary    = [];
    @track backupActiveUserSummary   = [];
    @track backupLicenseTypes              = [];
    @track backupStaleProdOrgsSummary      = [];
    @track backupComplianceUrgencyFilter   = null; // 'Critical' | 'Warning' | 'Healthy' | null
    @track backupComplianceSignalFilter    = null; // '_sig_stale60' | '_sig_zeroUsers' | etc.
    @track complianceSignalPopupOpen       = false;
    @track complianceSignalPopupLabel      = '';
    @track complianceSignalPopupData       = [];
    @track backupSummaryLoading      = false;
    @track backupSearchTerm       = '';
    @track backupShowSuggestions  = false;
    @track backupPageSize         = 10;
    @track backupCurrentPage      = 1;
    @track backupSortField        = null;
    @track backupSortAsc          = false;

    // Org detail popup
    @track orgDetailOpen    = false;
    @track orgDetailAccount = null;
    @track orgDetailRows    = [];
    @track orgExDetailRows  = [];
    @track userDetailRows   = [];
    @track orgDetailLoading = false;
    _bkChartBarMap          = [];
    _bkDonutSegmentMap      = [];

    // Donut org-type detail popup
    @track donutOrgDetailOpen    = false;
    @track donutOrgTypeFilter    = null;
    @track donutSingleAccount    = null; // set when popup is for a single filtered account
    @track donutOrgDetailRows    = [];
    @track donutOrgDetailLoading = false;

    get donutOrgDetailTitle() {
        if (!this.donutOrgTypeFilter) return '';
        const typeName = this.donutOrgTypeFilter === 'Production' ? 'Production' : 'Sandbox';
        return this.donutSingleAccount
            ? `${this.donutSingleAccount} — ${typeName} Orgs`
            : `${typeName} Orgs — All Accounts`;
    }

    get donutOrgDetailDisplayRows() {
        const isEpoch = d => !d || d.startsWith('1970');
        let rows = this.donutOrgDetailRows;
        // single-account data comes from getBackupOrgDetail (all org types) — filter here
        if (this.donutSingleAccount && this.donutOrgTypeFilter) {
            rows = rows.filter(r => this.donutOrgTypeFilter === 'Production'
                ? r.org_type === 'Production'
                : r.org_type !== 'Production'
            );
        }
        return rows.map((r, i) => {
            const bkMb        = r.backup_mb        || 0;
            const arMb        = r.archive_mb       || 0;
            const sfDataUsed  = r.sf_data_mb_used  || 0;
            const sfDataAvail = r.sf_data_mb_avail || 0;
            const sfFileUsed  = r.sf_file_mb_used  || 0;
            const sfFileAvail = r.sf_file_mb_avail || 0;
            const lastOp      = isEpoch(r.last_operation_date) ? '' : r.last_operation_date;
            const lastBk      = isEpoch(r.last_backup_date) ? '' : r.last_backup_date;
            const isZombie    = (r.backups  || 0) > 0
                              && !lastBk
                              && (r.archives || 0) === 0
                              && (r.restores || 0) === 0
                              && (r.exports  || 0) === 0;
            return {
                ...r,
                rowKey           : `${r.account_name || this.donutSingleAccount}::${r.org_name}`,
                account_name     : r.account_name || this.donutSingleAccount,
                backup_gb        : bkMb       > 0 ? (bkMb       / 1024).toFixed(2) : '0.00',
                archive_gb       : arMb       > 0 ? (arMb       / 1024).toFixed(2) : '0.00',
                sf_data_used_gb  : sfDataUsed  > 0 ? (sfDataUsed  / 1024).toFixed(2) : '—',
                sf_data_avail_gb : sfDataAvail > 0 ? (sfDataAvail / 1024).toFixed(2) : '—',
                sf_file_used_gb  : sfFileUsed  > 0 ? (sfFileUsed  / 1024).toFixed(2) : '—',
                sf_file_avail_gb : sfFileAvail > 0 ? (sfFileAvail / 1024).toFixed(2) : '—',
                sf_edition       : r.sf_edition || '',
                total_ops        : (r.backups || 0) + (r.archives || 0) + (r.restores || 0) + (r.exports || 0),
                last_op          : lastOp,
                last_op_class    : lastOp ? 'date-cell' : 'date-cell date-never',
                is_zombie        : isZombie,
                typeClass        : r.org_type === 'Production'
                                   ? 'org-type-badge org-type-prod'
                                   : 'org-type-badge org-type-sandbox',
                rowClass         : i % 2 === 0 ? 'row-even' : 'row-odd'
            };
        });
    }

    // Cross-product (Who Uses What) state
    @track crossProductData    = [];
    @track cpLoading           = false;
    @track cpSearchTerm        = '';
    @track cpSortField         = 'product_count';
    @track cpSortAsc           = false;
    @track cpSelectedTab       = 'product_adoption';
    // User Activity tab
    @track cpFocusedAccount    = null;
    @track cpUserDetailData    = [];
    @track cpUserDetailLoading = false;
    // New Tenants tab
    @track newTenantsData      = [];
    @track newTenantsLoading   = false;
    @track ntSearchTerm        = '';
    @track ntSortField         = 'first_seen';
    @track ntSortAsc           = false;
    @track ntError             = null;
    @track ntDiagnostic        = null;

    get isCrossProduct()           { return this.selectedProduct === 'who_uses_what'; }
    get isCpProductAdoptionTab()   { return this.cpSelectedTab === 'product_adoption'; }
    get isCpUserActivityTab()      { return this.cpSelectedTab === 'user_activity';    }
    get isCpNewTenantsTab()        { return this.cpSelectedTab === 'new_tenants';      }

    get cpSubtabs() {
        const tabs = [
            { key: 'product_adoption', label: 'Product Adoption' },
            { key: 'user_activity',    label: 'User Activity'    },
            { key: 'new_tenants',      label: 'New Tenants'      }
        ];
        return tabs.map(t => ({
            ...t,
            cssClass: 'cp-tab-btn' + (t.key === this.cpSelectedTab ? ' cp-tab-btn--active' : '')
        }));
    }

    get cpStats() {
        const d = this.crossProductData;
        const total  = d.length;
        const nativeN = d.filter(r => r.native_users       > 0).length;
        const cloudN  = d.filter(r => r.cloud_devops_users > 0).length;
        const baN     = d.filter(r => r.ba_users           > 0).length;
        const dmN     = d.filter(r => r.dm_users           > 0).length;
        const multiN  = d.filter(r => r.product_count      > 1).length;
        const pct = n => total > 0 ? Math.round(n / total * 100) + '%' : '0%';
        return { total, nativeN, cloudN, baN, dmN, multiN,
                 nativePct: pct(nativeN), cloudPct: pct(cloudN),
                 baPct: pct(baN), dmPct: pct(dmN), multiPct: pct(multiN) };
    }

    get crossProductDisplayRows() {
        let data = [...this.crossProductData];
        if (this.cpSearchTerm) {
            const s = this.cpSearchTerm.toLowerCase();
            data = data.filter(r => r.account.toLowerCase().includes(s));
        }
        const sf   = this.cpSortField;
        const sign = this.cpSortAsc ? 1 : -1;
        data.sort((a, b) => {
            const va = typeof a[sf] === 'string' ? a[sf].toLowerCase() : (a[sf] ?? 0);
            const vb = typeof b[sf] === 'string' ? b[sf].toLowerCase() : (b[sf] ?? 0);
            return va < vb ? -sign : va > vb ? sign : 0;
        });
        return data.map((r, i) => {
            const tot = r.total_events || 1;
            const evPct = e => e > 0 ? Math.round(e / tot * 100) + '%' : '0%';
            const pill  = (users, evts) => users > 0 ? `${users} users · ${evPct(evts)}` : '';
            return {
                ...r,
                rowClass              : i % 2 === 0 ? 'row-even' : 'row-odd',
                is_focused            : r.account === this.cpFocusedAccount,
                has_native            : r.native_users       > 0,
                has_cloud_devops      : r.cloud_devops_users > 0,
                has_ba                : r.ba_users           > 0,
                has_dm                : r.dm_users           > 0,
                native_display        : pill(r.native_users,       r.native_events),
                cloud_devops_display  : pill(r.cloud_devops_users, r.cloud_devops_events),
                ba_display            : pill(r.ba_users,           r.ba_events),
                dm_display            : pill(r.dm_users,           r.dm_events),
                total_events_display  : fmt(r.total_events),
                product_count_class   : `cp-count cp-count--${r.product_count}`
            };
        });
    }

    get cpUserDetailDisplayRows() {
        let data = [...this.cpUserDetailData];
        data.sort((a, b) => (b.total_events || 0) - (a.total_events || 0));
        return data.map((r, i) => {
            const tot = r.total_events || 1;
            const pct = e => e > 0 ? Math.round(e / tot * 100) + '%' : '';
            const cell = (e) => e > 0 ? `${fmt(e)} (${pct(e)})` : '—';
            return {
                ...r,
                rowClass              : i % 2 === 0 ? 'row-even' : 'row-odd',
                native_cell           : cell(r.native_events),
                cloud_devops_cell     : cell(r.cloud_devops_events),
                ba_cell               : cell(r.ba_events),
                dm_cell               : cell(r.dm_events),
                total_events_display  : fmt(r.total_events)
            };
        });
    }

    get newTenantsDisplayRows() {
        let data = [...this.newTenantsData];
        if (this.ntSearchTerm) {
            const s = this.ntSearchTerm.toLowerCase();
            data = data.filter(r =>
                (r.account || '').toLowerCase().includes(s) ||
                (r.user    || '').toLowerCase().includes(s) ||
                (r.domain  || '').toLowerCase().includes(s) ||
                (r.country || '').toLowerCase().includes(s)
            );
        }
        const sf   = this.ntSortField;
        const sign = this.ntSortAsc ? 1 : -1;
        data.sort((a, b) => {
            const va = typeof a[sf] === 'string' ? a[sf].toLowerCase() : (a[sf] ?? '');
            const vb = typeof b[sf] === 'string' ? b[sf].toLowerCase() : (b[sf] ?? '');
            return va < vb ? -sign : va > vb ? sign : 0;
        });
        return data.map((r, i) => ({ ...r, rowClass: i % 2 === 0 ? 'row-even' : 'row-odd' }));
    }

    get newTenantsRegionRows() {
        const map = {};
        this.newTenantsData.forEach(r => {
            const c = r.country || 'Unknown';
            map[c] = (map[c] || 0) + 1;
        });
        return Object.entries(map)
            .map(([country, count]) => ({ country, count }))
            .sort((a, b) => b.count - a.count)
            .slice(0, 15);
    }

    get ntTotalTenants() { return this.newTenantsData.length; }
    get ntTopCountry()   {
        const rows = this.newTenantsRegionRows;
        return rows.length > 0 ? rows[0].country : '—';
    }

    // Lifecycle
    connectedCallback() {
        this.selectedProduct = this.defaultProduct || 'native_apps';
        this.selectedDays    = this.defaultDays    || 90;
        this.loadData();
    }

    renderedCallback() {
        if (!this.isLoading && this.filteredData.length > 0) {
            this._drawCharts();
        }
        if (this.isBackupArchive && !this.backupSummaryLoading) {
            try { this._drawBackupActiveChart(); } catch(e) { /* silent */ }
            try { this._drawBreakdownDonut();    } catch(e) { /* silent */ }
        }
        if (this.isModalOpen && this.trendData) {
            try { this._drawModalChart(); } catch(e) { /* silent */ }
        }
    }

    // ── Data loading ────────────────────────────────────────────────────────

    loadData() {
        // Cross-product view has its own loader — skip the standard queries
        if (this.selectedProduct === 'who_uses_what') {
            this.rawData      = [];
            this.filteredData = [];
            this.trendData    = null;
            this.isLoading    = false;
            this.trendLoading = false;
            this._loadCrossProduct();
            return;
        }

        this.isLoading    = true;
        this.trendLoading = true;
        this.error        = null;
        this.trendData    = null;

        getCustomerUsage({ productKey: this.selectedProduct, days: this.selectedDays })
            .then(json => {
                this.rawData   = JSON.parse(json);
                this._applyFilters();
                this.isLoading = false;
            })
            .catch(err => {
                this.error     = err.body?.message ?? err.message ?? 'Unknown error';
                this.isLoading = false;
            });

        getUsageTrends({ productKey: this.selectedProduct, days: this.selectedDays })
            .then(json => {
                this.trendData    = JSON.parse(json);
                this.trendLoading = false;
            })
            .catch(() => { this.trendLoading = false; });

        getOrgSummary({ productKey: this.selectedProduct, days: this.selectedDays })
            .then(json => { try { this.orgSummaryMap = JSON.parse(json) || {}; } catch(e) { /**/ } })
            .catch(() => {});

        if (this.selectedProduct === 'backup_archive') {
            this.backupSummaryLoading      = true;
            this.backupOrgSummary          = [];
            this.backupExceptionSummary    = [];
            this.backupActiveUserSummary   = [];
            this.backupLicenseTypes        = [];
            this.backupStaleProdOrgsSummary = [];
            getBackupOrgSummary()
                .then(json => {
                    this.backupOrgSummary     = JSON.parse(json) || [];
                    this.backupSummaryLoading = false;
                })
                .catch(() => { this.backupSummaryLoading = false; });
            getBackupExceptionSummary()
                .then(json => { this.backupExceptionSummary = JSON.parse(json) || []; })
                .catch(() => {});
            getBackupActiveUserSummary()
                .then(json => { this.backupActiveUserSummary = JSON.parse(json) || []; })
                .catch(() => {});
            getBackupLicenseTypes()
                .then(json => { this.backupLicenseTypes = JSON.parse(json) || []; })
                .catch(() => {});
            getBackupStaleProdOrgs()
                .then(json => { this.backupStaleProdOrgsSummary = JSON.parse(json) || []; })
                .catch(() => {});
        } else {
            this.backupOrgSummary        = [];
            this.backupExceptionSummary  = [];
            this.backupActiveUserSummary = [];
            this.backupLicenseTypes          = [];
            this.backupStaleProdOrgsSummary  = [];
            this.backupSummaryLoading    = false;
        }
    }

    // ── Filter / sort ────────────────────────────────────────────────────────

    _applyFilters() {
        let data = [...this.rawData];

        // Search
        if (this.searchTerm) {
            const s = this.searchTerm.toLowerCase();
            data = data.filter(r => r.account.toLowerCase().includes(s));
        }

        // Cohort
        if (this.selectedCohort !== 'All') {
            data = data.filter(r => r.cohort === this.selectedCohort);
        }

        // Sort
        const sf   = this.sortField;
        const sign = this.sortAsc ? 1 : -1;
        data.sort((a, b) => {
            const va = typeof a[sf] === 'string' ? a[sf].toLowerCase() : (a[sf] ?? 0);
            const vb = typeof b[sf] === 'string' ? b[sf].toLowerCase() : (b[sf] ?? 0);
            if (va < vb) return -1 * sign;
            if (va > vb) return  1 * sign;
            return 0;
        });

        this.filteredData = data;
    }

    // ── Computed getters: controls ──────────────────────────────────────────

    get productButtons() {
        return PRODUCTS.map(p => ({
            ...p,
            cssClass: 'seg-btn' + (p.key === this.selectedProduct ? ' seg-btn--active' : '')
        }));
    }

    get timeRangeButtons() {
        return TIME_RANGES.map((t, i) => ({
            ...t,
            id: i,
            cssClass: 'seg-btn' + (t.days === this.selectedDays ? ' seg-btn--active' : '')
        }));
    }

    get isNativeApps()    { return this.selectedProduct === 'native_apps';    }
    get isCloudDevops()   { return this.selectedProduct === 'cloud_devops';   }
    get isBackupArchive() { return this.selectedProduct === 'backup_archive'; }
    get isDataMigrator()  { return this.selectedProduct === 'data_migrator';  }

    // ── Org detail popup getters ─────────────────────────────────────────────

    get orgDetailTitle() {
        if (!this.orgDetailAccount) return '';
        const tab = this.isBackupOrgInventoryTab ? 'Org Inventory'
                  : this.isBackupStorageTab      ? 'Storage Details'
                  : this.isBackupExceptionsTab   ? 'Exception Details'
                  : this.isBackupActiveUsersTab  ? 'Active Users'
                  : 'Ops Breakdown';
        return `${this.orgDetailAccount} — ${tab}`;
    }

    get userDetailDisplayRows() {
        const isEpoch = d => !d || d.startsWith('1970');
        return this.userDetailRows.map((r, i) => {
            const lastAct = isEpoch(r.last_activity) ? '' : r.last_activity;
            return {
                ...r,
                last_activity  : lastAct,
                last_act_class : lastAct ? 'date-cell' : 'date-cell date-never',
                rowClass       : i % 2 === 0 ? 'row-even' : 'row-odd'
            };
        });
    }

    get orgDetailDisplayRows() {
        const isEpoch = d => !d || d.startsWith('1970');
        const now  = new Date();
        const cut30 = new Date(now); cut30.setDate(cut30.getDate() - 30);
        const cut60 = new Date(now); cut60.setDate(cut60.getDate() - 60);
        const str30 = cut30.toISOString().slice(0, 10);
        const str60 = cut60.toISOString().slice(0, 10);
        const rows = this.orgDetailRows.map(r => {
            const bkMb         = r.backup_mb        || 0;
            const arMb         = r.archive_mb       || 0;
            const storageMb    = bkMb + arMb;
            const sfDataUsed   = r.sf_data_mb_used  || 0;
            const sfDataAvail  = r.sf_data_mb_avail || 0;
            const sfFileUsed   = r.sf_file_mb_used  || 0;
            const sfFileAvail  = r.sf_file_mb_avail || 0;
            const lastOp       = isEpoch(r.last_operation_date) ? '' : r.last_operation_date;
            const lastBk       = isEpoch(r.last_backup_date) ? '' : r.last_backup_date;
            const isProd       = r.org_type === 'Production';
            // Stale-highlight only for Production orgs, matching the compliance contact reason thresholds
            const lastBkClass  = !isProd                        ? 'date-cell'
                               : (!lastBk || lastBk < str60)   ? 'date-cell stale-critical'
                               : (lastBk < str30)              ? 'date-cell stale-warning'
                               :                                  'date-cell';
            // Zombie: backup attempts exist but zero ever succeeded, and no other operation types
            const isZombie     = (r.backups  || 0) > 0
                               && !lastBk
                               && (r.archives || 0) === 0
                               && (r.restores || 0) === 0
                               && (r.exports  || 0) === 0;
            return {
                ...r,
                backup_gb        : bkMb       > 0 ? (bkMb       / 1024).toFixed(2) : '0.00',
                archive_gb       : arMb       > 0 ? (arMb       / 1024).toFixed(2) : '0.00',
                storage_gb       : storageMb  > 0 ? (storageMb  / 1024).toFixed(2) : '0.00',
                sf_data_used_gb  : sfDataUsed  > 0 ? (sfDataUsed  / 1024).toFixed(2) : '—',
                sf_data_avail_gb : sfDataAvail > 0 ? (sfDataAvail / 1024).toFixed(2) : '—',
                sf_file_used_gb  : sfFileUsed  > 0 ? (sfFileUsed  / 1024).toFixed(2) : '—',
                sf_file_avail_gb : sfFileAvail > 0 ? (sfFileAvail / 1024).toFixed(2) : '—',
                sf_edition       : r.sf_edition || '',
                total_ops        : (r.backups || 0) + (r.archives || 0) + (r.restores || 0) + (r.exports || 0),
                last_op          : lastOp,
                last_op_class    : lastOp ? 'date-cell' : 'date-cell date-never',
                last_backup_date : lastBk || '—',
                last_backup_class: lastBkClass,
                is_zombie        : isZombie,
                typeClass        : r.org_type === 'Production'
                                   ? 'org-type-badge org-type-prod'
                                   : 'org-type-badge org-type-sandbox'
            };
        });
        // Most-recently-active first; orgs with no operations fall to the bottom
        rows.sort((a, b) => {
            if (!a.last_op && !b.last_op) return 0;
            if (!a.last_op) return 1;
            if (!b.last_op) return -1;
            return b.last_op < a.last_op ? -1 : b.last_op > a.last_op ? 1 : 0;
        });
        return rows.map((r, i) => ({ ...r, rowClass: i % 2 === 0 ? 'row-even' : 'row-odd' }));
    }

    get orgExDetailDisplayRows() {
        const isEpoch  = d => !d || d.startsWith('1970');
        const rate     = (ex, tot) => tot > 0 ? ((ex / tot) * 100).toFixed(1) + '%' : '—';
        const rateCls  = (ex, tot) => {
            if (tot === 0) return 'num-cell';
            const r = ex / tot;
            if (r > 0.2)  return 'num-cell rate-danger';
            if (r > 0.05) return 'num-cell rate-warning';
            return 'num-cell';
        };
        const excCls   = n => n > 0 ? 'num-cell exception-cell' : 'num-cell';

        const rows = this.orgExDetailRows.map(r => {
            const bkEx  = r.backup_exceptions  || 0;
            const arEx  = r.archive_exceptions || 0;
            const reEx  = r.restore_exceptions || 0;
            const exEx  = r.export_exceptions  || 0;
            const srEx  = r.search_exceptions  || 0;
            const totalEx = bkEx + arEx + reEx + exEx + srEx;
            const lastEx  = isEpoch(r.last_exception_date) ? '' : r.last_exception_date;
            // Zombie: every backup attempt is an exception and no other operations ran
            const isZombie = bkEx > 0
                           && bkEx === (r.total_backups  || 0)
                           && (r.total_archives || 0) === 0
                           && (r.total_restores || 0) === 0
                           && (r.total_exports  || 0) === 0
                           && (r.total_searches || 0) === 0;
            return {
                ...r,
                is_zombie          : isZombie,
                typeClass          : r.org_type === 'Production'
                                     ? 'org-type-badge org-type-prod'
                                     : 'org-type-badge org-type-sandbox',
                backup_exc_class   : excCls(bkEx),
                archive_exc_class  : excCls(arEx),
                restore_exc_class  : excCls(reEx),
                export_exc_class   : excCls(exEx),
                search_exc_class   : excCls(srEx),
                backup_fail_rate   : rate(bkEx, r.total_backups  || 0),
                archive_fail_rate  : rate(arEx, r.total_archives || 0),
                restore_fail_rate  : rate(reEx, r.total_restores || 0),
                export_fail_rate   : rate(exEx, r.total_exports  || 0),
                search_fail_rate   : rate(srEx, r.total_searches || 0),
                backup_rate_class  : rateCls(bkEx, r.total_backups  || 0),
                archive_rate_class : rateCls(arEx, r.total_archives || 0),
                restore_rate_class : rateCls(reEx, r.total_restores || 0),
                export_rate_class  : rateCls(exEx, r.total_exports  || 0),
                search_rate_class  : rateCls(srEx, r.total_searches || 0),
                total_exceptions   : totalEx,
                total_exc_class    : totalEx > 0 ? 'num-cell bk-total-cell exception-cell' : 'num-cell bk-total-cell',
                last_exception     : lastEx,
                last_exc_class     : lastEx ? 'date-cell' : 'date-cell date-never'
            };
        });
        return rows.map((r, i) => ({ ...r, rowClass: i % 2 === 0 ? 'row-even' : 'row-odd' }));
    }

    // ── Backup subtab getters ────────────────────────────────────────────────

    get backupSubtabs() {
        return [
            { key: 'org_inventory',   label: 'Org Inventory'   },
            { key: 'storage',         label: 'Storage'         },
            { key: 'exceptions',      label: 'Exceptions'      },
            { key: 'active_users',    label: 'Active Users'    },
            { key: 'total_ops',       label: 'Total Ops'       },
            { key: 'customer_compliance', label: 'Customer Compliance' }
        ].map(t => ({
            ...t,
            cssClass: 'bk-tab-btn' + (t.key === this.selectedBackupTab ? ' bk-tab-btn--active' : '')
        }));
    }

    get isBackupOrgInventoryTab()   { return this.selectedBackupTab === 'org_inventory';   }
    get isBackupStorageTab()        { return this.selectedBackupTab === 'storage';          }
    get isBackupExceptionsTab()     { return this.selectedBackupTab === 'exceptions';       }
    get isBackupActiveUsersTab()    { return this.selectedBackupTab === 'active_users';     }
    get isBackupOpsTab()            { return this.selectedBackupTab === 'total_ops';        }
    get isBackupCustomerComplianceTab() { return this.selectedBackupTab === 'customer_compliance'; }

    get backupChartTitle() {
        const a = this.backupChartAccounts;
        const single = a && a.size === 1 ? [...a][0] : null;
        if (single) {
            if (this.isBackupOrgInventoryTab)   return `${single} — Org Inventory`;
            if (this.isBackupStorageTab)        return `${single} — Storage`;
            if (this.isBackupExceptionsTab)     return `${single} — Exceptions`;
            if (this.isBackupActiveUsersTab)    return `${single} — Active Users`;
            if (this.isBackupCustomerComplianceTab) return `${single} — Compliance Overview`;
            return `${single} — Total Ops`;
        }
        if (this.isBackupOrgInventoryTab)   return 'Top 10 Accounts by Total Orgs';
        if (this.isBackupStorageTab)        return 'Top 10 Accounts by Total Storage (Backup + Archive) GB';
        if (this.isBackupExceptionsTab)     return 'Top 10 Accounts by Total Exceptions';
        if (this.isBackupActiveUsersTab)    return 'Top 10 Accounts by Active Users';
        if (this.isBackupCustomerComplianceTab) return single ? `${single} — Active Compliance Signals` : 'Compliance Signal Distribution';
        return 'Top 10 Accounts by Total Operations';
    }

    get backupBreakdownTitle() {
        if (this.isBackupOrgInventoryTab)   return 'Production vs Sandbox';
        if (this.isBackupStorageTab)        return 'Backup vs Archive Storage';
        if (this.isBackupExceptionsTab)     return 'Exceptions by Type';
        if (this.isBackupActiveUsersTab)    return 'Users by Cohort';
        if (this.isBackupCustomerComplianceTab) return 'Compliance Status';
        return 'Operations by Type';
    }

    // Returns { label, value (numeric), display (string), color } per slice
    get backupBreakdownData() {
        if (this.isBackupOrgInventoryTab) {
            const rows = this.backupChartAllRows;
            const prod = rows.reduce((s, r) => s + (r.prod_orgs    || 0), 0);
            const sand = rows.reduce((s, r) => s + (r.sandbox_orgs || 0), 0);
            return [
                { label: 'Production', value: prod, display: prod.toLocaleString(), color: '#1E3A8A' },
                { label: 'Sandbox',    value: sand, display: sand.toLocaleString(), color: '#7C2D5C' }
            ].filter(d => d.value > 0);
        }
        if (this.isBackupStorageTab) {
            const rows = this.backupChartAllRows;
            const bkMb = rows.reduce((s, r) => s + (r.total_backup_mb  || 0), 0);
            const arMb = rows.reduce((s, r) => s + (r.total_archive_mb || 0), 0);
            return [
                { label: 'Backup',  value: bkMb, display: (bkMb / 1024).toFixed(1) + ' GB', color: '#1E3A8A' },
                { label: 'Archive', value: arMb, display: (arMb / 1024).toFixed(1) + ' GB', color: '#059669' }
            ].filter(d => d.value > 0);
        }
        if (this.isBackupExceptionsTab) {
            const rows = this.backupChartExceptionRows;
            const bkEx = rows.reduce((s, r) => s + (r.backup_exceptions  || 0), 0);
            const arEx = rows.reduce((s, r) => s + (r.archive_exceptions || 0), 0);
            const reEx = rows.reduce((s, r) => s + (r.restore_exceptions || 0), 0);
            const exEx = rows.reduce((s, r) => s + (r.export_exceptions  || 0), 0);
            const srEx = rows.reduce((s, r) => s + (r.search_exceptions  || 0), 0);
            return [
                { label: 'Backup',  value: bkEx, display: bkEx.toLocaleString(), color: '#FF355E' },
                { label: 'Archive', value: arEx, display: arEx.toLocaleString(), color: '#1E3A8A' },
                { label: 'Restore', value: reEx, display: reEx.toLocaleString(), color: '#059669' },
                { label: 'Export',  value: exEx, display: exEx.toLocaleString(), color: '#F59E0B' },
                { label: 'Search',  value: srEx, display: srEx.toLocaleString(), color: '#8B5CF6' }
            ].filter(d => d.value > 0);
        }
        if (this.isBackupActiveUsersTab) {
            const byCohort = { 'Enterprise': 0, 'Growth': 0, 'Emerging': 0, 'Early Stage': 0 };
            this.backupChartUserRows.forEach(r => {
                byCohort[r.cohort] = (byCohort[r.cohort] || 0) + r.active_users;
            });
            return [
                { label: 'Enterprise',  value: byCohort['Enterprise'],  display: byCohort['Enterprise'].toLocaleString(),  color: '#FF355E' },
                { label: 'Growth',      value: byCohort['Growth'],      display: byCohort['Growth'].toLocaleString(),      color: '#1E3A8A' },
                { label: 'Emerging',    value: byCohort['Emerging'],    display: byCohort['Emerging'].toLocaleString(),    color: '#7C2D5C' },
                { label: 'Early Stage', value: byCohort['Early Stage'], display: byCohort['Early Stage'].toLocaleString(), color: '#94A3B8' }
            ].filter(d => d.value > 0);
        }
        if (this.isBackupCustomerComplianceTab) {
            const rows     = this.backupChartComplianceRows;
            const critical = rows.filter(r => r.urgency_order === 2).length;
            const warning  = rows.filter(r => r.urgency_order === 1).length;
            const healthy  = rows.filter(r => r.urgency_order === 0).length;
            return [
                { label: 'Critical', value: critical, display: critical.toLocaleString(), color: '#DC2626' },
                { label: 'Warning',  value: warning,  display: warning.toLocaleString(),  color: '#F59E0B' },
                { label: 'Healthy',  value: healthy,  display: healthy.toLocaleString(),  color: '#059669' }
            ].filter(d => d.value > 0);
        }
        // Total Ops
        const rows = this.backupChartAllRows;
        const bk = rows.reduce((s, r) => s + (r.backups  || 0), 0);
        const ar = rows.reduce((s, r) => s + (r.archives || 0), 0);
        const re = rows.reduce((s, r) => s + (r.restores || 0), 0);
        const ex = rows.reduce((s, r) => s + (r.exports  || 0), 0);
        return [
            { label: 'Backups',  value: bk, display: bk.toLocaleString(), color: '#FF355E' },
            { label: 'Archives', value: ar, display: ar.toLocaleString(), color: '#1E3A8A' },
            { label: 'Restores', value: re, display: re.toLocaleString(), color: '#059669' },
            { label: 'Exports',  value: ex, display: ex.toLocaleString(), color: '#F59E0B' }
        ].filter(d => d.value > 0);
    }

    get backupBreakdownLegend() {
        const activeFilter = this.isBackupCustomerComplianceTab ? this.backupComplianceUrgencyFilter : null;
        return this.backupBreakdownData.map(d => ({
            label   : d.label,
            display : d.display,
            dotStyle: `background:${d.color};width:12px;height:12px;border-radius:50%;display:inline-block;margin-right:6px;flex-shrink:0`,
            rowClass: activeFilter
                      ? (activeFilter === d.label ? 'legend-row legend-row--active' : 'legend-row legend-row--dimmed')
                      : 'legend-row'
        }));
    }

    get hasComplianceUrgencyFilter() {
        return this.isBackupCustomerComplianceTab && !!this.backupComplianceUrgencyFilter;
    }

    // ── Unified base: one row per account with all backup metrics ────────────

    get backupAllRowsBase() {
        const summaryMap = {};
        this.backupOrgSummary.forEach(s => { summaryMap[s.account] = s; });
        const prevOpsMap = {};
        this.backupExceptionSummary.forEach(e => {
            prevOpsMap[e.account] = {
                backups  : e.prev_total_backups  || 0,
                archives : e.prev_total_archives || 0,
                restores : e.prev_total_restores || 0,
                exports  : e.prev_total_exports  || 0,
                total    : (e.prev_total_backups  || 0) + (e.prev_total_archives || 0) +
                           (e.prev_total_restores || 0) + (e.prev_total_exports  || 0) +
                           (e.prev_total_searches || 0)
            };
        });
        const tr = (curr, prev) => ({ up: prev > 0 && curr > prev, down: prev > 0 && curr < prev });
        return this.rawData.map(r => {
            const s        = summaryMap[r.account] || {};
            const prod     = s.prod_orgs         || 0;
            const prevProd = s.prev_prod_orgs     || 0;
            const sand     = s.sandbox_orgs      || 0;
            const prevSand = s.prev_sandbox_orgs  || 0;
            const bkMb     = s.total_backup_mb   || 0;
            const prevBkMb = s.prev_backup_mb    || 0;
            const arMb     = s.total_archive_mb  || 0;
            const prevArMb = s.prev_archive_mb   || 0;
            const totalMb  = bkMb + arMb;
            const bk       = r.backups  || 0;
            const ar       = r.archives || 0;
            const re       = r.restores || 0;
            const ex       = r.exports  || 0;
            const ops      = bk + ar + re + ex;
            const p        = prevOpsMap[r.account] || {};
            const prodT    = tr(prod,    prevProd);
            const sandT    = tr(sand,    prevSand);
            const totalT   = tr(prod + sand, prevProd + prevSand);
            const bkT      = tr(bkMb,   prevBkMb);
            const arT      = tr(arMb,   prevArMb);
            const storT    = tr(totalMb, prevBkMb + prevArMb);
            const bkOpsT   = tr(bk, p.backups  || 0);
            const arOpsT   = tr(ar, p.archives || 0);
            const reOpsT   = tr(re, p.restores || 0);
            const exOpsT   = tr(ex, p.exports  || 0);
            const opsT     = tr(ops, p.total   || 0);
            return {
                account             : r.account,
                cohort              : r.cohort,
                cohortBadgeClass    : `cohort-badge cohort-badge--${r.cohort.toLowerCase().replace(/\s/g, '-')}`,
                prod_orgs           : prod,
                prod_trend_up       : prodT.up,
                prod_trend_down     : prodT.down,
                sandbox_orgs        : sand,
                sandbox_trend_up    : sandT.up,
                sandbox_trend_down  : sandT.down,
                total_orgs          : prod + sand,
                total_trend_up      : totalT.up,
                total_trend_down    : totalT.down,
                total_backup_mb     : bkMb,
                total_archive_mb    : arMb,
                total_db_mb         : totalMb,
                backup_gb           : bkMb   > 0 ? (bkMb   / 1024).toFixed(2) : '0.00',
                backup_trend_up     : bkT.up,
                backup_trend_down   : bkT.down,
                archive_gb          : arMb   > 0 ? (arMb   / 1024).toFixed(2) : '0.00',
                archive_trend_up    : arT.up,
                archive_trend_down  : arT.down,
                total_storage_gb    : totalMb > 0 ? (totalMb / 1024).toFixed(2) : '0.00',
                storage_trend_up    : storT.up,
                storage_trend_down  : storT.down,
                backups             : bk,
                backups_trend_up    : bkOpsT.up,
                backups_trend_down  : bkOpsT.down,
                archives            : ar,
                archives_trend_up   : arOpsT.up,
                archives_trend_down : arOpsT.down,
                restores            : re,
                restores_trend_up   : reOpsT.up,
                restores_trend_down : reOpsT.down,
                exports             : ex,
                exports_trend_up    : exOpsT.up,
                exports_trend_down  : exOpsT.down,
                total_ops           : ops,
                total_ops_fmt       : ops.toLocaleString(),
                ops_trend_up        : opsT.up,
                ops_trend_down      : opsT.down
            };
        });
    }

    get backupActiveUserRowsBase() {
        const rdMap = {};
        this.rawData.forEach(r => { rdMap[r.account] = r; });
        return this.backupActiveUserSummary
            .map(a => {
                const rd     = rdMap[a.account] || {};
                const cohort = rd.cohort || 'Early Stage';
                const lastAct = a.last_activity || '';
                const curr = a.active_users      || 0;
                const prev = a.prev_active_users || 0;
                return {
                    account          : a.account,
                    cohort           : cohort,
                    cohortBadgeClass : `cohort-badge cohort-badge--${cohort.toLowerCase().replace(/\s/g, '-')}`,
                    active_users     : curr,
                    users_trend_up   : prev > 0 && curr > prev,
                    users_trend_down : prev > 0 && curr < prev,
                    last_activity    : lastAct,
                    last_act_class   : lastAct ? 'date-cell' : 'date-cell date-never'
                };
            })
            .filter(r => r.active_users > 0);
    }

    get backupExceptionRowsBase() {
        const rdMap = {};
        this.rawData.forEach(r => { rdMap[r.account] = r; });
        return this.backupExceptionSummary
            .map(e => {
                const bkEx  = e.backup_exceptions  || 0;
                const bkTot = e.total_backups       || 0;
                const arEx  = e.archive_exceptions  || 0;
                const arTot = e.total_archives      || 0;
                const reEx  = e.restore_exceptions  || 0;
                const reTot = e.total_restores      || 0;
                const exEx  = e.export_exceptions   || 0;
                const exTot = e.total_exports       || 0;
                const srEx  = e.search_exceptions   || 0;
                const srTot = e.total_searches      || 0;
                const totalEx = bkEx + arEx + reEx + exEx + srEx;
                const rd      = rdMap[e.account] || {};
                const cohort  = rd.cohort || 'Early Stage';
                const rate     = (ex, tot) => tot > 0 ? ((ex / tot) * 100).toFixed(1) + '%' : '—';
                const rateNum  = (ex, tot) => tot > 0 ? ex / tot : -1; // -1 → no data, sorts last
                const rateClass = (ex, tot) => {
                    if (tot === 0) return 'num-cell';
                    const r = ex / tot;
                    if (r > 0.2) return 'num-cell rate-danger';
                    if (r > 0.05) return 'num-cell rate-warning';
                    return 'num-cell';
                };
                return {
                    account                  : e.account,
                    cohort                   : cohort,
                    cohortBadgeClass         : `cohort-badge cohort-badge--${cohort.toLowerCase().replace(/\s/g, '-')}`,
                    backup_exceptions        : bkEx,
                    total_backups            : bkTot,
                    backup_fail_rate         : rate(bkEx, bkTot),
                    backup_fail_rate_num     : rateNum(bkEx, bkTot),
                    backup_rate_class        : rateClass(bkEx, bkTot),
                    backup_exc_class         : bkEx > 0 ? 'num-cell exception-cell' : 'num-cell',
                    archive_exceptions       : arEx,
                    total_archives           : arTot,
                    archive_fail_rate        : rate(arEx, arTot),
                    archive_fail_rate_num    : rateNum(arEx, arTot),
                    archive_rate_class       : rateClass(arEx, arTot),
                    archive_exc_class        : arEx > 0 ? 'num-cell exception-cell' : 'num-cell',
                    restore_exceptions       : reEx,
                    total_restores           : reTot,
                    restore_fail_rate        : rate(reEx, reTot),
                    restore_fail_rate_num    : rateNum(reEx, reTot),
                    restore_rate_class       : rateClass(reEx, reTot),
                    restore_exc_class        : reEx > 0 ? 'num-cell exception-cell' : 'num-cell',
                    export_exceptions        : exEx,
                    total_exports            : exTot,
                    export_fail_rate         : rate(exEx, exTot),
                    export_fail_rate_num     : rateNum(exEx, exTot),
                    export_rate_class        : rateClass(exEx, exTot),
                    export_exc_class         : exEx > 0 ? 'num-cell exception-cell' : 'num-cell',
                    search_exceptions        : srEx,
                    total_searches           : srTot,
                    search_fail_rate         : rate(srEx, srTot),
                    search_fail_rate_num     : rateNum(srEx, srTot),
                    search_rate_class        : rateClass(srEx, srTot),
                    search_exc_class         : srEx > 0 ? 'num-cell exception-cell' : 'num-cell',
                    total_exceptions          : totalEx,
                    total_exc_class           : totalEx > 0 ? 'num-cell bk-total-cell exception-cell' : 'num-cell bk-total-cell',
                    exc_trend_up              : (e.prev_total_exceptions || 0) > 0 && totalEx > (e.prev_total_exceptions || 0),
                    exc_trend_down            : (e.prev_total_exceptions || 0) > 0 && totalEx < (e.prev_total_exceptions || 0)
                };
            })
            .filter(r => r.total_exceptions > 0);
    }

    get backupComplianceRowsBase() {
        // Case-insensitive lookups
        const licenseMap = {};
        this.backupLicenseTypes.forEach(l => { licenseMap[(l.account || '').toLowerCase()] = l; });

        const staleMap = {};
        this.backupStaleProdOrgsSummary.forEach(s => { staleMap[(s.account || '').toLowerCase()] = s; });

        const excMap = {};
        this.backupExceptionRowsBase.forEach(e => { excMap[e.account] = e; });

        const userMap = {};
        this.backupActiveUserSummary.forEach(u => { userMap[(u.account || '').toLowerCase()] = u; });

        // Cutoff: 30 days ago as YYYY-MM-DD for string comparison
        const d = new Date();
        d.setDate(d.getDate() - 30);
        const cutoff = d.toISOString().slice(0, 10);

        const licenseClass = type => {
            if (!type) return 'license-badge license-badge--unknown';
            return `license-badge license-badge--${type.toLowerCase().replace(/\s+/g, '-')}`;
        };

        return this.backupAllRowsBase.map(base => {
            const key   = (base.account || '').toLowerCase();
            const lic   = licenseMap[key] || {};
            const stale = staleMap[key]   || {};
            const ex    = excMap[base.account] || {};
            const user  = userMap[key] || null; // null = account not in summary at all

            // ── B&A exception rate (backup + archive only) ──
            const bkEx    = ex.backup_exceptions  || 0;
            const arEx    = ex.archive_exceptions || 0;
            const bkTotal = ex.total_backups      || 0;
            const arTotal = ex.total_archives     || 0;
            const baOps   = bkTotal + arTotal;
            const baExRate = baOps > 0 ? (bkEx + arEx) / baOps : 0;

            // ── Stale org counts (30-day and 60-day windows) ──
            const stale60 = stale.stale_60 || 0;
            const stale30 = stale.stale_30 || 0;
            const staleWarnOnly = Math.max(0, stale30 - stale60); // orgs in 30–60 day band only

            // ── Active users / engagement ──
            const activeUsers    = user ? (user.active_users || 0) : 0;
            const lastActivity   = user ? (user.last_activity || '') : '';
            const zeroUsers      = activeUsers === 0;                           // no users at all
            const noRecentActivity = !zeroUsers && (!lastActivity || lastActivity < cutoff); // users exist but inactive 30d

            // ── CRITICAL signals (any one → Critical) ──
            const critSignals = [];
            if (stale60 > 0)      critSignals.push(`${stale60} prod org${stale60 > 1 ? 's' : ''} not backed up in 60+ days`);
            if (baExRate >= 0.50)  critSignals.push(`B&A exception rate ${(baExRate * 100).toFixed(1)}%`);
            if (zeroUsers)        critSignals.push('No active users on account');

            // ── WARNING signals (any one, only if no critical) ──
            const warnSignals = [];
            if (staleWarnOnly > 0)    warnSignals.push(`${staleWarnOnly} prod org${staleWarnOnly > 1 ? 's' : ''} not backed up in 30–60 days`);
            if (baExRate >= 0.05 && baExRate < 0.50) warnSignals.push(`Elevated B&A exceptions (${(baExRate * 100).toFixed(1)}%)`);
            if (noRecentActivity)     warnSignals.push('No user activity in last 30 days');

            let urgency, urgencyOrder, urgencyClass, contactReason;
            if (critSignals.length > 0) {
                urgency = 'Critical'; urgencyOrder = 2; urgencyClass = 'urgency-badge urgency-critical';
                contactReason = critSignals.concat(warnSignals).join(' · ');
            } else if (warnSignals.length > 0) {
                urgency = 'Warning';  urgencyOrder = 1; urgencyClass = 'urgency-badge urgency-warning';
                contactReason = warnSignals.join(' · ');
            } else {
                urgency = 'Healthy';  urgencyOrder = 0; urgencyClass = 'urgency-badge urgency-healthy';
                contactReason = 'Account is healthy';
            }

            return {
                ...base,
                license_type       : lic.license_type || '—',
                license_tier       : lic.license_tier || 0,
                license_type_class : licenseClass(lic.license_type),
                urgency,
                urgency_order      : urgencyOrder,
                urgencyClass,
                contact_reason     : contactReason,
                total_exceptions   : ex.total_exceptions || 0,
                exc_rate_num       : baExRate * 100,
                // individual signal flags — used by the compliance bar chart and signal filter
                _sig_stale60    : stale60 > 0,
                _sig_zeroUsers  : zeroUsers,
                _sig_excCrit    : baExRate >= 0.50,
                _sig_staleWarn  : staleWarnOnly > 0,
                _sig_noActivity : noRecentActivity,
                _sig_excWarn    : baExRate >= 0.05 && baExRate < 0.50
            };
        });
    }

    get backupChartComplianceRows() {
        const a = this.backupChartAccounts;
        return a ? this.backupComplianceRowsBase.filter(r => a.has(r.account)) : this.backupComplianceRowsBase;
    }

    get top10ByUrgency() {
        return [...this.backupChartComplianceRows]
            .sort((a, b) => {
                if (b.urgency_order !== a.urgency_order) return b.urgency_order - a.urgency_order;
                return (b.total_exceptions || 0) - (a.total_exceptions || 0);
            })
            .slice(0, 10);
    }

    // Signal frequency data for the compliance bar chart
    // Each entry represents one compliance signal; 'account' carries the flag key for click filtering
    get complianceSignalData() {
        const rows = this.backupChartComplianceRows;
        return [
            { label: 'Stale 60+ days', account: '_sig_stale60',    color: '#1E3A8A' },
            { label: 'Zero users',      account: '_sig_zeroUsers',  color: '#1E3A8A' },
            { label: 'Exc ≥50%',        account: '_sig_excCrit',    color: '#1E3A8A' },
            { label: 'Stale 30–60d',    account: '_sig_staleWarn',  color: '#1E3A8A' },
            { label: 'No activity 30d', account: '_sig_noActivity', color: '#1E3A8A' },
            { label: 'Exc 5–49%',       account: '_sig_excWarn',    color: '#1E3A8A' }
        ].map(s => ({ ...s, count: rows.filter(r => r[s.account]).length }))
         .filter(d => d.count > 0);
    }

    get hasComplianceSignalFilter() {
        return this.isBackupCustomerComplianceTab && !!this.backupComplianceSignalFilter;
    }

    get activeComplianceSignalLabel() {
        const labels = {
            '_sig_stale60':    'Stale 60+ days',
            '_sig_zeroUsers':  'Zero users',
            '_sig_excCrit':    'Exc ≥50%',
            '_sig_staleWarn':  'Stale 30–60d',
            '_sig_noActivity': 'No activity 30d',
            '_sig_excWarn':    'Exc 5–49%'
        };
        return labels[this.backupComplianceSignalFilter] || '';
    }

    get complianceSignalPopupTitle() {
        if (!this.complianceSignalPopupLabel) return '';
        const count = this.complianceSignalPopupData.length;
        return `${this.complianceSignalPopupLabel} — ${count} account${count !== 1 ? 's' : ''}`;
    }

    get complianceSignalPopupDisplayRows() {
        return this.complianceSignalPopupData.map((r, i) => ({
            ...r,
            rowClass: i % 2 === 0 ? 'row-even' : 'row-odd'
        }));
    }

    // ── Sort ─────────────────────────────────────────────────────────────────

    get backupActiveSortField() {
        if (this.backupSortField)             return this.backupSortField;
        if (this.isBackupStorageTab)          return 'total_db_mb';
        if (this.isBackupExceptionsTab)       return 'total_exceptions';
        if (this.isBackupActiveUsersTab)      return 'active_users';
        if (this.isBackupOpsTab)              return 'total_ops';
        if (this.isBackupCustomerComplianceTab) return 'urgency_order'; // 2=Critical, 1=Warning, 0=Healthy; desc = worst first
        return 'total_orgs';
    }

    get backupSortedRows() {
        const base = this.isBackupExceptionsTab     ? this.backupExceptionRowsBase
                   : this.isBackupActiveUsersTab    ? this.backupActiveUserRowsBase
                   : this.isBackupCustomerComplianceTab ? this.backupComplianceRowsBase
                   : this.backupAllRowsBase;
        const sf   = this.backupActiveSortField;
        const sign = this.backupSortAsc ? 1 : -1;
        return [...base].sort((a, b) => {
            const va = typeof a[sf] === 'string' ? a[sf].toLowerCase() : (a[sf] ?? 0);
            const vb = typeof b[sf] === 'string' ? b[sf].toLowerCase() : (b[sf] ?? 0);
            if (va < vb) return -1 * sign;
            if (va > vb) return       sign;
            return 0;
        });
    }

    // Sort class / icon helpers (used in thead)
    _bkSortClass(f) { return 'sortable' + (this.backupActiveSortField === f ? ' sort-active' : ''); }
    _bkSortIcon(f)  { return this.backupActiveSortField === f ? (this.backupSortAsc ? '↑' : '↓') : ''; }

    get bkSortClassAccount()     { return this._bkSortClass('account');      }
    get bkSortClassProdOrgs()    { return this._bkSortClass('prod_orgs');    }
    get bkSortClassSandboxOrgs() { return this._bkSortClass('sandbox_orgs'); }
    get bkSortClassTotalOrgs()   { return this._bkSortClass('total_orgs');   }
    get bkSortClassDbMb()        { return this._bkSortClass('total_db_mb');      }
    get bkSortClassBackupMb()    { return this._bkSortClass('total_backup_mb');  }
    get bkSortClassArchiveMb()   { return this._bkSortClass('total_archive_mb'); }
    get bkSortClassBackups()     { return this._bkSortClass('backups');           }
    get bkSortClassArchives()    { return this._bkSortClass('archives');     }
    get bkSortClassRestores()    { return this._bkSortClass('restores');     }
    get bkSortClassExports()     { return this._bkSortClass('exports');      }
    get bkSortClassTotalOps()    { return this._bkSortClass('total_ops');    }

    get bkSortIconAccount()      { return this._bkSortIcon('account');      }
    get bkSortIconProdOrgs()     { return this._bkSortIcon('prod_orgs');    }
    get bkSortIconSandboxOrgs()  { return this._bkSortIcon('sandbox_orgs'); }
    get bkSortIconTotalOrgs()    { return this._bkSortIcon('total_orgs');   }
    get bkSortIconDbMb()         { return this._bkSortIcon('total_db_mb');      }
    get bkSortIconBackupMb()     { return this._bkSortIcon('total_backup_mb');  }
    get bkSortIconArchiveMb()    { return this._bkSortIcon('total_archive_mb'); }
    get bkSortIconBackups()      { return this._bkSortIcon('backups');           }
    get bkSortIconArchives()     { return this._bkSortIcon('archives');     }
    get bkSortIconRestores()     { return this._bkSortIcon('restores');     }
    get bkSortIconExports()      { return this._bkSortIcon('exports');      }
    get bkSortIconTotalOps()      { return this._bkSortIcon('total_ops');           }

    get bkSortClassTotalEx()      { return this._bkSortClass('total_exceptions');   }
    get bkSortClassBackupEx()     { return this._bkSortClass('backup_exceptions');  }
    get bkSortClassTotalBk()      { return this._bkSortClass('total_backups');      }
    get bkSortClassArchiveEx()    { return this._bkSortClass('archive_exceptions'); }
    get bkSortClassTotalAr()      { return this._bkSortClass('total_archives');     }
    get bkSortClassRestoreEx()    { return this._bkSortClass('restore_exceptions'); }
    get bkSortClassTotalRe()      { return this._bkSortClass('total_restores');     }
    get bkSortClassExportEx()     { return this._bkSortClass('export_exceptions');  }
    get bkSortClassTotalEx2()     { return this._bkSortClass('total_exports');      }
    get bkSortClassSearchEx()     { return this._bkSortClass('search_exceptions');  }
    get bkSortClassTotalSr()      { return this._bkSortClass('total_searches');     }

    get bkSortIconTotalEx()       { return this._bkSortIcon('total_exceptions');   }
    get bkSortIconBackupEx()      { return this._bkSortIcon('backup_exceptions');  }
    get bkSortIconTotalBk()       { return this._bkSortIcon('total_backups');      }
    get bkSortIconArchiveEx()     { return this._bkSortIcon('archive_exceptions'); }
    get bkSortIconTotalAr()       { return this._bkSortIcon('total_archives');     }
    get bkSortIconRestoreEx()     { return this._bkSortIcon('restore_exceptions'); }
    get bkSortIconTotalRe()       { return this._bkSortIcon('total_restores');     }
    get bkSortIconExportEx()      { return this._bkSortIcon('export_exceptions');  }
    get bkSortIconTotalEx2()      { return this._bkSortIcon('total_exports');      }
    get bkSortIconSearchEx()      { return this._bkSortIcon('search_exceptions');       }
    get bkSortIconTotalSr()       { return this._bkSortIcon('total_searches');          }

    get bkSortClassBkRate()        { return this._bkSortClass('backup_fail_rate_num');   }
    get bkSortClassArRate()        { return this._bkSortClass('archive_fail_rate_num');  }
    get bkSortClassReRate()        { return this._bkSortClass('restore_fail_rate_num');  }
    get bkSortClassExRate()        { return this._bkSortClass('export_fail_rate_num');   }
    get bkSortClassSrRate()        { return this._bkSortClass('search_fail_rate_num');   }

    get bkSortIconBkRate()         { return this._bkSortIcon('backup_fail_rate_num');    }
    get bkSortIconArRate()         { return this._bkSortIcon('archive_fail_rate_num');   }
    get bkSortIconReRate()         { return this._bkSortIcon('restore_fail_rate_num');   }
    get bkSortIconExRate()         { return this._bkSortIcon('export_fail_rate_num');    }
    get bkSortIconSrRate()         { return this._bkSortIcon('search_fail_rate_num');    }

    get bkSortClassActiveUsers()   { return this._bkSortClass('active_users');           }
    get bkSortClassLastActivity()  { return this._bkSortClass('last_activity');          }
    get bkSortIconActiveUsers()    { return this._bkSortIcon('active_users');            }
    get bkSortIconLastActivity()   { return this._bkSortIcon('last_activity');           }

    get bkSortClassUrgency()        { return this._bkSortClass('urgency_order');     }
    get bkSortIconUrgency()         { return this._bkSortIcon('urgency_order');      }
    get bkSortClassLicenseType()    { return this._bkSortClass('license_tier');      }
    get bkSortIconLicenseType()     { return this._bkSortIcon('license_tier');       }
    get bkSortClassTotalExC()       { return this._bkSortClass('total_exceptions');  }
    get bkSortIconTotalExC()        { return this._bkSortIcon('total_exceptions');   }

    // ── Top-10 charts (always use full unsorted base so they reflect true top) ─

    // ── Chart filter: set by search term or open account popup ──────────────

    get backupChartAccounts() {
        if (this.orgDetailOpen && this.orgDetailAccount) {
            return new Set([this.orgDetailAccount]);
        }
        const term = this.backupSearchTerm.toLowerCase().trim();
        if (term) return new Set(this.backupFilteredRows.map(r => r.account));
        return null; // null = no filter, show all
    }

    get backupChartAllRows() {
        const a = this.backupChartAccounts;
        return a ? this.backupAllRowsBase.filter(r => a.has(r.account)) : this.backupAllRowsBase;
    }
    get backupChartExceptionRows() {
        const a = this.backupChartAccounts;
        return a ? this.backupExceptionRowsBase.filter(r => a.has(r.account)) : this.backupExceptionRowsBase;
    }
    get backupChartUserRows() {
        const a = this.backupChartAccounts;
        return a ? this.backupActiveUserRowsBase.filter(r => a.has(r.account)) : this.backupActiveUserRowsBase;
    }

    get top10ByOrgs() {
        return [...this.backupChartAllRows].sort((a, b) => b.total_orgs - a.total_orgs).slice(0, 10);
    }
    get top10ByStorage() {
        return [...this.backupChartAllRows].sort((a, b) => b.total_db_mb - a.total_db_mb).slice(0, 10);
    }
    get top10ByOps() {
        return [...this.backupChartAllRows].sort((a, b) => b.total_ops - a.total_ops).slice(0, 10);
    }
    get top10ByExceptions() {
        return [...this.backupChartExceptionRows].sort((a, b) => b.total_exceptions - a.total_exceptions).slice(0, 10);
    }
    get top10ByActiveUsers() {
        return [...this.backupChartUserRows].sort((a, b) => b.active_users - a.active_users).slice(0, 10);
    }

    // ── Search filter + suggestions ──────────────────────────────────────────

    get backupFilteredRows() {
        const term = this.backupSearchTerm.toLowerCase().trim();
        let rows = term
            ? this.backupSortedRows.filter(r => r.account.toLowerCase().includes(term))
            : this.backupSortedRows;
        if (this.isBackupCustomerComplianceTab && this.backupComplianceUrgencyFilter) {
            rows = rows.filter(r => r.urgency === this.backupComplianceUrgencyFilter);
        }
        if (this.isBackupCustomerComplianceTab && this.backupComplianceSignalFilter) {
            rows = rows.filter(r => r[this.backupComplianceSignalFilter]);
        }
        return rows;
    }

    get backupSearchSuggestions() {
        if (!this.backupShowSuggestions) return [];
        const term = this.backupSearchTerm.toLowerCase().trim();
        if (!term) return [];
        const base = this.isBackupExceptionsTab     ? this.backupExceptionRowsBase
                   : this.isBackupActiveUsersTab    ? this.backupActiveUserRowsBase
                   : this.isBackupCustomerComplianceTab ? this.backupComplianceRowsBase
                   : this.backupAllRowsBase;
        return base
            .filter(r => r.account.toLowerCase().includes(term) && r.account.toLowerCase() !== term)
            .slice(0, 8)
            .map(r => ({ account: r.account }));
    }

    get backupHasSuggestions() {
        return this.backupSearchSuggestions.length > 0;
    }

    // Pagination
    get backupTotalRows()  { return this.backupFilteredRows.length; }

    get backupTotalPages() {
        if (!this.backupPageSize) return 1;
        return Math.max(1, Math.ceil(this.backupTotalRows / this.backupPageSize));
    }

    get backupPrevDisabled() { return this.backupCurrentPage <= 1; }
    get backupNextDisabled() { return this.backupCurrentPage >= this.backupTotalPages; }

    get backupPageInfo() {
        const total = this.backupTotalRows;
        if (!this.backupPageSize || total === 0) return `${total} accounts`;
        const start = (this.backupCurrentPage - 1) * this.backupPageSize + 1;
        const end   = Math.min(this.backupCurrentPage * this.backupPageSize, total);
        return `${start}–${end} of ${total}`;
    }

    get backupPageSizeOptions() {
        const sizes = [
            { value: 10, label: '10' }, { value: 20, label: '20' },
            { value: 50, label: '50' }, { value: 100, label: '100' },
            { value: 0,  label: 'All' }
        ];
        return sizes.map(o => ({
            ...o,
            cssClass: 'pg-btn' + (o.value === this.backupPageSize ? ' pg-btn--active' : '')
        }));
    }

    get backupPaginatedRows() {
        const rows = this.backupFilteredRows;
        let sliced = rows;
        if (this.backupPageSize > 0) {
            const start = (this.backupCurrentPage - 1) * this.backupPageSize;
            sliced = rows.slice(start, start + this.backupPageSize);
        }
        return sliced.map((r, i) => ({ ...r, rowClass: i % 2 === 0 ? 'row-even' : 'row-odd' }));
    }

    // ── Computed getters: stats cards ───────────────────────────────────────

    get totalAccounts()       { return this.filteredData.length; }
    get enterpriseCount()     { return this.filteredData.filter(r => r.cohort === 'Enterprise').length; }
    get growthCount()         { return this.filteredData.filter(r => r.cohort === 'Growth').length; }
    get totalUsersFormatted() { return fmt(this.filteredData.reduce((s, r) => s + (r.users || 0), 0)); }
    get totalEventsFormatted(){ return fmt(this.filteredData.reduce((s, r) => s + (r.total_events || 0), 0)); }

    // ── Computed getters: donut chart legend ────────────────────────────────

    get cohortLegend() {
        const counts = {};
        this.filteredData.forEach(r => { counts[r.cohort] = (counts[r.cohort] || 0) + 1; });
        return COHORT_ORDER.map(label => ({
            label,
            count : counts[label] || 0,
            dotStyle: `background:${COHORT_COLORS[label]};width:12px;height:12px;border-radius:50%;display:inline-block;margin-right:6px;flex-shrink:0`
        }));
    }

    // ── Computed getters: cohort tabs ───────────────────────────────────────

    get cohortTabList() {
        const allTabs = ['All', ...COHORT_ORDER];
        const counts  = { All: this.rawData.length };
        this.rawData.forEach(r => { counts[r.cohort] = (counts[r.cohort] || 0) + 1; });

        // Apply search filter to counts
        let searchFiltered = this.rawData;
        if (this.searchTerm) {
            const s = this.searchTerm.toLowerCase();
            searchFiltered = searchFiltered.filter(r => r.account.toLowerCase().includes(s));
        }
        const filteredCounts = { All: searchFiltered.length };
        searchFiltered.forEach(r => { filteredCounts[r.cohort] = (filteredCounts[r.cohort] || 0) + 1; });

        return allTabs.map(label => ({
            label,
            count   : filteredCounts[label] || 0,
            cssClass: 'cohort-tab' + (label === this.selectedCohort ? ' cohort-tab--active' : '')
        }));
    }

    // ── Computed getters: table rows ────────────────────────────────────────

    get tableRows() {
        return this.filteredData.map(r => {
            const org = this.orgSummaryMap[r.account] || {};
            const p   = org.prod_orgs    || 0;
            const s   = org.sandbox_orgs || 0;
            return {
                ...r,
                orgsDisplay          : (p === 0 && s === 0) ? '—' : `${p}p / ${s}s`,
                rowClass             : 'data-row',
                cohortBadgeClass     : `cohort-badge cohort-badge--${r.cohort.toLowerCase().replace(/\s/g, '-')}`,
                totalEventsFormatted : fmt(r.total_events)
            };
        });
    }

    get isEmpty()      { return !this.isLoading && this.filteredData.length === 0; }
    get rowCount()     { return this.filteredData.length; }

    get hasTrendData() {
        return !this.trendLoading &&
               this.trendData?.weeks?.length > 0 &&
               (this.selectedProduct === 'native_apps' || this.selectedProduct === 'cloud_devops');
    }
    get isModalOpen()  { return this.expandedChart != null; }

    get deployTrendTitle() {
        if (this.isNativeApps)    return 'Deployment Trends — Manual vs Pipeline · weekly';
        if (this.isBackupArchive) return 'Backup & Archive Trends · weekly';
        if (this.isDataMigrator)  return 'Migration Trends · weekly';
        return 'Deployment Trends · weekly';
    }

    get eventBreakdownTitle() {
        if (this.isNativeApps)    return 'Event Breakdown';
        if (this.isBackupArchive) return 'Activity Breakdown';
        if (this.isDataMigrator)  return 'Migration Breakdown';
        return 'Engagement Breakdown';
    }

    get modalTitle() { return this.expandedChart === 'deploy' ? this.deployTrendTitle : 'Feature Usage Trends — Top 5 by Volume · weekly'; }

    // ── Sort icon helpers ────────────────────────────────────────────────────

    _sortClass(field) { return 'sortable' + (this.sortField === field ? ' sort-active' : ''); }
    _sortIcon(field)  { return this.sortField === field ? (this.sortAsc ? '↑' : '↓') : ''; }

    get sortClassAccount()      { return this._sortClass('account'); }
    get sortClassCohort()       { return this._sortClass('cohort'); }
    get sortClassUsers()        { return this._sortClass('users'); }
    get sortClassDeploys()      { return this._sortClass('deploys'); }
    get sortClassDpu()          { return this._sortClass('deploys_per_user'); }
    get sortClassLicensesUsed() { return this._sortClass('licenses_used'); }
    get sortClassLicensesTotal(){ return this._sortClass('licenses_total'); }
    get sortClassCommits()      { return this._sortClass('commits'); }
    get sortClassPipelineRuns() { return this._sortClass('pipeline_runs'); }
    get sortClassBackups()      { return this._sortClass('backups'); }
    get sortClassArchives()     { return this._sortClass('archives'); }
    get sortClassRestores()     { return this._sortClass('restores'); }
    get sortClassExports()      { return this._sortClass('exports'); }
    get sortClassMigrations()   { return this._sortClass('migrations'); }
    get sortClassRetrieves()    { return this._sortClass('retrieves'); }
    get sortClassEvents()       { return this._sortClass('total_events'); }

    get sortIconAccount()       { return this._sortIcon('account'); }
    get sortIconCohort()        { return this._sortIcon('cohort'); }
    get sortIconUsers()         { return this._sortIcon('users'); }
    get sortIconDeploys()       { return this._sortIcon('deploys'); }
    get sortIconDpu()           { return this._sortIcon('deploys_per_user'); }
    get sortIconLicensesUsed()  { return this._sortIcon('licenses_used'); }
    get sortIconLicensesTotal() { return this._sortIcon('licenses_total'); }
    get sortIconCommits()       { return this._sortIcon('commits'); }
    get sortIconPipelineRuns()  { return this._sortIcon('pipeline_runs'); }
    get sortIconBackups()       { return this._sortIcon('backups'); }
    get sortIconArchives()      { return this._sortIcon('archives'); }
    get sortIconRestores()      { return this._sortIcon('restores'); }
    get sortIconExports()       { return this._sortIcon('exports'); }
    get sortIconMigrations()    { return this._sortIcon('migrations'); }
    get sortIconRetrieves()     { return this._sortIcon('retrieves'); }
    get sortIconEvents()        { return this._sortIcon('total_events'); }

    // ── Event handlers ───────────────────────────────────────────────────────

    handleProductSelect(evt) {
        this.selectedProduct        = evt.currentTarget.dataset.key;
        this.selectedCohort         = 'All';
        this.searchTerm             = '';
        this.selectedBackupTab      = 'org_inventory';
        this.backupSearchTerm       = '';
        this.backupShowSuggestions  = false;
        this.backupPageSize         = 10;
        this.backupCurrentPage      = 1;
        this.backupSortField        = null;
        this.backupSortAsc          = false;
        this.loadData();
    }

    handleBackupTabSelect(evt) {
        this.selectedBackupTab              = evt.currentTarget.dataset.tab;
        this.backupCurrentPage              = 1;
        this.backupSortField                = null;
        this.backupSortAsc                  = false;
        this.backupComplianceUrgencyFilter  = null;
        this.backupComplianceSignalFilter   = null;
    }

    handleBackupSort(evt) {
        const field = evt.currentTarget.dataset.field;
        if (field === this.backupActiveSortField) {
            this.backupSortAsc = !this.backupSortAsc;
        } else {
            this.backupSortField = field;
            this.backupSortAsc   = false;
        }
        this.backupCurrentPage = 1;
    }

    handleBackupSearchInput(evt) {
        this.backupSearchTerm               = evt.target.value;
        this.backupShowSuggestions          = true;
        this.backupCurrentPage              = 1;
        this.backupComplianceUrgencyFilter  = null;
        this.backupComplianceSignalFilter   = null;
    }

    handleBackupSearchFocus() {
        if (this.backupSearchTerm) this.backupShowSuggestions = true;
    }

    handleBackupSearchBlur() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this.backupShowSuggestions = false; }, 150);
    }

    handleBackupSuggestionSelect(evt) {
        this.backupSearchTerm      = evt.currentTarget.dataset.account;
        this.backupShowSuggestions = false;
        this.backupCurrentPage     = 1;
    }

    handleBackupClearSearch() {
        this.backupSearchTerm               = '';
        this.backupShowSuggestions          = false;
        this.backupCurrentPage              = 1;
        this.backupComplianceUrgencyFilter  = null;
        this.backupComplianceSignalFilter   = null;
    }

    clearComplianceUrgencyFilter() {
        this.backupComplianceUrgencyFilter = null;
        this.backupCurrentPage             = 1;
    }

    clearComplianceSignalFilter() {
        this.backupComplianceSignalFilter = null;
        this.backupCurrentPage            = 1;
    }

    closeComplianceSignalPopup() {
        this.complianceSignalPopupOpen  = false;
        this.complianceSignalPopupLabel = '';
        this.complianceSignalPopupData  = [];
    }

    handleComplianceSignalPopupOverlayClick(evt) {
        if (evt.target === evt.currentTarget) this.closeComplianceSignalPopup();
    }

    handleBackupPageSize(evt) {
        this.backupPageSize    = parseInt(evt.currentTarget.dataset.size, 10);
        this.backupCurrentPage = 1;
    }

    handleBackupPrevPage() {
        if (this.backupCurrentPage > 1) this.backupCurrentPage--;
    }

    handleBackupNextPage() {
        if (this.backupCurrentPage < this.backupTotalPages) this.backupCurrentPage++;
    }

    handleTimeSelect(evt) {
        this.selectedDays = parseInt(evt.currentTarget.dataset.days, 10);
        this.loadData();
    }

    handleRefresh() {
        this.loadData();
    }

    handleSearch(evt) {
        this.searchTerm = evt.target.value;
        this._applyFilters();
    }

    handleCohortFilter(evt) {
        this.selectedCohort = evt.currentTarget.dataset.cohort;
        this._applyFilters();
    }

    handleSort(evt) {
        const field = evt.currentTarget.dataset.field;
        if (field === this.sortField) {
            this.sortAsc = !this.sortAsc;
        } else {
            this.sortField = field;
            this.sortAsc   = false;
        }
        this._applyFilters();
    }

    handleRowClick(evt) {
        const account = evt.currentTarget.dataset.account;
        if (!account) return;
        this.acctModalAccount   = account;
        this.acctModalProduct   = this.selectedProduct;
        this.isAccountModalOpen = true;
    }

    handleCloseAccountModal() {
        this.isAccountModalOpen = false;
        this.acctModalAccount   = null;
        this.acctModalProduct   = null;
    }

    handleAccountModalCardClick(evt) {
        evt.stopPropagation();
    }

    // ── Backup org detail popup ──────────────────────────────────────────────

    _openBkOrgDetail(accountName) {
        this.orgDetailAccount = accountName;
        this.orgDetailOpen    = true;
        this.orgDetailRows    = [];
        this.orgExDetailRows  = [];
        this.userDetailRows   = [];
        this.orgDetailLoading = true;
        if (this.isBackupExceptionsTab) {
            getBackupOrgExceptions({ accountName })
                .then(json => {
                    this.orgExDetailRows  = JSON.parse(json) || [];
                    this.orgDetailLoading = false;
                })
                .catch(() => { this.orgDetailLoading = false; });
        } else if (this.isBackupActiveUsersTab) {
            getBackupUserDetail({ accountName })
                .then(json => {
                    this.userDetailRows   = JSON.parse(json) || [];
                    this.orgDetailLoading = false;
                })
                .catch(() => { this.orgDetailLoading = false; });
        } else {
            getBackupOrgDetail({ accountName })
                .then(json => {
                    this.orgDetailRows    = JSON.parse(json) || [];
                    this.orgDetailLoading = false;
                })
                .catch(() => { this.orgDetailLoading = false; });
        }
    }

    handleBkRowClick(evt) {
        const account = evt.currentTarget.dataset.account;
        if (account) this._openBkOrgDetail(account);
    }

    handleBkChartClick(evt) {
        if (!this._bkChartBarMap || !this._bkChartBarMap.length) return;
        const canvas = this.template.querySelector('.bk-top10-canvas');
        if (!canvas) return;
        const rect   = canvas.getBoundingClientRect();
        const scaleX = canvas.width / rect.width;
        const x      = (evt.clientX - rect.left) * scaleX;
        const hit    = this._bkChartBarMap.find(b => x >= b.xStart && x <= b.xEnd);
        if (!hit) return;
        if (this.isBackupCustomerComplianceTab) {
            const flagKey = hit.account; // e.g. '_sig_stale60'
            const signalEntry = this.complianceSignalData.find(s => s.account === flagKey);
            const label = signalEntry ? signalEntry.label : flagKey;
            const affected = this.backupChartComplianceRows.filter(r => r[flagKey]);
            this.complianceSignalPopupLabel = label;
            this.complianceSignalPopupData  = affected;
            this.complianceSignalPopupOpen  = true;
            // also filter the table behind the popup
            this.backupComplianceSignalFilter = flagKey;
            this.backupCurrentPage = 1;
            return;
        }
        this._openBkOrgDetail(hit.account);
    }

    handleBkDonutClick(evt) {
        if (!this.isBackupOrgInventoryTab && !this.isBackupCustomerComplianceTab) return;
        if (!this._bkDonutSegmentMap || !this._bkDonutSegmentMap.length) return;
        const canvas = this.template.querySelector('.bk-breakdown-canvas');
        if (!canvas) return;
        const rect   = canvas.getBoundingClientRect();
        const scaleX = canvas.width  / rect.width;
        const scaleY = canvas.height / rect.height;
        const x  = (evt.clientX - rect.left) * scaleX;
        const y  = (evt.clientY - rect.top)  * scaleY;
        const cx = canvas.width  / 2;
        const cy = canvas.height / 2;
        const R  = Math.min(cx, cy) - 10;
        const ri = R * 0.58;
        const dx = x - cx;
        const dy = y - cy;
        const dist = Math.sqrt(dx * dx + dy * dy);
        if (dist < ri || dist > R) return;

        // Normalize click angle to same space as segment angles: [-π/2, 3π/2)
        let clickAngle = Math.atan2(dy, dx);
        if (clickAngle < -Math.PI / 2) clickAngle += 2 * Math.PI;

        const hit = this._bkDonutSegmentMap.find(s => clickAngle >= s.startAngle && clickAngle < s.endAngle);
        if (!hit) return;

        // Customer Health tab: toggle urgency filter, don't open popup
        if (this.isBackupCustomerComplianceTab) {
            this.backupComplianceUrgencyFilter = this.backupComplianceUrgencyFilter === hit.label ? null : hit.label;
            this.backupCurrentPage = 1;
            return;
        }

        const accounts      = this.backupChartAccounts;
        const singleAccount = accounts && accounts.size === 1 ? [...accounts][0] : null;

        this.donutOrgTypeFilter    = hit.label; // 'Production' or 'Sandbox'
        this.donutSingleAccount    = singleAccount;
        this.donutOrgDetailOpen    = true;
        this.donutOrgDetailRows    = [];
        this.donutOrgDetailLoading = true;

        if (singleAccount) {
            // Reuse per-account org detail; filter by type in donutOrgDetailDisplayRows
            getBackupOrgDetail({ accountName: singleAccount })
                .then(json => {
                    this.donutOrgDetailRows    = JSON.parse(json) || [];
                    this.donutOrgDetailLoading = false;
                })
                .catch(() => { this.donutOrgDetailLoading = false; });
        } else {
            getBackupAllOrgsByType({ orgType: hit.label })
                .then(json => {
                    this.donutOrgDetailRows    = JSON.parse(json) || [];
                    this.donutOrgDetailLoading = false;
                })
                .catch(() => { this.donutOrgDetailLoading = false; });
        }
    }

    closeBkDonutOrgDetail() {
        this.donutOrgDetailOpen    = false;
        this.donutOrgTypeFilter    = null;
        this.donutSingleAccount    = null;
        this.donutOrgDetailRows    = [];
    }

    handleBkDonutOrgDetailOverlayClick(evt) {
        if (evt.target === evt.currentTarget) this.closeBkDonutOrgDetail();
    }

    closeBkOrgDetail() {
        this.orgDetailOpen    = false;
        this.orgDetailAccount = null;
        this.orgDetailRows    = [];
        this.orgExDetailRows  = [];
        this.userDetailRows   = [];
    }

    handleOrgDetailOverlayClick(evt) {
        if (evt.target === evt.currentTarget) this.closeBkOrgDetail();
    }

    handleOrgDetailCardClick(evt) {
        evt.stopPropagation();
    }

    handleExpandChart(evt) {
        this.expandedChart = evt.currentTarget.dataset.chart;
    }

    handleCloseModal() {
        this.expandedChart = null;
    }

    handleModalOverlayClick(evt) {
        if (evt.target === evt.currentTarget) this.expandedChart = null;
    }

    // ── Canvas charts ────────────────────────────────────────────────────────

    _drawCharts() {
        try { this._drawDonut();  } catch(e) { /* silent */ }
        try { this._drawBar();    } catch(e) { /* silent */ }
        try { this._drawTrends(); } catch(e) { /* silent */ }
    }

    _drawDonut() {
        const canvas = this.template.querySelector('.donut-canvas');
        if (!canvas) return;
        const ctx   = canvas.getContext('2d');
        const data  = this.cohortLegend;
        const total = data.reduce((s, d) => s + d.count, 0);
        if (total === 0) return;

        const W  = canvas.width;
        const H  = canvas.height;
        const cx = W / 2;
        const cy = H / 2;
        const R  = Math.min(cx, cy) - 10;
        const r  = R * 0.58;

        ctx.clearRect(0, 0, W, H);

        let angle = -Math.PI / 2;
        data.forEach(d => {
            if (d.count === 0) return;
            const sweep = (d.count / total) * 2 * Math.PI;
            ctx.beginPath();
            ctx.moveTo(cx, cy);
            ctx.arc(cx, cy, R, angle, angle + sweep);
            ctx.closePath();
            ctx.fillStyle = COHORT_COLORS[d.label] || '#ccc';
            ctx.fill();
            angle += sweep;
        });

        // Donut hole
        ctx.beginPath();
        ctx.arc(cx, cy, r, 0, 2 * Math.PI);
        ctx.fillStyle = '#FFFFFF';
        ctx.fill();

        // Center label
        ctx.fillStyle    = '#0D1B2A';
        ctx.font         = `bold 26px -apple-system,sans-serif`;
        ctx.textAlign    = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText(total, cx, cy - 8);
        ctx.font      = `13px -apple-system,sans-serif`;
        ctx.fillStyle = '#64748B';
        ctx.fillText('accounts', cx, cy + 14);
    }

    _drawBar() {
        const canvas = this.template.querySelector('.bar-canvas');
        if (!canvas) return;
        const data = [...this.filteredData]
            .sort((a, b) => (b.total_events || 0) - (a.total_events || 0))
            .slice(0, 10);
        this._paintBar(canvas, data, d => d.total_events || 0, fmt);
    }

    _drawBreakdownDonut() {
        const canvas = this.template.querySelector('.bk-breakdown-canvas');
        if (!canvas) return;
        const data  = this.backupBreakdownData;
        const total = data.reduce((s, d) => s + d.value, 0);
        const ctx   = canvas.getContext('2d');
        const W = canvas.width, H = canvas.height;
        const cx = W / 2, cy = H / 2;
        const R  = Math.min(cx, cy) - 10;
        const r  = R * 0.58;

        ctx.clearRect(0, 0, W, H);
        if (total === 0) { this._bkDonutSegmentMap = []; return; }

        this._bkDonutSegmentMap = [];
        let angle = -Math.PI / 2;
        data.forEach(d => {
            if (d.value === 0) return;
            const sweep = (d.value / total) * 2 * Math.PI;
            ctx.beginPath();
            ctx.moveTo(cx, cy);
            ctx.arc(cx, cy, R, angle, angle + sweep);
            ctx.closePath();
            ctx.fillStyle = d.color;
            ctx.fill();
            this._bkDonutSegmentMap.push({ label: d.label, display: d.display, color: d.color, startAngle: angle, endAngle: angle + sweep });
            angle += sweep;
        });

        ctx.beginPath();
        ctx.arc(cx, cy, r, 0, 2 * Math.PI);
        ctx.fillStyle = '#FFFFFF';
        ctx.fill();

        // Center: total value + subtitle
        const centerLabel = this.isBackupStorageTab
            ? ((total / 1024).toFixed(1) + ' GB')
            : fmt(total);
        const centerSub = this.isBackupOrgInventoryTab ? 'total orgs'
            : this.isBackupStorageTab                  ? 'total'
            : this.isBackupExceptionsTab               ? 'exceptions'
            : this.isBackupActiveUsersTab              ? 'total users'
            : 'total ops';
        ctx.fillStyle    = '#0D1B2A';
        ctx.font         = `bold 22px -apple-system,sans-serif`;
        ctx.textAlign    = 'center';
        ctx.textBaseline = 'middle';
        ctx.fillText(centerLabel, cx, cy - 8);
        ctx.font      = `12px -apple-system,sans-serif`;
        ctx.fillStyle = '#64748B';
        ctx.fillText(centerSub, cx, cy + 14);
    }

    _drawBackupActiveChart() {
        const canvas = this.template.querySelector('.bk-top10-canvas');
        if (!canvas) return;
        if (this.isBackupOrgInventoryTab) {
            this._bkChartBarMap = this._paintBar(canvas, this.top10ByOrgs,        d => d.total_orgs       || 0, v => String(v));
        } else if (this.isBackupStorageTab) {
            this._bkChartBarMap = this._paintBar(canvas, this.top10ByStorage,     d => d.total_db_mb      || 0, v => (v / 1024).toFixed(1) + ' GB');
        } else if (this.isBackupExceptionsTab) {
            this._bkChartBarMap = this._paintBar(canvas, this.top10ByExceptions,  d => d.total_exceptions || 0, v => String(v));
        } else if (this.isBackupActiveUsersTab) {
            this._bkChartBarMap = this._paintBar(canvas, this.top10ByActiveUsers, d => d.active_users     || 0, v => String(v));
        } else if (this.isBackupCustomerComplianceTab) {
            this._bkChartBarMap = this._paintBar(
                canvas, this.complianceSignalData,
                d => d.count,
                v => String(v),
                d => d.color
            );
        } else {
            this._bkChartBarMap = this._paintBar(canvas, this.top10ByOps,         d => d.total_ops        || 0, fmt);
        }
    }

    _paintBar(canvas, data, getVal, fmtY, getColor) {
        if (!data || data.length === 0) return [];
        // Stretch canvas to fill its card container (card padding is 18px each side)
        const containerW = canvas.parentElement ? canvas.parentElement.clientWidth - 36 : canvas.width;
        if (containerW > 0) canvas.width = containerW;
        const ctx    = canvas.getContext('2d');
        const W      = canvas.width;
        const H      = canvas.height;
        const pt = 16, pr = 16, pb = 70, pl = 52;
        const chartW = W - pl - pr;
        const chartH = H - pt - pb;
        const maxVal = Math.max(...data.map(d => getVal(d)), 1);

        ctx.clearRect(0, 0, W, H);

        const barW = (chartW / data.length) * 0.65;
        const gap  = (chartW / data.length) * 0.35;

        [0, 0.25, 0.5, 0.75, 1].forEach(frac => {
            const y = pt + chartH * (1 - frac);
            ctx.strokeStyle = '#E2E8F0';
            ctx.lineWidth   = 1;
            ctx.beginPath(); ctx.moveTo(pl, y); ctx.lineTo(pl + chartW, y); ctx.stroke();
            ctx.fillStyle    = '#94A3B8';
            ctx.font         = '10px -apple-system,sans-serif';
            ctx.textAlign    = 'right';
            ctx.textBaseline = 'middle';
            ctx.fillText(fmtY(Math.round(maxVal * frac)), pl - 6, y);
        });

        data.forEach((d, i) => {
            const x    = pl + i * (chartW / data.length) + gap / 2;
            const barH = chartH * (getVal(d) / maxVal);
            const y    = pt + chartH - barH;

            ctx.fillStyle = getColor ? getColor(d) : (i === 0 ? '#FF355E' : '#1E3A8A');
            ctx.beginPath();
            ctx.roundRect
                ? ctx.roundRect(x, y, barW, barH, [3, 3, 0, 0])
                : ctx.rect(x, y, barW, barH);
            ctx.fill();

            ctx.save();
            ctx.translate(x + barW / 2, pt + chartH + 8);
            ctx.rotate(-Math.PI / 4);
            ctx.fillStyle    = '#334155';
            ctx.font         = '10px -apple-system,sans-serif';
            ctx.textAlign    = 'right';
            ctx.textBaseline = 'middle';
            const raw = d.label || d.account || '';
            const lbl = raw.length > 18 ? raw.substring(0, 18) + '…' : raw;
            ctx.fillText(lbl, 0, 0);
            ctx.restore();
        });

        return data.map((d, i) => {
            const x = pl + i * (chartW / data.length) + gap / 2;
            return { account: d.account, xStart: x, xEnd: x + barW };
        });
    }

    // ── Trend charts ─────────────────────────────────────────────────────────

    _drawTrends() {
        if (!this.trendData) return;
        const td = this.trendData;
        const deployCanvas  = this.template.querySelector('.deploy-trend-canvas');
        const featureCanvas = this.template.querySelector('.feature-trend-canvas');
        if (deployCanvas)  this._drawLineChart(deployCanvas,  td.weeks, this._deploySeries(td));
        if (featureCanvas) this._drawLineChart(featureCanvas, td.weeks, this._top5Features(td));
    }

    _drawModalChart() {
        const canvas = this.template.querySelector('.modal-trend-canvas');
        if (!canvas || !this.trendData) return;
        const series = this.expandedChart === 'deploy'
            ? this._deploySeries(this.trendData)
            : this._top5Features(this.trendData);
        this._drawLineChart(canvas, this.trendData.weeks, series);
    }

    _deploySeries(td) {
        if (this.isNativeApps) {
            return [
                { label: 'Manual',   data: td.deploys_manual   || [] },
                { label: 'Pipeline', data: td.deploys_pipeline || [] }
            ];
        }
        if (this.isBackupArchive) {
            return [
                { label: 'Backups',  data: td.backups  || [] },
                { label: 'Archives', data: td.archives || [] }
            ];
        }
        if (this.isDataMigrator) {
            return [
                { label: 'Migrations', data: td.migrations || [] },
                { label: 'Retrieves',  data: td.retrieves  || [] }
            ];
        }
        return [{ label: 'Deploys', data: td.deploys_manual || [] }];
    }

    _top5Features(td) {
        let keys;
        if (this.isNativeApps) {
            keys = [
                { key: 'commits',              label: 'Commits'         },
                { key: 'branches',             label: 'Branches'        },
                { key: 'validates',            label: 'Validates'       },
                { key: 'pipeline_runs',        label: 'Pipeline Runs'   },
                { key: 'peer_reviews',         label: 'Peer Reviews'    },
                { key: 'code_scans',           label: 'Code Scans'      },
                { key: 'rollbacks',            label: 'Rollbacks'       },
                { key: 'smart_merges',         label: 'Smart Merges'    },
                { key: 'code_coverage',        label: 'Code Coverage'   },
                { key: 'snapshots',            label: 'Snapshots'       },
                { key: 'overwrite_protection', label: 'Overwrite Prot.' }
            ];
        } else if (this.isCloudDevops) {
            keys = [
                { key: 'commits',       label: 'Commits'       },
                { key: 'branches',      label: 'Branches'      },
                { key: 'validates',     label: 'Validates'     },
                { key: 'pipeline_runs', label: 'Pipeline Runs' },
                { key: 'smart_merges',  label: 'Smart Merges'  },
                { key: 'code_scans',    label: 'Code Scans'    },
                { key: 'rollbacks',     label: 'Rollbacks'     }
            ];
        } else if (this.isBackupArchive) {
            keys = [
                { key: 'archives', label: 'Archives' },
                { key: 'restores', label: 'Restores' },
                { key: 'exports',  label: 'Exports'  }
            ];
        } else if (this.isDataMigrator) {
            keys = [
                { key: 'retrieves', label: 'Retrieves' }
            ];
        } else {
            keys = [
                { key: 'commits',       label: 'Commits'       },
                { key: 'branches',      label: 'Branches'      },
                { key: 'validates',     label: 'Validates'     },
                { key: 'pipeline_runs', label: 'Pipeline Runs' },
                { key: 'smart_merges',  label: 'Smart Merges'  },
                { key: 'code_scans',    label: 'Code Scans'    },
                { key: 'rollbacks',     label: 'Rollbacks'     },
                { key: 'backups',       label: 'Backups'       },
                { key: 'archives',      label: 'Archives'      },
                { key: 'restores',      label: 'Restores'      },
                { key: 'exports',       label: 'Exports'       },
                { key: 'migrations',    label: 'Migrations'    },
                { key: 'retrieves',     label: 'Retrieves'     }
            ];
        }
        return keys
            .map(f => ({ label: f.label, data: td[f.key] || [], total: (td[f.key] || []).reduce((s, v) => s + v, 0) }))
            .sort((a, b) => b.total - a.total)
            .slice(0, 5)
            .map(({ label, data }) => ({ label, data }));
    }

    _drawLineChart(canvas, weeks, series) {
        if (!canvas || !weeks || weeks.length === 0 || !series.length) return;
        const ctx    = canvas.getContext('2d');
        const W      = canvas.width;
        const H      = canvas.height;
        const pt = 12, pr = 12, pb = 52, pl = 50;
        const chartW = W - pl - pr;
        const chartH = H - pt - pb;
        const n      = weeks.length;
        const COLORS = ['#FF355E', '#1E3A8A', '#059669', '#F59E0B', '#8B5CF6', '#EC4899', '#0EA5E9'];

        const maxVal = Math.max(...series.flatMap(s => s.data.map(v => v || 0)), 1);
        ctx.clearRect(0, 0, W, H);

        // Grid + Y labels
        [0, 0.25, 0.5, 0.75, 1].forEach(frac => {
            const y = pt + chartH * (1 - frac);
            ctx.strokeStyle = '#E2E8F0';
            ctx.lineWidth   = 1;
            ctx.beginPath(); ctx.moveTo(pl, y); ctx.lineTo(pl + chartW, y); ctx.stroke();
            ctx.fillStyle    = '#94A3B8';
            ctx.font         = '9px -apple-system,sans-serif';
            ctx.textAlign    = 'right';
            ctx.textBaseline = 'middle';
            ctx.fillText(fmt(Math.round(maxVal * frac)), pl - 4, y);
        });

        // X labels (every ~8 points, always last)
        const xStep = Math.max(1, Math.ceil(n / 8));
        weeks.forEach((w, i) => {
            if (i % xStep !== 0 && i !== n - 1) return;
            const x = n > 1 ? pl + (i / (n - 1)) * chartW : pl + chartW / 2;
            ctx.save();
            ctx.translate(x, pt + chartH + 5);
            ctx.rotate(-Math.PI / 5);
            ctx.fillStyle    = '#94A3B8';
            ctx.font         = '9px -apple-system,sans-serif';
            ctx.textAlign    = 'right';
            ctx.textBaseline = 'top';
            ctx.fillText(String(w).substring(5), 0, 0);
            ctx.restore();
        });

        // Lines + dots
        series.forEach((s, si) => {
            const color = COLORS[si % COLORS.length];
            ctx.strokeStyle = color;
            ctx.lineWidth   = 2;
            ctx.lineJoin    = 'round';
            ctx.lineCap     = 'round';
            ctx.beginPath();
            s.data.forEach((v, i) => {
                const x = n > 1 ? pl + (i / (n - 1)) * chartW : pl + chartW / 2;
                const y = pt + chartH * (1 - (v || 0) / maxVal);
                i === 0 ? ctx.moveTo(x, y) : ctx.lineTo(x, y);
            });
            ctx.stroke();
            s.data.forEach((v, i) => {
                const x = n > 1 ? pl + (i / (n - 1)) * chartW : pl + chartW / 2;
                const y = pt + chartH * (1 - (v || 0) / maxVal);
                ctx.beginPath();
                ctx.arc(x, y, 2.5, 0, 2 * Math.PI);
                ctx.fillStyle = color;
                ctx.fill();
            });
        });

        // Legend
        const legendY = H - 10;
        const legendItemW = Math.min(130, (W - pl - pr) / series.length);
        series.forEach((s, si) => {
            const color = COLORS[si % COLORS.length];
            const lx    = pl + si * legendItemW;
            ctx.fillStyle = color;
            ctx.fillRect(lx, legendY - 4, 14, 3);
            ctx.fillStyle    = '#334155';
            ctx.font         = '9px -apple-system,sans-serif';
            ctx.textAlign    = 'left';
            ctx.textBaseline = 'middle';
            ctx.fillText(s.label, lx + 17, legendY - 2);
        });
    }

    // ── Cross-product (Who Uses What) ────────────────────────────────────────

    _loadCrossProduct() {
        this.cpLoading        = true;
        this.crossProductData = [];
        this.cpFocusedAccount = null;
        this.cpUserDetailData = [];
        this.newTenantsData   = [];
        this.ntError          = null;
        this.ntDiagnostic     = null;
        this.cpSelectedTab    = 'product_adoption';
        getCrossProductUsage({ days: this.selectedDays })
            .then(json => {
                this.crossProductData = JSON.parse(json) || [];
                this.cpLoading = false;
            })
            .catch(err => {
                this.error     = err.body?.message ?? err.message ?? 'Unknown error';
                this.cpLoading = false;
            });
    }

    _loadUserDetail(accountName) {
        this.cpUserDetailLoading = true;
        this.cpUserDetailData    = [];
        getCrossProductUserDetail({ accountName, days: this.selectedDays })
            .then(json => {
                this.cpUserDetailData    = JSON.parse(json) || [];
                this.cpUserDetailLoading = false;
            })
            .catch(() => { this.cpUserDetailLoading = false; });
    }

    _loadNewTenants() {
        if (this.newTenantsData.length > 0) return; // already loaded
        this.newTenantsLoading = true;
        this.ntError      = null;
        this.ntDiagnostic = null;
        getNewTenants({ days: this.selectedDays })
            .then(json => {
                const rows = JSON.parse(json) || [];
                // Apex returns a sentinel row when no real data was found —
                // pull it out and show as a diagnostic hint instead of a table row.
                const diagIdx = rows.findIndex(r => r.account === '__diagnostic__');
                if (diagIdx !== -1) {
                    this.ntDiagnostic = 'No matching events found. Event name discovery: ' + rows[diagIdx].user;
                    rows.splice(diagIdx, 1);
                }
                this.newTenantsData    = rows;
                this.newTenantsLoading = false;
            })
            .catch(err => {
                this.ntError           = (err && err.body && err.body.message) || (err && err.message) || 'Unknown error loading New Tenants';
                this.newTenantsLoading = false;
            });
    }

    handleCpSubtabSelect(evt) {
        this.cpSelectedTab = evt.currentTarget.dataset.tab;
        if (this.cpSelectedTab === 'new_tenants') this._loadNewTenants();
    }

    handleCpAccountClick(evt) {
        const account = evt.currentTarget.dataset.account;
        this.cpFocusedAccount = account;
        this.cpSelectedTab    = 'user_activity';
        this._loadUserDetail(account);
    }

    handleCpClearFocus() {
        this.cpFocusedAccount = null;
        this.cpUserDetailData = [];
        this.cpSelectedTab    = 'product_adoption';
    }

    handleCpSearch(evt) {
        this.cpSearchTerm = evt.target.value;
    }

    handleCpSort(evt) {
        const field = evt.currentTarget.dataset.field;
        if (field === this.cpSortField) {
            this.cpSortAsc = !this.cpSortAsc;
        } else {
            this.cpSortField = field;
            this.cpSortAsc   = false;
        }
    }

    handleNtSearch(evt) {
        this.ntSearchTerm = evt.target.value;
    }

    handleNtSort(evt) {
        const field = evt.currentTarget.dataset.field;
        if (field === this.ntSortField) {
            this.ntSortAsc = !this.ntSortAsc;
        } else {
            this.ntSortField = field;
            this.ntSortAsc   = false;
        }
    }
}
