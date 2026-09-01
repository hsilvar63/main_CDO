import { LightningElement, api, wire, track } from 'lwc';
import { getRecord } from 'lightning/uiRecordApi';
import ACCOUNT_NAME_FIELD from '@salesforce/schema/Account.Name';
import getAccountNames      from '@salesforce/apex/PostHogController.getAccountNames';
import getAvailableProducts from '@salesforce/apex/PostHogController.getAvailableProducts';
import getAccountDetail     from '@salesforce/apex/PostHogController.getAccountDetail';
import getAccountTrends     from '@salesforce/apex/PostHogController.getAccountTrends';
import getOrgSummary        from '@salesforce/apex/PostHogController.getOrgSummary';
import getOrgAudit          from '@salesforce/apex/PostHogController.getOrgAudit';
import getBackupOrgDetail   from '@salesforce/apex/PostHogController.getBackupOrgDetail';

// All possible products in display order
const ALL_PRODUCTS = [
    { key: 'native_apps',    label: 'Native Apps'      },
    { key: 'cloud_devops',   label: 'Cloud DevOps'     },
    { key: 'backup_archive', label: 'Backup & Archive' },
    { key: 'data_migrator',  label: 'Data Migrator'    }
];

// Metric rows per product — drives both the table and status cards
const FIELDS_BY_PRODUCT = {
    native_apps: [
        { label: 'Active Users',          key: 'users'                },
        { label: 'Deployments',           key: 'deploys'              },
        { label: 'Commits',               key: 'commits'              },
        { label: 'Branches Created',      key: 'branches'             },
        { label: 'Validates',             key: 'validates'            },
        { label: 'Pipeline Runs',         key: 'pipeline_runs'        },
        { label: 'Peer Reviews',          key: 'peer_reviews'         },
        { label: 'Code Scans',            key: 'code_scans'           },
        { label: 'Rollbacks',             key: 'rollbacks'            },
        { label: 'Smart Merges',          key: 'smart_merges'         },
        { label: 'Code Coverage',         key: 'code_coverage'        },
        { label: 'Snapshots',             key: 'snapshots'            },
        { label: 'Overwrite Protection',  key: 'overwrite_protection' },
        { label: 'Total Events',          key: 'total_events'         }
    ],
    cloud_devops: [
        { label: 'Active Users',          key: 'users'                },
        { label: 'Deployments',           key: 'deploys'              },
        { label: 'Commits',               key: 'commits'              },
        { label: 'Branches Created',      key: 'branches'             },
        { label: 'Validates',             key: 'validates'            },
        { label: 'Pipeline Runs',         key: 'pipeline_runs'        },
        { label: 'Smart Merges',          key: 'smart_merges'         },
        { label: 'Code Scans',            key: 'code_scans'           },
        { label: 'Rollbacks',             key: 'rollbacks'            },
        { label: 'Total Events',          key: 'total_events'         }
    ],
    backup_archive: [
        { label: 'Active Users',          key: 'users'                },
        { label: 'Backups',               key: 'backups'              },
        { label: 'Archives',              key: 'archives'             },
        { label: 'Restores',              key: 'restores'             },
        { label: 'Exports',               key: 'exports'              },
        { label: 'Total Events',          key: 'total_events'         }
    ],
    data_migrator: [
        { label: 'Active Users',          key: 'users'                },
        { label: 'Migrations',            key: 'migrations'           },
        { label: 'Retrieves',             key: 'retrieves'            },
        { label: 'Total Events',          key: 'total_events'         }
    ]
};

// Which keys appear in the Current Status cards (after Active Users + Cohort)
const STATUS_KEYS_BY_PRODUCT = {
    native_apps:    ['deploys', 'branches',  'validates',  'pipeline_runs'],
    cloud_devops:   ['deploys', 'commits',   'validates',  'pipeline_runs'],
    backup_archive: ['backups', 'archives',  'restores',   'exports'      ],
    data_migrator:  ['migrations', 'retrieves']
};

