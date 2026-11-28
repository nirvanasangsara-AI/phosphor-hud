const invoke = (cmd, args) => window.__TAURI__.core.invoke(cmd, args);

const rowsEl = document.getElementById("rows");
const footEl = document.getElementById("foot");
const alertsEl = document.getElementById("alerts");
const peakEl = document.getElementById("peak");

function pct(n) {
  const v = Math.max(0, Math.min(100, Number(n) || 0));
  return Math.round(v);
}

function bar(window, color) {
  if (window.kind === "meter") {
    return `<div class="amount">${escapeHtml(window.amount || "")}</div>`;
  }
  const used = pct(window.usedPercent);
  const warn = window.warns || used >= 90;
  const fill = warn ? "#f07167" : color;
  const forecast = window.forecastText
    ? `<div class="forecast${window.warns ? " warn" : ""}">${escapeHtml(window.forecastRate ? window.forecastRate + " · " : "")}${escapeHtml(window.forecastText)}</div>`
    : "";
  const reset = window.resetsIn ? `<div class="detail">resets in ${escapeHtml(window.resetsIn)}</div>` : "";
  const amount = window.amount ? `<div class="detail">${escapeHtml(window.amount)}</div>` : "";
  return `
    <div class="win">
      <span class="label">${escapeHtml(window.label)}</span>
      <div class="bar"><span style="width:${used}%;background:${fill}"></span></div>
      <span class="pct">${used}%</span>
    </div>
    ${amount}
    ${forecast}
    ${reset}
  `;
}

function escapeHtml(s) {
  return String(s)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;");
}

function render(model) {
  const gauged = model.rows.flatMap((r) => r.windows.filter((w) => w.gauged));
  const peak = gauged.reduce((m, w) => Math.max(m, w.usedPercent || 0), 0);
  peakEl.textContent = gauged.length ? `Φ ${pct(peak)}%` : "";

  if (model.alerts && model.alerts.length) {
    alertsEl.hidden = false;
    alertsEl.textContent = model.alerts.join(" · ");
  } else {
    alertsEl.hidden = true;
  }

  if (!model.rows.length) {
    rowsEl.innerHTML = `<div class="empty">Nothing to show yet.</div>`;
  } else {
    rowsEl.innerHTML = model.rows
      .map((row) => {
        const windows = (row.windows || []).map((w) => bar(w, row.color)).join("");
        const msg = row.message ? `<div class="msg">${escapeHtml(row.message)}</div>` : "";
        const detail = row.detail ? `<div class="detail">${escapeHtml(row.detail)}</div>` : "";
        const plan = row.plan ? `<span class="plan">${escapeHtml(row.plan)}</span>` : "";
        return `
          <section class="row ${escapeHtml(row.status)}">
            <div class="head">
              <span class="badge" style="background:${escapeHtml(row.color)}">${escapeHtml(row.monogram)}</span>
              <span class="title">${escapeHtml(row.name)}</span>
              ${plan}
            </div>
            ${windows}
            ${detail}
            ${msg}
          </section>
        `;
      })
      .join("");
  }

  const f = model.footer || {};
  const money = f.apiValue ? ` · ≈$${Number(f.apiValue).toFixed(2)} API-equivalent` : "";
  const roi = f.roi ? `<div><strong>ROI ${Number(f.roi).toFixed(1)}x</strong> over ${f.days} days</div>` : "";
  const monthly = f.monthlyUsd != null ? `<div>Plans $${Number(f.monthlyUsd).toFixed(0)} / month</div>` : "";
  const dev = f.dev
    ? `<div>${escapeHtml(f.dev.login)} · merged ${f.dev.mergedToday}/${f.dev.merged7}/${f.dev.merged30} · ${escapeHtml(f.dev.tierLabel)}</div>`
    : model.showDev
      ? `<div>GitHub CLI is not logged in, so PR counts stay blank.</div>`
      : "";
  footEl.innerHTML = `
    <div>Logs ${f.days || 7}D: ${Number(f.tokens || 0).toLocaleString()} tokens${money}</div>
    ${roi}
    ${monthly}
    ${dev}
    <div>${escapeHtml(f.note || "")}</div>
    <div class="toggles">
      <label><input id="demo" type="checkbox" ${model.demo ? "checked" : ""}/> Demo data</label>
      <label><input id="dev" type="checkbox" ${model.showDev ? "checked" : ""}/> GitHub PRs</label>
      <label><input id="phone-sync" type="checkbox"/> Phone sync</label>
    </div>
  `;
  document.getElementById("demo").addEventListener("change", async (e) => {
    await invoke("set_demo", { enabled: e.target.checked });
    refresh();
  });
  document.getElementById("dev").addEventListener("change", async (e) => {
    await invoke("set_show_dev", { enabled: e.target.checked });
    refresh();
  });
  document.getElementById("phone-sync").addEventListener("change", async (e) => {
    const view = await invoke("set_phone_sync", { enabled: e.target.checked });
    showPhone(view);
  });
  loadPhone();
}

function showPhone(view) {
  const box = document.getElementById("phone-card");
  const toggle = document.getElementById("phone-sync");
  if (toggle) toggle.checked = !!view.enabled;
  if (!view || !view.enabled) {
    box.hidden = true;
    box.innerHTML = "";
    return;
  }
  box.hidden = false;
  box.innerHTML = `
    <div>Same Wi-Fi. The phone keeps a pairing token, not your logins.</div>
    <div class="code">${escapeHtml(view.code || "")}</div>
    <div>${escapeHtml(view.host || "")}:${view.port || ""}</div>
    <div>${view.qrSvg || ""}</div>
    <button id="new-code" type="button">New code</button>
  `;
  document.getElementById("new-code").addEventListener("click", async () => {
    showPhone(await invoke("rotate_phone_code"));
  });
}

async function loadPhone() {
  try {
    showPhone(await invoke("phone_sync_state"));
  } catch (_) {
    /* the card stays hidden until the command exists */
  }
}

async function refresh() {
  try {
    const model = await invoke("hud_state");
    render(model);
  } catch (err) {
    rowsEl.innerHTML = `<div class="empty">Could not read usage. ${escapeHtml(err)}</div>`;
  }
}

document.getElementById("refresh").addEventListener("click", refresh);
document.getElementById("hide").addEventListener("click", () => invoke("hide_hud"));
refresh();
setInterval(refresh, 60_000);
