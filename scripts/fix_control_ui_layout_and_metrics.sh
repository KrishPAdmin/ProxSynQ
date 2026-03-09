#!/usr/bin/env bash
set -euo pipefail

PI_HOST="10.26.0.170"
PI_USER="krishadmin"
ALL_HOSTS=("10.26.0.170" "10.26.0.171" "10.26.0.172" "10.26.0.173")
VM_HOSTS=("10.26.0.171" "10.26.0.172" "10.26.0.173")

cd "$HOME/proxsyncq"

mkdir -p rpi-control/control_ui/templates
mkdir -p rpi-control/prometheus

cat > rpi-control/prometheus/prometheus.yml <<'YAML'
global:
  scrape_interval: 10s
  evaluation_interval: 10s

scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets:
          - prometheus:9090

  - job_name: node_exporter
    static_configs:
      - targets:
          - 10.26.0.170:9100
          - 10.26.0.171:9100
          - 10.26.0.172:9100
          - 10.26.0.173:9100

  - job_name: node_agent
    metrics_path: /metrics
    static_configs:
      - targets:
          - 10.26.0.171:8000
          - 10.26.0.172:8000
          - 10.26.0.173:8000
YAML

cat > rpi-control/control_ui/templates/index.html <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>ProxSyncQ Control Plane</title>
  <link rel="icon" href="https://krishadmin.com/pics/LimeK.png" type="image/png" />
  <link rel="preconnect" href="https://fonts.googleapis.com" />
  <link rel="preconnect" href="https://fonts.gstatic.com" crossorigin />
  <link href="https://fonts.googleapis.com/css2?family=Source+Sans+3:wght@400;600;700;900&display=swap" rel="stylesheet" />
  <style>
    :root {
      --accent: #20fd14;
      --bg: #000;
      --glassBg: rgba(12, 14, 16, 0.78);
      --glassBorder: rgba(255, 255, 255, 0.10);
      --shadow: 0 12px 40px rgba(0, 0, 0, 0.35);
      --textSoft: rgb(190, 190, 190);
      --textSub: rgb(149, 149, 149);
      --titleShadow: 0 12px 30px rgba(0, 0, 0, 0.55);
      --headerH: 9rem;
    }

    *, *::before, *::after { margin: 0; padding: 0; box-sizing: border-box; }

    html {
      font-size: 62.5%;
      scroll-behavior: smooth;
      font-family: "Source Sans 3", system-ui, sans-serif;
    }

    body {
      background-color: var(--bg);
      color: #fff;
      line-height: 1.5;
      overflow-x: hidden;
      position: relative;
    }

    body::before {
      content: "";
      position: fixed;
      inset: 0;
      z-index: -2;
      background:
        linear-gradient(to right, rgba(0, 0, 0, 0.80), rgba(37, 44, 49, 0.80)),
        url("https://krishadmin.com/svg/common-bg.svg");
      background-position: center;
      background-size: cover;
    }

    body::after {
      content: "";
      position: fixed;
      inset: 0;
      z-index: -1;
      background-image: url("https://krishadmin.com/pics/LimeK.png");
      background-repeat: no-repeat;
      background-position: right 4% bottom 6%;
      background-size: clamp(180px, 22vw, 360px);
      opacity: 0.08;
    }

    a { text-decoration: none; color: inherit; }
    img { display: block; max-width: 100%; }
    button, input, select { font: inherit; }

    .glass-panel {
      background: var(--glassBg);
      backdrop-filter: blur(10px);
      -webkit-backdrop-filter: blur(10px);
      border: 1px solid var(--glassBorder);
      border-radius: 18px;
      box-shadow: var(--shadow);
    }

    .header {
      position: fixed;
      width: 100%;
      z-index: 1000;
      background: var(--glassBg);
      backdrop-filter: blur(10px);
      -webkit-backdrop-filter: blur(10px);
      border-bottom: 1px solid var(--glassBorder);
    }

    .header__content {
      display: flex;
      align-items: center;
      justify-content: space-between;
      padding: 1rem 5rem;
      min-height: var(--headerH);
    }

    .header__logo-container {
      display: flex;
      align-items: center;
      color: var(--accent);
      gap: 1.4rem;
    }

    .header__logo-img-cont {
      width: 7rem;
      height: 7rem;
      border-radius: 50px;
      overflow: hidden;
      background: var(--accent);
    }

    .header__logo-img {
      width: 100%;
      height: 100%;
      object-fit: cover;
    }

    .header__logo-sub {
      font-size: 1.8rem;
      text-transform: uppercase;
      font-weight: 900;
      letter-spacing: 1px;
    }

    .header__center-title {
      font-size: 2.4rem;
      font-weight: 900;
      letter-spacing: 2px;
      text-transform: uppercase;
      text-align: center;
      color: #fff;
      text-shadow: var(--titleShadow);
      flex: 1;
    }

    .header__links {
      display: flex;
      gap: 0.8rem;
      align-items: center;
    }

    .header__link {
      padding: 1.4rem 1.6rem;
      display: inline-block;
      font-size: 1.4rem;
      color: var(--accent);
      text-transform: uppercase;
      letter-spacing: 1px;
      font-weight: 900;
      border-radius: 10px;
      transition: background 0.2s ease, filter 0.2s ease;
    }

    .header__link:hover {
      filter: brightness(1.10);
      background: rgba(32, 253, 20, 0.10);
    }

    .site-socials {
      position: fixed;
      left: 0;
      top: 50%;
      transform: translateY(-50%);
      z-index: 900;
      border: 2px solid rgba(238, 238, 238, 0.85);
      border-left: 0;
      background: rgba(0, 0, 0, 0.30);
      backdrop-filter: blur(6px);
      -webkit-backdrop-filter: blur(6px);
    }

    .site-socials__link {
      width: 5.2rem;
      height: 5.2rem;
      display: flex;
      align-items: center;
      justify-content: center;
      border-bottom: 2px solid rgba(238, 238, 238, 0.85);
      transition: background 0.2s ease;
    }

    .site-socials__link:hover { background: rgba(255, 255, 255, 0.10); }

    .site-socials__link--last { border-bottom: 0; }

    .site-socials__icon, .main-footer__icon {
      width: 2.8rem;
      height: 2.8rem;
      object-fit: contain;
    }

    .topbar-wrap {
      padding-top: calc(var(--headerH) + 1.8rem);
      width: min(66.6vw, 124rem);
      margin: 0 auto;
      max-width: 92vw;
    }

    .topbar-panel {
      padding: 2rem 2.4rem;
      display: flex;
      align-items: center;
      justify-content: space-between;
      gap: 2rem;
    }

    .topbar-title {
      font-size: clamp(2.8rem, 3vw, 4.2rem);
      text-transform: uppercase;
      letter-spacing: 2px;
      font-weight: 900;
      text-shadow: var(--titleShadow);
    }

    .topbar-sub {
      margin-top: 0.7rem;
      font-size: 1.7rem;
      color: var(--textSoft);
      line-height: 1.6;
    }

    .btn {
      background: #000;
      color: var(--accent);
      text-transform: uppercase;
      letter-spacing: 2px;
      display: inline-block;
      font-weight: 900;
      border-radius: 8px;
      box-shadow: var(--shadow);
      transition: transform 0.2s ease, filter 0.2s ease, color 0.2s ease;
      border: 0;
      cursor: pointer;
      white-space: nowrap;
    }

    .btn:hover {
      transform: translateY(-2px);
      filter: brightness(1.04);
      color: #fff;
    }

    .btn--bg { padding: 1.4rem 3rem; font-size: 1.6rem; }
    .btn--med { padding: 1.1rem 2rem; font-size: 1.35rem; }
    .btn--theme { background: var(--accent); color: #000; }

    .section {
      padding: 2rem 0 6rem 0;
    }

    .section__panel {
      width: min(66.6vw, 124rem);
      margin: 0 auto 2rem auto;
      max-width: 92vw;
      padding: 2.4rem;
    }

    .section-heading {
      position: relative;
      display: flex;
      align-items: center;
      justify-content: center;
      margin-bottom: 2.2rem;
      min-height: 5rem;
    }

    .heading-sec__main {
      display: inline-block;
      font-size: clamp(2.6rem, 3vw, 4rem);
      text-transform: uppercase;
      letter-spacing: 3px;
      text-align: center;
      position: relative;
      text-shadow: var(--titleShadow);
      color: #fff;
      font-weight: 900;
    }

    .heading-sec__main::after {
      content: "";
      position: absolute;
      top: calc(100% + 1.1rem);
      height: 5px;
      width: 3rem;
      background: var(--accent);
      left: 50%;
      transform: translateX(-50%);
      border-radius: 999px;
    }

    .section-heading__action {
      position: absolute;
      right: 0;
      top: 50%;
      transform: translateY(-50%);
    }

    .grid-2 {
      display: grid;
      grid-template-columns: 1.2fr 0.8fr;
      gap: 2rem;
    }

    .grid-3 {
      display: grid;
      grid-template-columns: repeat(3, 1fr);
      gap: 2rem;
    }

    .node-grid {
      display: grid;
      grid-template-columns: repeat(auto-fit, minmax(38rem, 1fr));
      gap: 2rem;
    }

    .card {
      background: rgba(255,255,255,0.04);
      border: 1px solid rgba(255,255,255,0.08);
      border-radius: 16px;
      padding: 1.8rem;
      box-shadow: var(--shadow);
      min-width: 0;
    }

    .card h3 {
      font-size: 2rem;
      font-weight: 900;
      margin-bottom: 0.4rem;
      color: #fff;
      text-shadow: var(--titleShadow);
    }

    .muted { color: var(--textSub); }
    .mono {
      font-family: Consolas, monospace;
      word-break: break-word;
      overflow-wrap: anywhere;
    }

    .pill {
      display: inline-block;
      padding: 0.5rem 1rem;
      border-radius: 999px;
      font-size: 1.2rem;
      font-weight: 900;
      letter-spacing: 1px;
      text-transform: uppercase;
      margin-right: 0.8rem;
      margin-top: 0.8rem;
    }

    .good { background: rgba(32,253,20,0.18); color: #9aff8f; }
    .warn { background: rgba(251,191,36,0.18); color: #ffd86f; }
    .bad { background: rgba(248,113,113,0.18); color: #ff9a9a; }

    .stat-grid {
      display: grid;
      grid-template-columns: repeat(2, 1fr);
      gap: 1rem;
      margin-top: 1.6rem;
    }

    .stat {
      background: rgba(255,255,255,0.05);
      border-radius: 12px;
      padding: 1.2rem;
      border: 1px solid rgba(255,255,255,0.08);
      min-width: 0;
    }

    .stat__label {
      font-size: 1.2rem;
      text-transform: uppercase;
      letter-spacing: 1px;
      color: var(--textSub);
      font-weight: 900;
    }

    .stat__value {
      margin-top: 0.5rem;
      font-size: 2.1rem;
      font-weight: 900;
      color: #fff;
      word-break: break-word;
    }

    .form-grid {
      display: grid;
      grid-template-columns: repeat(5, 1fr);
      gap: 1rem;
      margin-top: 1.6rem;
    }

    label {
      display: block;
      font-size: 1.2rem;
      text-transform: uppercase;
      letter-spacing: 1px;
      color: var(--accent);
      font-weight: 900;
      margin-bottom: 0.6rem;
    }

    input, select {
      width: 100%;
      padding: 1.1rem 1.2rem;
      border-radius: 10px;
      border: 1px solid rgba(255,255,255,0.12);
      background: rgba(255,255,255,0.06);
      color: #fff;
      font-size: 1.5rem;
    }

    table {
      width: 100%;
      border-collapse: collapse;
      margin-top: 1.2rem;
      table-layout: fixed;
    }

    th, td {
      padding: 1rem;
      border-bottom: 1px solid rgba(255,255,255,0.08);
      text-align: left;
      font-size: 1.4rem;
      vertical-align: top;
      word-break: break-word;
      overflow-wrap: anywhere;
    }

    th {
      color: var(--accent);
      text-transform: uppercase;
      letter-spacing: 1px;
      font-weight: 900;
      font-size: 1.2rem;
      width: 16rem;
    }

    .ring-item {
      background: rgba(255,255,255,0.05);
      border: 1px solid rgba(255,255,255,0.08);
      border-radius: 14px;
      padding: 1.4rem;
      margin-top: 1.2rem;
    }

    .ring-item:first-child { margin-top: 0; }

    .status-message {
      margin: 1.2rem 0 0 0;
      text-align: center;
    }

    .main-footer {
      padding: 0 0 6rem 0;
    }

    .footer__panel {
      width: min(66.6vw, 124rem);
      margin: 0 auto;
      max-width: 92vw;
      padding: 2.6rem;
    }

    .main-footer__upper {
      display: grid;
      grid-template-columns: 1fr 1fr;
      gap: 4rem;
      margin-bottom: 2.2rem;
    }

    .heading-sm {
      color: #fff;
      font-size: 2rem;
      text-transform: uppercase;
      letter-spacing: 1px;
      font-weight: 900;
      text-shadow: 0 10px 24px rgba(0, 0, 0, 0.45);
    }

    .main-footer__social-cont {
      display: flex;
      gap: 1.2rem;
      margin-top: 1.4rem;
      flex-wrap: wrap;
    }

    .main-footer__short-desc, .footer-emails {
      margin-top: 1.4rem;
      font-size: 1.7rem;
      color: var(--textSoft);
      line-height: 1.7;
    }

    .main-footer__lower {
      padding-top: 2.2rem;
      border-top: 1px solid rgba(255, 255, 255, 0.12);
      font-size: 1.5rem;
      color: var(--textSub);
      text-align: center;
      font-weight: 700;
      letter-spacing: 1px;
    }

    @media (max-width: 1400px) {
      .section__panel, .topbar-wrap, .footer__panel { width: 92vw; }
    }

    @media (max-width: 1100px) {
      .grid-2, .grid-3, .main-footer__upper { grid-template-columns: 1fr; }
      .form-grid { grid-template-columns: 1fr 1fr; }
      .topbar-panel { flex-direction: column; align-items: stretch; }
      .header__center-title { display: none; }
    }

    @media (max-width: 700px) {
      .header__content { padding: 1rem 2rem; }
      .header__links { display: none; }
      .site-socials { display: none; }
      .form-grid { grid-template-columns: 1fr; }
      .stat-grid { grid-template-columns: 1fr; }
      .node-grid { grid-template-columns: 1fr; }
      .section-heading {
        flex-direction: column;
        gap: 1.6rem;
      }
      .section-heading__action {
        position: static;
        transform: none;
      }
    }
  </style>
</head>
<body>
  <header class="header">
    <div class="header__content">
      <a class="header__logo-container" href="https://krishadmin.com" aria-label="Home">
        <div class="header__logo-img-cont">
          <img src="https://krishadmin.com/pics/Krish_Patel_Face.jpg" alt="Krish Patel" class="header__logo-img" />
        </div>
        <span class="header__logo-sub">Krish Patel</span>
      </a>

      <div class="header__center-title">ProxSyncQ Control Plane</div>

      <div class="header__links">
        <a href="https://krishadmin.com" class="header__link">Home</a>
        <a href="https://co-op.krishadmin.com" class="header__link">Co-op</a>
        <a href="https://notes.krishadmin.com" class="header__link">Notes</a>
        <a href="https://server.krishadmin.com" class="header__link">Servers</a>
        <a href="https://contact.krishadmin.com" class="header__link">Contact</a>
        <a href="/logout" class="header__link">Logout</a>
      </div>
    </div>
  </header>

  <aside class="site-socials" aria-label="Social links">
    <a href="https://www.linkedin.com/in/krishadmin" class="site-socials__link" target="_blank" rel="noopener noreferrer" aria-label="LinkedIn">
      <img src="https://krishadmin.com/pics/Icon-LinkedIn.png" alt="" class="site-socials__icon" />
    </a>
    <a href="https://discord.com/users/290130274010923010" class="site-socials__link" target="_blank" rel="noopener noreferrer" aria-label="Discord">
      <img src="https://krishadmin.com/pics/Icon-Discord.png" alt="" class="site-socials__icon" />
    </a>
    <a href="https://github.com/KrishPAdmin" class="site-socials__link" target="_blank" rel="noopener noreferrer" aria-label="GitHub">
      <img src="https://krishadmin.com/pics/Icon-Github.png" alt="" class="site-socials__icon" />
    </a>
    <a href="https://www.youtube.com/channel/UCPOpecefAO1ub4KB50wDmjg" class="site-socials__link" target="_blank" rel="noopener noreferrer" aria-label="YouTube">
      <img src="https://krishadmin.com/pics/Icon-Youtube.png" alt="" class="site-socials__icon" />
    </a>
    <a href="https://www.instagram.com/krish_admin/" class="site-socials__link site-socials__link--last" target="_blank" rel="noopener noreferrer" aria-label="Instagram">
      <img src="https://krishadmin.com/pics/Icon-Instagram.png" alt="" class="site-socials__icon" />
    </a>
  </aside>

  <div class="topbar-wrap">
    <div class="glass-panel topbar-panel">
      <div>
        <div class="topbar-title">ProxSyncQ Control Plane</div>
        <div class="topbar-sub">
          Raspberry Pi hosted cluster operations dashboard for VM1, VM2, VM3, queue orchestration, Gluster failover visibility, and shared-storage monitoring.
        </div>
      </div>
      <div>
        <a href="http://10.26.0.170:3000" class="btn btn--bg btn--theme" target="_blank" rel="noopener noreferrer">Open Grafana</a>
      </div>
    </div>

    {% if message %}
    <div class="status-message">
      <span class="pill {% if status == 'ok' %}good{% elif status == 'partial' %}warn{% else %}bad{% endif %}">{{ status }} {{ message }}</span>
    </div>
    {% endif %}
  </div>

  <section class="section">
    <div class="glass-panel section__panel">
      <div class="section-heading">
        <span class="heading-sec__main">Cluster Operations</span>
      </div>

      <div class="grid-2">
        <div class="card">
          <h3>Submit Jobs</h3>
          <div class="muted" style="font-size:1.6rem;">Authenticated as <span class="mono">{{ username }}</span></div>
          <form method="post" action="/submit">
            <div class="form-grid">
              <div>
                <label for="target_ip">Target node</label>
                <select name="target_ip" id="target_ip">
                  <option value="10.26.0.171">COE892-VM-1</option>
                  <option value="10.26.0.172">COE892-VM-2</option>
                  <option value="10.26.0.173">COE892-VM-3</option>
                </select>
              </div>
              <div>
                <label for="job_type">Job type</label>
                <select name="job_type" id="job_type">
                  <option value="demo_write">demo_write</option>
                  <option value="sleep">sleep</option>
                </select>
              </div>
              <div>
                <label for="count">Count</label>
                <input type="number" id="count" name="count" value="5" min="1" max="50" />
              </div>
              <div>
                <label for="message_text">Message</label>
                <input type="text" id="message_text" name="message_text" value="hello from rpi control" />
              </div>
              <div>
                <label for="sleep_seconds">Sleep seconds</label>
                <input type="number" id="sleep_seconds" name="sleep_seconds" value="3" min="1" max="30" />
              </div>
            </div>
            <div style="margin-top:1.6rem;">
              <button type="submit" class="btn btn--med btn--theme">Submit Jobs</button>
            </div>
          </form>
        </div>

        <div class="card">
          <h3>Queue Summary</h3>
          <table>
            <tr><th>Name</th><td class="mono">{{ queue.name }}</td></tr>
            <tr><th>State</th><td>{{ queue.state }}</td></tr>
            <tr><th>Total messages</th><td>{{ queue.messages }}</td></tr>
            <tr><th>Ready</th><td>{{ queue.ready }}</td></tr>
            <tr><th>Unacked</th><td>{{ queue.unacked }}</td></tr>
            <tr><th>Consumers</th><td>{{ queue.consumers }}</td></tr>
            <tr><th>Error</th><td class="mono">{{ queue.error }}</td></tr>
          </table>
        </div>
      </div>
    </div>

    <div class="glass-panel section__panel">
      <div class="section-heading">
        <span class="heading-sec__main">Node Status</span>
        <button type="button" class="btn btn--med btn--theme section-heading__action" onclick="window.location.reload()">Refresh</button>
      </div>

      <div class="node-grid">
        {% for row in rows %}
        <div class="card">
          <h3>{{ row.node.name }}</h3>
          <div class="muted mono">{{ row.node.ip }}</div>

          {% if row.health.reachable %}
          <span class="pill good">health ok</span>
          {% else %}
          <span class="pill bad">health down</span>
          {% endif %}

          {% if row.metrics.exporter_up %}
          <span class="pill good">metrics online</span>
          {% else %}
          <span class="pill warn">metrics unavailable</span>
          {% endif %}

          {% if row.metrics.agent_up == true %}
          <span class="pill good">agent online</span>
          {% elif row.metrics.agent_up == false %}
          <span class="pill warn">agent scrape down</span>
          {% endif %}

          <div class="stat-grid">
            <div class="stat">
              <div class="stat__label">CPU Utilization</div>
              <div class="stat__value">{{ row.metrics.cpu if row.metrics.cpu is not none else 'n/a' }}</div>
            </div>
            <div class="stat">
              <div class="stat__label">Memory Used</div>
              <div class="stat__value">{{ row.metrics.mem if row.metrics.mem is not none else 'n/a' }}</div>
            </div>
            <div class="stat">
              <div class="stat__label">Root Storage Used</div>
              <div class="stat__value">{{ row.metrics.root_used if row.metrics.root_used is not none else 'n/a' }}</div>
            </div>
            <div class="stat">
              <div class="stat__label">Shared Mount Used</div>
              <div class="stat__value">{{ row.metrics.shared_used if row.metrics.shared_used is not none else 'n/a' }}</div>
            </div>
            <div class="stat">
              <div class="stat__label">Load 1m</div>
              <div class="stat__value">{{ row.metrics.load1 if row.metrics.load1 is not none else 'n/a' }}</div>
            </div>
            <div class="stat">
              <div class="stat__label">Shared Path</div>
              <div class="stat__value">
                {% if row.health.data and row.health.data.shared_path_exists is sameas true %}yes{% elif row.health.data and row.health.data.shared_path_exists is sameas false %}no{% else %}n/a{% endif %}
              </div>
            </div>
          </div>

          {% if row.node.name != 'COE892-RPi' %}
          <table>
            <tr><th>RabbitMQ</th><td>{{ row.health.data.rabbitmq if row.health.data else 'n/a' }}</td></tr>
            <tr><th>Postgres</th><td>{{ row.health.data.postgres if row.health.data else 'n/a' }}</td></tr>
            <tr><th>Health error</th><td class="mono">{{ row.health.error }}</td></tr>
          </table>
          {% endif %}
        </div>
        {% endfor %}
      </div>
    </div>

    <div class="glass-panel section__panel">
      <div class="section-heading">
        <span class="heading-sec__main">Gluster Failover Ring</span>
      </div>

      <div class="grid-3">
        {% for item in failover_ring %}
        <div class="ring-item">
          <div style="font-size:2rem;font-weight:900;color:#fff;">{{ item.client }}</div>
          <div style="margin-top:0.8rem;font-size:1.6rem;color:var(--textSoft);">primary: <span class="mono">{{ item.primary }}</span></div>
          <div style="margin-top:0.4rem;font-size:1.6rem;color:var(--textSoft);">backup: <span class="mono">{{ item.backup }}</span></div>
        </div>
        {% endfor %}
      </div>
    </div>

    <div class="glass-panel section__panel">
      <div class="section-heading">
        <span class="heading-sec__main">Recent Jobs</span>
      </div>

      <table>
        <thead>
          <tr>
            <th>Submitted At</th>
            <th>Job Type</th>
            <th>State</th>
            <th>Claimed By</th>
            <th>Attempts</th>
            <th>Submitted By</th>
          </tr>
        </thead>
        <tbody>
          {% for job in jobs %}
          <tr>
            <td class="mono">{{ job.submitted_at }}</td>
            <td class="mono">{{ job.job_type }}</td>
            <td>{{ job.state }}</td>
            <td>{{ job.claimed_by }}</td>
            <td>{{ job.attempt_count }}</td>
            <td>{{ job.submitted_by }}</td>
          </tr>
          {% endfor %}
        </tbody>
      </table>
    </div>
  </section>

  <footer class="main-footer" aria-label="Footer">
    <div class="glass-panel footer__panel">
      <div class="main-footer__upper">
        <div>
          <div class="heading-sm">Social</div>
          <div class="main-footer__social-cont">
            <a href="https://www.linkedin.com/in/krishadmin" target="_blank" rel="noopener noreferrer" aria-label="LinkedIn">
              <img src="https://krishadmin.com/pics/Icon-LinkedIn.png" alt="" class="main-footer__icon" />
            </a>
            <a href="https://github.com/KrishPAdmin" target="_blank" rel="noopener noreferrer" aria-label="GitHub">
              <img src="https://krishadmin.com/pics/Icon-Github.png" alt="" class="main-footer__icon" />
            </a>
            <a href="https://www.youtube.com/channel/UCPOpecefAO1ub4KB50wDmjg" target="_blank" rel="noopener noreferrer" aria-label="YouTube">
              <img src="https://krishadmin.com/pics/Icon-Youtube.png" alt="" class="main-footer__icon" />
            </a>
            <a href="https://www.instagram.com/krish_admin/" target="_blank" rel="noopener noreferrer" aria-label="Instagram">
              <img src="https://krishadmin.com/pics/Icon-Instagram.png" alt="" class="main-footer__icon" />
            </a>
            <a href="https://discord.com/users/290130274010923010" target="_blank" rel="noopener noreferrer" aria-label="Discord">
              <img src="https://krishadmin.com/pics/Icon-Discord.png" alt="" class="main-footer__icon" />
            </a>
          </div>
          <div class="footer-emails">
            Discord: <a href="https://discord.com/users/290130274010923010" target="_blank" rel="noopener noreferrer" style="color:var(--accent);text-decoration:underline;">DM me here</a><br />
            Email: <a href="mailto:krish@krishadmin.com" style="color:var(--accent);text-decoration:underline;">krish@krishadmin.com</a>
          </div>
        </div>
        <div>
          <div class="heading-sm">About</div>
          <div class="main-footer__short-desc">
            ProxSyncQ Raspberry Pi control plane for cluster health, queue orchestration, shared storage visibility, and Gluster failover mapping.
          </div>
        </div>
      </div>
      <div class="main-footer__lower">
        © <span id="yearNow"></span> Krish Patel. Built for <a href="https://krishadmin.com" style="color:var(--accent);text-decoration:underline;">www.krishadmin.com</a>
      </div>
    </div>
  </footer>

  <script>
    (function () {
      var yearNow = document.getElementById("yearNow");
      if (yearNow) yearNow.textContent = String(new Date().getFullYear());
      setInterval(function () {
        if (!document.hidden) window.location.reload();
      }, 20000);
    })();
  </script>
</body>
</html>
HTML

echo "== syncing UI and prometheus config to Pi =="
rsync -av rpi-control/ "${PI_USER}@${PI_HOST}:/home/${PI_USER}/proxsyncq-rpi/"

echo
echo "== ensuring node exporter is enabled on all nodes =="
for host in "${ALL_HOSTS[@]}"; do
  echo "== ${host} =="
  ssh -tt "${PI_USER}@${host}" 'sudo bash -s' <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get install -y prometheus-node-exporter curl ca-certificates
systemctl enable --now prometheus-node-exporter
systemctl is-active prometheus-node-exporter || true
ss -ltnp | grep ':9100' || true
REMOTE
  echo
done

echo "== restarting Pi UI stack =="
ssh -tt "${PI_USER}@${PI_HOST}" 'bash -s' <<'REMOTE'
set -euo pipefail
cd ~/proxsyncq-rpi
sudo docker compose up -d --build control_ui
sudo docker compose restart prometheus
sleep 6
sudo docker compose ps
echo
echo "== prometheus targets =="
curl -fsS http://127.0.0.1:9090/api/v1/targets | sed -n '1,220p' || true
echo
echo "== control_ui logs =="
sudo docker compose logs --tail=80 control_ui || true
REMOTE

echo
echo "== checking port 9100 on all nodes from Pi =="
ssh -tt "${PI_USER}@${PI_HOST}" 'bash -s' <<'REMOTE'
set -euo pipefail
for host in 10.26.0.170 10.26.0.171 10.26.0.172 10.26.0.173; do
  echo "== ${host}:9100 =="
  curl -fsS --max-time 5 "http://${host}:9100/metrics" | sed -n '1,3p' || echo "node_exporter failed on ${host}"
  echo
done
REMOTE

echo
echo "== checking node-agent health endpoints from Pi =="
ssh -tt "${PI_USER}@${PI_HOST}" 'bash -s' <<'REMOTE'
set -euo pipefail
for host in 10.26.0.171 10.26.0.172 10.26.0.173; do
  echo "== ${host}:8000/health =="
  curl -fsS --max-time 5 "http://${host}:8000/health" || echo "node agent failed on ${host}"
  echo
done
REMOTE

echo
echo "== final quick checks =="
curl -fsS --max-time 5 "http://${PI_HOST}:8080" >/dev/null && echo "control_ui: ok" || echo "control_ui: fail"
curl -fsS --max-time 5 "http://${PI_HOST}:9090/-/healthy" && echo || true
curl -fsS --max-time 5 "http://${PI_HOST}:3000/api/health" && echo || true

echo
echo "done"