// Feature keys to compare for trend charts (native & cloud devops only)
const TREND_FEATURE_KEYS = {
    native_apps: [
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
    ],
    cloud_devops: [
        { key: 'commits',       label: 'Commits'       },
        { key: 'branches',      label: 'Branches'      },
        { key: 'validates',     label: 'Validates'     },
        { key: 'pipeline_runs', label: 'Pipeline Runs' },
        { key: 'smart_merges',  label: 'Smart Merges'  },
        { key: 'code_scans',    label: 'Code Scans'    },
        { key: 'rollbacks',     label: 'Rollbacks'     }
    ]
};

const CHART_COLORS = ['#FF355E', '#1E3A8A', '#059669', '#F59E0B', '#8B5CF6', '#EC4899', '#0EA5E9'];

const FIELD_LABELS = {
    deploys: 'Deployments', branches: 'Branches', validates: 'Validates',
    pipeline_runs: 'Pipeline Runs', commits: 'Commits', peer_reviews: 'Peer Reviews',
    backups: 'Backups', archives: 'Archives', restores: 'Restores', exports: 'Exports',
    migrations: 'Migrations', retrieves: 'Retrieves'
};

function getCohort(users) {
    if (users >= 30) return 'Enterprise';
    if (users >= 11) return 'Growth';
    if (users >= 3)  return 'Emerging';
    return 'Early Stage';
}

function fmt(n) {
    if (!n) return '0';
    if (n >= 1000000) return (n / 1000000).toFixed(1) + 'M';
    if (n >= 1000)    return (n / 1000).toFixed(1) + 'K';
    return String(n);
}

export default class FlosumAccountDashboard extends LightningElement {

    @api recordId;
    @api defaultProduct = 'native_apps';
    @api accountName;   // injected by usage-dashboard modal — bypasses account selector

    @wire(getRecord, { recordId: '$recordId', fields: [ACCOUNT_NAME_FIELD] })
    wiredAccount({ data, error }) {
        if (data) {
            const name = data.fields.Name.value;
            if (name && name !== this.selectedAccount) {
                this.selectedAccount = name;
                this.searchInput     = name;
                this._loadAvailableProducts();
            }
        }
    }

    @track accountNames       = [];
    @track searchInput        = '';
    @track showDropdown       = false;
    @track selectedLetter     = null;
    @track selectedAccount    = null;
    @track availableProducts  = [];
    @track selectedProduct    = null;
    @track accountDetail      = null;
    @track trendData          = null;
    @track orgCounts          = null;
    @track orgList            = [];    // per-org rows for native_apps org selector
    @track selectedOrgId      = null;  // null = all orgs aggregated
    @track backupOrgs         = [];    // per-org backup metrics for backup_archive
    @track isLoadingAccounts  = false;
    @track isLoadingProducts  = false;
    @track isLoadingDetail    = false;
    @track error              = null;

    _chartDrawn      = false;
    _trendChartDrawn = false;

    connectedCallback() {
        if (this.accountName) {
            this.selectedAccount = this.accountName;
            this.searchInput     = this.accountName;
            this._loadAvailableProducts();
        } else if (!this.recordId) {
            this._loadAccountNames();
        }
    }

    renderedCallback() {
        if (this.hasData && !this._chartDrawn) {
            this._drawHeartbeat();
        }
        if (this.showTrends && !this._trendChartDrawn) {
            this._drawTrendCharts();
        }
    }

    _loadAccountNames() {
        this.isLoadingAccounts = true;
        this.accountNames      = [];
        getAccountNames({})
            .then(json => {
                this.accountNames      = JSON.parse(json);
                this.isLoadingAccounts = false;
            })
            .catch(err => {
                this.error             = err.body?.message ?? err.message ?? 'Failed to load accounts';
                this.isLoadingAccounts = false;
            });
    }

