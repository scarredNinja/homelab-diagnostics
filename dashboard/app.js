// automation/dashboard/app.js
let statusData = null;

async function fetchStatus() {
    console.log("Fetching homelab status...");
    try {
        const response = await fetch('data/status.json?t=' + Date.now());
        if (!response.ok) {
            throw new Error(`HTTP error! status: ${response.status}`);
        }
        statusData = await response.json();
        updateDashboard(statusData);
    } catch (error) {
        console.error("Failed to fetch status:", error);
        document.getElementById('overall-health-text').innerText = "Unreachable";
        document.getElementById('overall-health-text').className = "status-critical";
        
        const dot = document.getElementById('overall-status-dot');
        dot.className = "status-indicator indicator-critical";
        
        document.getElementById('llm-insight-text').innerText = "Error loading status file. Verify status.json is generated and readable.";
    }
    
    // Also fetch history files for timeline bar
    fetchHistory();
}

async function fetchHistory() {
    try {
        const today = new Date();
        const formatDate = (date) => {
            const yyyy = date.getFullYear();
            const mm = String(date.getMonth() + 1).padStart(2, '0');
            const dd = String(date.getDate()).padStart(2, '0');
            return `${yyyy}-${mm}-${dd}`;
        };
        
        const todayStr = formatDate(today);
        const todayUrl = `data/history-${todayStr}.json?t=` + Date.now();
        
        let todayData = [];
        try {
            const response = await fetch(todayUrl);
            if (response.ok) {
                todayData = await response.json();
            }
        } catch (e) {
            console.warn("Could not load today's history:", e);
        }
        
        let combinedData = todayData;
        if (!Array.isArray(combinedData)) {
            combinedData = [];
        }
        
        if (combinedData.length < 40) {
            const yesterday = new Date();
            yesterday.setDate(today.getDate() - 1);
            const yesterdayStr = formatDate(yesterday);
            const yesterdayUrl = `data/history-${yesterdayStr}.json?t=` + Date.now();
            
            let yesterdayData = [];
            try {
                const response = await fetch(yesterdayUrl);
                if (response.ok) {
                    yesterdayData = await response.json();
                }
            } catch (e) {
                console.warn("Could not load yesterday's history:", e);
            }
            
            if (Array.isArray(yesterdayData)) {
                combinedData = yesterdayData.concat(combinedData);
            }
        }
        
        renderTimeline(combinedData);
    } catch (e) {
        console.warn("Could not load history:", e);
    }
}

let allHistoryData = [];

function renderTimeline(historyData) {
    allHistoryData = historyData;
    const bar = document.getElementById('health-timeline-bar');
    if (!bar || !Array.isArray(historyData) || historyData.length === 0) return;
    
    bar.innerHTML = "";
    // Show up to the last 40 entries
    const items = historyData.slice(-40);
    
    // Check if we have any remediations in the history dataset
    const hasRemediations = historyData.some(item => Array.isArray(item.remediations) && item.remediations.length > 0);
    const viewRemediationsBtn = document.getElementById('view-remediations-btn');
    if (viewRemediationsBtn) {
        viewRemediationsBtn.style.display = hasRemediations ? "inline-flex" : "none";
    }
    
    items.forEach(item => {
        const node = document.createElement('div');
        node.className = "timeline-node";
        
        const status = item.overall_status || "Healthy";
        if (status === "Healthy") {
            node.classList.add("timeline-node-healthy");
        } else if (status === "Warning") {
            node.classList.add("timeline-node-warning");
        } else if (status === "Critical") {
            node.classList.add("timeline-node-critical");
        }
        
        const date = new Date(item.timestamp).toLocaleString();
        let titleText = `${date} - Status: ${status}\nBackups: ${item.domains?.backups}\nServices: ${item.domains?.services}\nHardware: ${item.domains?.hardware}\nNetwork: ${item.domains?.network}`;
        
        if (Array.isArray(item.remediations) && item.remediations.length > 0) {
            titleText += `\n\nRemediations:\n` + item.remediations.map(r => `• ${r.description || r.command} (${r.result})`).join("\n");
            // Add a border highlight to timeline node to show a remediation occurred
            node.style.border = "1.5px solid #3b82f6";
        }
        
        node.title = titleText;
        bar.appendChild(node);
    });
}