    _loadAvailableProducts() {
        this.isLoadingProducts = true;
        this.availableProducts = [];
        this.selectedProduct   = null;
        this.accountDetail     = null;
        this.orgList           = [];
        this.selectedOrgId     = null;
        this.backupOrgs        = [];
        this._chartDrawn       = false;
        this.error             = null;

        getAvailableProducts({ accountName: this.selectedAccount })
            .then(json => {
                this.availableProducts = JSON.parse(json);
                this.isLoadingProducts = false;
                if (this.availableProducts.length > 0) {
                    const pref = this.defaultProduct;
                    this.selectedProduct = (pref && this.availableProducts.includes(pref))
                        ? pref
                        : this.availableProducts[0];
                    this._loadAccountDetail();
                }
            })
            .catch(err => {
                this.error             = err.body?.message ?? err.message ?? 'Failed to detect products';
                this.isLoadingProducts = false;
            });
    }

    _loadAccountDetail() {
        if (!this.selectedAccount || !this.selectedProduct) return;
        this.isLoadingDetail  = true;
        this.accountDetail    = null;
        this.trendData        = null;
        this.orgCounts        = null;
        this.error            = null;
        this._chartDrawn      = false;
        this._trendChartDrawn = false;

        getAccountDetail({
            productKey  : this.selectedProduct,
            accountName : this.selectedAccount,
            orgId       : this.selectedOrgId
        })
            .then(json => {
                this.accountDetail   = JSON.parse(json);
                this.isLoadingDetail = false;
            })
            .catch(err => {
                this.error           = err.body?.message ?? err.message ?? 'Failed to load account data';
                this.isLoadingDetail = false;
            });

        const isNative = this.selectedProduct === 'native_apps';
        const needsTrends = isNative || this.selectedProduct === 'cloud_devops';

        if (needsTrends) {
            getAccountTrends({
                productKey  : this.selectedProduct,
                accountName : this.selectedAccount,
                days        : 365,
                orgId       : this.selectedOrgId
            })
                .then(json => { this.trendData = JSON.parse(json); })
                .catch(() => {});

            getOrgSummary({ productKey: this.selectedProduct, days: 365 })
                .then(json => {
                    const map = JSON.parse(json) || {};
                    this.orgCounts = map[this.selectedAccount] || null;
                })
                .catch(() => {});
        }

        // Load per-org list for native_apps only (first time, or when org changes)
        if (isNative && this.orgList.length === 0) {
            getOrgAudit({ productKey: 'native_apps', accountName: this.selectedAccount })
                .then(json => {
                    const rows = JSON.parse(json) || [];
                    this.orgList = rows.map(o => ({
                        orgId      : o.org_id,
                        orgName    : o.org_name,
                        pkgVersion : o.pkg_version  || '',
                        licUsed    : o.licenses_used  || 0,
                        licTotal   : o.licenses_total || 0,
                        isSandbox  : o.org_type === 'Sandbox',
                        label      : o.org_name + (o.pkg_version ? '  ·  ' + o.pkg_version : '')
                    }));
                })
                .catch(() => {});
        }

        // Load per-org backup metrics for backup_archive
        if (this.selectedProduct === 'backup_archive') {
            getBackupOrgDetail({ accountName: this.selectedAccount })
                .then(json => { this.backupOrgs = JSON.parse(json) || []; })
                .catch(() => {});
        }
    }

    // ── Getters: controls ────────────────────────────────────────────────────

    get productButtons() {
        return ALL_PRODUCTS
            .filter(p => this.availableProducts.includes(p.key))
            .map(p => ({
                ...p,
                cssClass: 'seg-btn' + (p.key === this.selectedProduct ? ' seg-btn--active' : '')
            }));
    }

    get isStandaloneMode()     { return !this.recordId && !this.accountName; }
    get hasAvailableProducts() { return this.availableProducts.length > 0; }
    get showProductTabs()      { return this.hasAvailableProducts && !this.isLoadingProducts; }

    get accountPlaceholder() {
        return this.isLoadingAccounts ? 'Loading accounts…' : 'Search accounts…';
    }

    get filteredAccounts() {
        const q = (this.searchInput || '').toLowerCase();
        let list = this.accountNames;
        if (this.selectedLetter) {
            list = list.filter(n => n.charAt(0).toUpperCase() === this.selectedLetter);
        }
        if (q) {
            list = list.filter(n => n.toLowerCase().includes(q));
        }
        return list.slice(0, 50);
    }

    get allLetterClass() {
        return 'alpha-btn' + (this.selectedLetter == null ? ' alpha-btn--active' : '');
    }

    get alphaLetters() {
        const available = new Set(this.accountNames.map(n => n.charAt(0).toUpperCase()));
        return 'ABCDEFGHIJKLMNOPQRSTUVWXYZ'.split('').map(l => ({
            letter  : l,
            cssClass: 'alpha-btn'
                + (l === this.selectedLetter ? ' alpha-btn--active' : '')
                + (!available.has(l)         ? ' alpha-btn--empty'  : '')
        }));
    }

    get noResults() { return this.filteredAccounts.length === 0; }
    get hasData()   { return this.accountDetail != null && !this.isLoadingDetail; }

    get chartTitle() {
        if (this.selectedProduct === 'backup_archive') return 'Backup Daily Activity';
        if (this.selectedProduct === 'data_migrator')  return 'Migration Daily Activity';
        return 'Deployment Daily Heart Beat';
    }

    // ── Getters: content ─────────────────────────────────────────────────────

    get statusCards() {
        const windows = ((this.accountDetail || {}).windows) || {};
        const w90     = windows['90'] || {};
        const keys    = STATUS_KEYS_BY_PRODUCT[this.selectedProduct] || [];

        const cards = [
            { label: 'Active Users', value: fmt(w90.users)          },
            { label: 'Cohort',       value: getCohort(w90.users || 0) }
        ];
        keys.forEach(k => cards.push({ label: FIELD_LABELS[k] || k, value: fmt(w90[k]) }));
        return cards;
    }

    get tableRows() {
        const windows = ((this.accountDetail || {}).windows) || {};
        const fields  = FIELDS_BY_PRODUCT[this.selectedProduct] || [];
        return fields.map((f, i) => {
            const raw30  = ((windows['30']  || {})[f.key]) || 0;
            const raw90  = ((windows['90']  || {})[f.key]) || 0;
            const raw180 = ((windows['180'] || {})[f.key]) || 0;
            const raw365 = ((windows['365'] || {})[f.key]) || 0;

            // Prior-30d rate = (90d total - 30d total) / 2 — gives monthly rate for days 31–90
            const prior30 = (raw90 - raw30) / 2;
            let trend = 'neutral';
            if (f.key !== 'users') {
                if (prior30 === 0 && raw30 > 0)       trend = 'up';
                else if (prior30 > 0 && raw30 > prior30 * 1.10) trend = 'up';
                else if (prior30 > 0 && raw30 < prior30 * 0.90) trend = 'down';
            }

            const baseRowClass = i % 2 === 0 ? 'row-even' : 'row-odd';
            return {
                label     : f.label,
                d30       : fmt(raw30),
                d90       : fmt(raw90),
                d180      : fmt(raw180),
                d365      : fmt(raw365),
                avg       : fmt(Math.round(raw365 / 12.17)),
                rowClass  : baseRowClass,
                d30Class  : 'col-num' + (trend === 'up' ? ' trend-cell-up' : trend === 'down' ? ' trend-cell-down' : ''),
                trendUp   : trend === 'up',
                trendDown : trend === 'down'
            };
        });
    }