function showRemediationHistory() {
    const list = document.getElementById('remediation-history-list');
    const card = document.getElementById('remediation-history-card');
    if (!list || !card || !Array.isArray(allHistoryData)) return;
    
    list.innerHTML = "";
    
    // Filter items with remediations, newest first
    const items = allHistoryData.filter(item => Array.isArray(item.remediations) && item.remediations.length > 0).reverse();
    
    if (items.length === 0) {
        list.innerHTML = "<div class='timeline-loading'>No auto-remediations recorded.</div>";
        card.style.display = "block";
        return;
    }
    
    items.forEach(item => {
        const time = new Date(item.timestamp).toLocaleString();
        item.remediations.forEach(r => {
            const entry = document.createElement('div');
            entry.className = "history-entry";
            
            const isSuccess = r.result && r.result.includes("SUCCESS");
            const statusClass = isSuccess ? "badge-healthy" : "badge-critical";
            const statusLabel = isSuccess ? "Success" : "Failed";
            
            entry.innerHTML = `
                <span class="history-entry-time">${time}</span>
                <span class="history-entry-command" title="${r.command}">${r.command}</span>
                <span class="history-entry-status ${statusClass}">${statusLabel}</span>
            `;
            list.appendChild(entry);
        });
    });
    
    card.style.display = "block";
    card.scrollIntoView({ behavior: 'smooth' });
}

function updateDashboard(data) {
    // Overall status
    const statusText = document.getElementById('overall-health-text');
    const dot = document.getElementById('overall-status-dot');
    const timeText = document.getElementById('last-scan-time');
    
    statusText.innerText = data.overall_status || "Unknown";
    
    // Reset indicator classes
    statusText.className = "";
    dot.className = "status-indicator";
    
    if (data.overall_status === "Healthy") {
        statusText.classList.add("status-healthy");
        dot.classList.add("indicator-healthy");
    } else if (data.overall_status === "Warning") {
        statusText.classList.add("status-warning");
        dot.classList.add("indicator-warning");
    } else if (data.overall_status === "Critical") {
        statusText.classList.add("status-critical");
        dot.classList.add("indicator-critical");
    } else {
        dot.classList.add("indicator-unknown");
    }
    
    // Parse time
    if (data.timestamp) {
        const d = new Date(data.timestamp);
        timeText.innerText = d.toLocaleString();
    } else {
        timeText.innerText = "Unknown";
    }
    
    // Update individual domain badges & card hover styles
    const domains = ["backups", "services", "hardware", "network"];
    domains.forEach(dom => {
        const badge = document.getElementById(`badge-${dom}`);
        const card = document.getElementById(`card-${dom}`);
        const status = data.domains && data.domains[dom] ? data.domains[dom].status : "Unknown";
        
        if (badge) {
            badge.innerText = status;
            badge.className = "badge"; // Reset
            
            if (status === "Healthy") {
                badge.classList.add("badge-healthy");
            } else if (status === "Warning") {
                badge.classList.add("badge-warning");
            } else if (status === "Critical") {
                badge.classList.add("badge-critical");
            } else {
                badge.classList.add("badge-unknown");
            }
        }
    });

    // Update Hardware metric pills
    const hwMetrics = data.domains && data.domains.hardware && data.domains.hardware.metrics ? data.domains.hardware.metrics : null;
    const cpuStealPill = document.getElementById('pill-cpu-steal');
    const zfsArcPill = document.getElementById('pill-zfs-arc');
    const swapPill = document.getElementById('pill-swap-usage');

    if (cpuStealPill) {
        if (hwMetrics && typeof hwMetrics.cpu_steal_pct === 'number') {
            const st = hwMetrics.cpu_steal_pct;
            cpuStealPill.innerText = `Steal: ${st}%`;
            cpuStealPill.className = "metric-pill " + (st > 30 ? "pill-critical" : st > 10 ? "pill-warning" : "pill-healthy");
        } else {
            cpuStealPill.innerText = "Steal: --";
            cpuStealPill.className = "metric-pill";
        }
    }

    if (zfsArcPill) {
        if (hwMetrics && hwMetrics.arc_size_gib !== null) {
            const hit = hwMetrics.arc_hit_rate_pct !== null ? ` (${hwMetrics.arc_hit_rate_pct}%)` : '';
            zfsArcPill.innerText = `ARC: ${hwMetrics.arc_size_gib}G${hit}`;
            zfsArcPill.className = "metric-pill " + (hwMetrics.arc_hit_rate_pct !== null && hwMetrics.arc_hit_rate_pct < 70 ? "pill-warning" : "pill-healthy");
        } else {
            zfsArcPill.innerText = "ARC: --";
            zfsArcPill.className = "metric-pill";
        }
    }

    if (swapPill) {
        if (hwMetrics && (hwMetrics.swap_used || hwMetrics.swap_total)) {
            swapPill.innerText = `Swap: ${hwMetrics.swap_used || '0B'} / ${hwMetrics.swap_total || '0B'}`;
            swapPill.className = "metric-pill";
        } else {
            swapPill.innerText = "Swap: --";
            swapPill.className = "metric-pill";
        }
    }

    // Update Network Synology Dual-NIC metric pills
    const synNics = data.domains && data.domains.network && data.domains.network.synology_nics ? data.domains.network.synology_nics : null;
    const nic1Pill = document.getElementById('pill-syn-nic1');
    const nic2Pill = document.getElementById('pill-syn-nic2');

    if (nic1Pill) {
        if (synNics && synNics.nic1_media) {
            const st = synNics.nic1_media.status || (synNics.nic1_media.ping ? "UP" : "DOWN");
            nic1Pill.innerText = `NIC1 (100): ${st}`;
            nic1Pill.className = "metric-pill " + (st === "UP" ? "pill-healthy" : "pill-critical");
        } else {
            nic1Pill.innerText = "NIC1 (100): --";
            nic1Pill.className = "metric-pill";
        }
    }

    if (nic2Pill) {
        if (synNics && synNics.nic2_mgmt) {
            const st = synNics.nic2_mgmt.status || (synNics.nic2_mgmt.ping ? "UP" : "DOWN");
            nic2Pill.innerText = `NIC2 (60): ${st}`;
            nic2Pill.className = "metric-pill " + (st === "UP" ? "pill-healthy" : "pill-critical");
        } else {
            nic2Pill.innerText = "NIC2 (60): --";
            nic2Pill.className = "metric-pill";
        }
    }

    // Parse LLM insight / fallback rule summaries
    const insightText = document.getElementById('llm-insight-text');
    
    // Check if the vault monitoring logs show LLM updates or parse the logs directly
    // For now, let's pull a snippet of the analysis or display a status overview
    if (data.overall_status === "Healthy") {
        insightText.innerText = "System is fully operational. All core domains are reporting normal metrics. Backups verified, Swarm replicas matching, host metrics stable.";
    } else {
        let issues = [];
        domains.forEach(dom => {
            const status = data.domains && data.domains[dom] ? data.domains[dom].status : "Healthy";
            if (status !== "Healthy") {
                issues.push(`${dom.toUpperCase()} is reporting ${status}`);
            }
        });
        insightText.innerText = "Active issues detected:\n" + issues.map(i => "• " + i).join("\n") + "\n\nClick 'View Diagnostics' below to inspect logs.";
    }
    
    // Refresh log console if visible
    const consoleArea = document.getElementById('console-area');
    if (consoleArea.style.display !== "none") {
        const activeDom = document.getElementById('active-domain-name').innerText.toLowerCase();
        showLogs(activeDom);
    }
}