    get heartbeatEmpty() {
        const hb = ((this.accountDetail || {}).heartbeat) || [];
        return hb.length === 0;
    }

    get showOrgSelector() { return this.selectedProduct === 'native_apps' && this.orgList.length > 1; }

    get orgSelectorButtons() {
        const allActive = this.selectedOrgId == null;
        const all = { orgId: null, label: 'All Orgs', cssClass: 'org-btn' + (allActive ? ' org-btn--active' : ''), licUsed: 0, licTotal: 0, pkgVersion: '' };
        const orgs = this.orgList.map(o => ({
            ...o,
            cssClass: 'org-btn' + (this.selectedOrgId === o.orgId ? ' org-btn--active' : '')
        }));
        return [all, ...orgs];
    }

    get selectedOrgInfo() {
        if (!this.selectedOrgId) return null;
        return this.orgList.find(o => o.orgId === this.selectedOrgId) || null;
    }

    get showOrgCounts()   { return !!this.orgCounts && !this.selectedOrgInfo; }
    get orgCountsDisplay() {
        const p = this.orgCounts?.prod_orgs    || 0;
        const s = this.orgCounts?.sandbox_orgs || 0;
        return `${p} Production  /  ${s} Sandbox`;
    }
    get showTrends()      { return this.trendData?.weeks?.length > 0; }
    get isNativeApps()    { return this.selectedProduct === 'native_apps'; }
    get showBackupOrgs()  { return this.selectedProduct === 'backup_archive' && this.backupOrgs.length > 0; }
    get backupOrgRows() {
        return this.backupOrgs.map((o, i) => {
            const backupGb   = ((o.backup_mb  || 0) / 1024).toFixed(2);
            const archiveGb  = ((o.archive_mb || 0) / 1024).toFixed(2);
            const dbMb       = Math.round(o.db_mb || 0).toLocaleString();
            const weeklyHrs  = (o.weekly_hours || 0).toFixed(2);
            const completed  = o.completed  || 0;
            const exceptions = o.exceptions || 0;
            const orgName    = o.org_name;
            const isProd     = o.org_type === 'Production';
            const hasAlert   = exceptions > 0;
            let rowClass = i % 2 === 0 ? 'row-even' : 'row-odd';
            if (hasAlert && isProd) rowClass += ' row-alert-prod';
            else if (hasAlert)      rowClass += ' row-alert';
            return {
                orgName, orgType: o.org_type, region: o.region,
                backupGb, archiveGb, dbMb, weeklyHrs,
                completed, exceptions,
                lastSeen : o.last_seen,
                isProd, hasAlert,
                rowClass
            };
        });
    }
    get deployTrendTitle() {
        return this.isNativeApps ? 'Deployment Trends — Manual vs Pipeline · weekly' : 'Deployment Trends · weekly';
    }

    // ── Event handlers ────────────────────────────────────────────────────────

    handleProductSelect(evt) {
        this.selectedProduct = evt.currentTarget.dataset.key;
        this.accountDetail   = null;
        this.orgList         = [];
        this.selectedOrgId   = null;
        this.backupOrgs      = [];
        this._chartDrawn     = false;
        this._loadAccountDetail();
    }

    handleOrgSelect(evt) {
        const orgId = evt.currentTarget.dataset.orgid || null;
        if (this.selectedOrgId === orgId) return;
        this.selectedOrgId = orgId;
        this._loadAccountDetail();
    }

    handleLetterSelect(evt) {
        const letter = evt.currentTarget.dataset.letter || null;
        this.selectedLetter = (!letter || this.selectedLetter === letter) ? null : letter;
        this.searchInput    = '';
        this.showDropdown   = true;
    }

    handleSearchInput(evt) {
        this.searchInput    = evt.target.value;
        this.showDropdown   = true;
        if (evt.target.value) this.selectedLetter = null;
    }

    handleFocus() {
        this.showDropdown = true;
    }

    handleFocusOut() {
        // eslint-disable-next-line @lwc/lwc/no-async-operation
        setTimeout(() => { this.showDropdown = false; }, 150);
    }

    handleAccountSelect(evt) {
        this.selectedAccount = evt.currentTarget.dataset.name;
        this.searchInput     = this.selectedAccount;
        this.showDropdown    = false;
        this.selectedLetter  = null;
        this._loadAvailableProducts();
    }

    // ── Trend charts ─────────────────────────────────────────────────────────

    _drawTrendCharts() {
        if (!this.trendData) return;
        const td = this.trendData;
        const deployCanvas  = this.template.querySelector('.deploy-trend-canvas');
        const featureCanvas = this.template.querySelector('.feature-trend-canvas');
        if (deployCanvas)  {
            this._drawLineChart(deployCanvas,  td.weeks, this._deploySeries(td));
            this._trendChartDrawn = true;
        }
        if (featureCanvas) {
            this._drawLineChart(featureCanvas, td.weeks, this._top5Features(td));
            this._trendChartDrawn = true;
        }
    }

    _deploySeries(td) {
        if (this.isNativeApps) {
            return [
                { label: 'Manual',   data: td.deploys_manual   || [] },
                { label: 'Pipeline', data: td.deploys_pipeline || [] }
            ];
        }
        return [{ label: 'Deploys', data: td.deploys_manual || [] }];
    }

    _top5Features(td) {
        const keys = TREND_FEATURE_KEYS[this.selectedProduct] || [];
        return keys
            .map(f => ({ label: f.label, data: td[f.key] || [], total: (td[f.key] || []).reduce((s, v) => s + v, 0) }))
            .sort((a, b) => b.total - a.total)
            .slice(0, 5)
            .map(({ label, data }) => ({ label, data }));
    }