function showLogs(domain) {
    if (!statusData || !statusData.domains || !statusData.domains[domain]) {
        document.getElementById('console-output').innerText = `No log data available for domain: ${domain}`;
        return;
    }
    
    document.getElementById('active-domain-name').innerText = domain.charAt(0).toUpperCase() + domain.slice(1);
    
    const rawLog = statusData.domains[domain].log || "Log is empty.";
    document.getElementById('console-output').innerText = rawLog;
    document.getElementById('console-area').style.display = "block";
    
    // Smooth scroll down to console
    document.getElementById('console-area').scrollIntoView({ behavior: 'smooth' });
}

document.addEventListener('DOMContentLoaded', () => {
    // Initial fetch
    fetchStatus();
    
    // Refresh button click handler
    document.getElementById('refresh-btn').addEventListener('click', () => {
        const refreshBtn = document.getElementById('refresh-btn');
        refreshBtn.classList.add("btn-loading");
        fetchStatus().finally(() => {
            refreshBtn.classList.remove("btn-loading");
        });
    });
    
    // View Logs buttons handlers
    document.querySelectorAll('.view-log-btn').forEach(btn => {
        btn.addEventListener('click', (e) => {
            const domain = e.target.getAttribute('data-domain');
            showLogs(domain);
        });
    });
    
    // Close log console handler
    document.getElementById('close-console-btn').addEventListener('click', () => {
        document.getElementById('console-area').style.display = "none";
    });

    // View Remediation History button handler
    const viewRemediationsBtn = document.getElementById('view-remediations-btn');
    if (viewRemediationsBtn) {
        viewRemediationsBtn.addEventListener('click', () => {
            showRemediationHistory();
        });
    }

    // Close Remediation History button handler
    const closeHistoryBtn = document.getElementById('close-history-btn');
    if (closeHistoryBtn) {
        closeHistoryBtn.addEventListener('click', () => {
            document.getElementById('remediation-history-card').style.display = "none";
        });
    }
    
    // Refresh every 60 seconds
    setInterval(fetchStatus, 60000);
});