    _drawLineChart(canvas, weeks, series) {
        if (!canvas || !weeks || weeks.length === 0 || !series.length) return;
        canvas.width = canvas.offsetWidth || 760;
        const ctx    = canvas.getContext('2d');
        const W      = canvas.width;
        const H      = canvas.height;
        const pt = 12, pr = 12, pb = 52, pl = 46;
        const chartW = W - pl - pr;
        const chartH = H - pt - pb;
        const n      = weeks.length;

        const maxVal = Math.max(...series.flatMap(s => s.data.map(v => v || 0)), 1);
        ctx.clearRect(0, 0, W, H);

        // Grid + Y labels
        [0, 0.25, 0.5, 0.75, 1].forEach(frac => {
            const y = pt + chartH * (1 - frac);
            ctx.strokeStyle = '#E2E8F0'; ctx.lineWidth = 1;
            ctx.beginPath(); ctx.moveTo(pl, y); ctx.lineTo(pl + chartW, y); ctx.stroke();
            ctx.fillStyle = '#94A3B8'; ctx.font = '9px -apple-system,sans-serif';
            ctx.textAlign = 'right'; ctx.textBaseline = 'middle';
            ctx.fillText(fmt(Math.round(maxVal * frac)), pl - 4, y);
        });

        // X labels
        const xStep = Math.max(1, Math.ceil(n / 8));
        weeks.forEach((w, i) => {
            if (i % xStep !== 0 && i !== n - 1) return;
            const x = n > 1 ? pl + (i / (n - 1)) * chartW : pl + chartW / 2;
            ctx.save();
            ctx.translate(x, pt + chartH + 5);
            ctx.rotate(-Math.PI / 5);
            ctx.fillStyle = '#94A3B8'; ctx.font = '9px -apple-system,sans-serif';
            ctx.textAlign = 'right'; ctx.textBaseline = 'top';
            ctx.fillText(String(w).substring(5), 0, 0);
            ctx.restore();
        });

        // Lines + dots
        series.forEach((s, si) => {
            const color = CHART_COLORS[si % CHART_COLORS.length];
            ctx.strokeStyle = color; ctx.lineWidth = 2;
            ctx.lineJoin = 'round'; ctx.lineCap = 'round';
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
                ctx.beginPath(); ctx.arc(x, y, 2.5, 0, 2 * Math.PI);
                ctx.fillStyle = color; ctx.fill();
            });
        });

        // Legend
        const legendY    = H - 10;
        const legendItemW = Math.min(130, (W - pl - pr) / series.length);
        series.forEach((s, si) => {
            const color = CHART_COLORS[si % CHART_COLORS.length];
            const lx    = pl + si * legendItemW;
            ctx.fillStyle = color; ctx.fillRect(lx, legendY - 4, 14, 3);
            ctx.fillStyle = '#334155'; ctx.font = '9px -apple-system,sans-serif';
            ctx.textAlign = 'left'; ctx.textBaseline = 'middle';
            ctx.fillText(s.label, lx + 17, legendY - 2);
        });
    }

    // ── Canvas chart ─────────────────────────────────────────────────────────

    _drawHeartbeat() {
        const canvas = this.template.querySelector('.heartbeat-canvas');
        if (!canvas) return;

        const rawData = ((this.accountDetail || {}).heartbeat) || [];
        if (rawData.length === 0) return;

        this._chartDrawn = true;
        canvas.width     = canvas.offsetWidth || 760;

        const ctx    = canvas.getContext('2d');
        const W      = canvas.width;
        const H      = canvas.height;
        const pt = 16, pr = 16, pb = 36, pl = 44;
        const chartW = W - pl - pr;
        const chartH = H - pt - pb;

        const points = rawData.map(r => ({ day: String(r[0]), value: Number(r[1]) || 0 }));
        const maxVal = Math.max(...points.map(p => p.value), 1);

        ctx.clearRect(0, 0, W, H);

        ctx.strokeStyle = '#E2E8F0';
        ctx.lineWidth   = 1;
        [0, 0.25, 0.5, 0.75, 1].forEach(frac => {
            const y = pt + chartH * (1 - frac);
            ctx.beginPath();
            ctx.moveTo(pl, y);
            ctx.lineTo(pl + chartW, y);
            ctx.stroke();
            ctx.fillStyle    = '#94A3B8';
            ctx.font         = '10px -apple-system,sans-serif';
            ctx.textAlign    = 'right';
            ctx.textBaseline = 'middle';
            ctx.fillText(Math.round(maxVal * frac), pl - 4, y);
        });

        ctx.beginPath();
        points.forEach((p, i) => {
            const x = pl + (i / (points.length - 1 || 1)) * chartW;
            const y = pt + chartH * (1 - p.value / maxVal);
            if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
        });
        ctx.lineTo(pl + chartW, pt + chartH);
        ctx.lineTo(pl, pt + chartH);
        ctx.closePath();
        ctx.globalAlpha = 0.12;
        ctx.fillStyle   = '#1E3A8A';
        ctx.fill();
        ctx.globalAlpha = 1;

        ctx.beginPath();
        ctx.strokeStyle = '#1E3A8A';
        ctx.lineWidth   = 1.5;
        points.forEach((p, i) => {
            const x = pl + (i / (points.length - 1 || 1)) * chartW;
            const y = pt + chartH * (1 - p.value / maxVal);
            if (i === 0) ctx.moveTo(x, y); else ctx.lineTo(x, y);
        });
        ctx.stroke();

        const step = Math.max(1, Math.floor(points.length / 6));
        ctx.fillStyle    = '#94A3B8';
        ctx.font         = '10px -apple-system,sans-serif';
        ctx.textAlign    = 'center';
        ctx.textBaseline = 'top';
        for (let i = 0; i < points.length; i += step) {
            const x = pl + (i / (points.length - 1 || 1)) * chartW;
            ctx.fillText(points[i].day.substring(5), x, pt + chartH + 6);
        }
    }
}
