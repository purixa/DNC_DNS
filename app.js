const loginScreen = document.getElementById('login-screen');
const appScreen = document.getElementById('app-screen');
const loginForm = document.getElementById('login-form');
const loginError = document.getElementById('login-error');
const serverIpBadge = document.getElementById('server-ip-badge');
const statusGrid = document.getElementById('status-grid');
const restartBtn = document.getElementById('restart-btn');
const addDomainForm = document.getElementById('add-domain-form');
const addDomainInput = document.getElementById('new-domain-input');
const addDomainMsg = document.getElementById('add-domain-msg');
const gamepacksGrid = document.getElementById('gamepacks-grid');
const domainsList = document.getElementById('domains-list');
const logoutBtn = document.getElementById('logout-btn');

let knownDomains = [];

async function api(path, opts = {}) {
  const res = await fetch(path, {
    headers: { 'Content-Type': 'application/json' },
    ...opts,
  });
  const data = await res.json().catch(() => ({ ok: false, error: 'پاسخ نامعتبر از سرور' }));
  if (!res.ok || data.ok === false) {
    throw new Error(data.error || 'خطای ناشناخته');
  }
  return data;
}

function showApp() {
  loginScreen.classList.add('hidden');
  appScreen.classList.remove('hidden');
  refreshAll();
}

function showLogin(message) {
  appScreen.classList.add('hidden');
  loginScreen.classList.remove('hidden');
  if (message) loginError.textContent = message;
}

loginForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  loginError.textContent = '';
  const username = document.getElementById('login-username').value;
  const password = document.getElementById('login-password').value;
  try {
    await api('/api/login', { method: 'POST', body: JSON.stringify({ username, password }) });
    showApp();
  } catch (err) {
    loginError.textContent = err.message;
  }
});

logoutBtn.addEventListener('click', async () => {
  try { await api('/api/logout', { method: 'POST' }); } catch (e) {}
  showLogin();
});

async function refreshStatus() {
  try {
    const data = await api('/api/status');
    serverIpBadge.textContent = data.server_ip ? `IP سرور: ${data.server_ip}` : 'نصب نشده';

    for (const el of statusGrid.querySelectorAll('.status-item')) {
      const svc = el.dataset.svc;
      const up = !!data[svc];
      el.classList.toggle('up', up);
      el.classList.toggle('down', !up);
    }

    knownDomains = data.domains || [];
    renderDomains();
  } catch (err) {
    if (err.message === 'not authenticated') {
      showLogin();
      return;
    }
    console.error(err);
  }
}

function renderDomains() {
  domainsList.innerHTML = '';
  if (knownDomains.length === 0) {
    domainsList.innerHTML = '<div class="empty-note">هنوز دامنه‌ای اضافه نشده.</div>';
    return;
  }
  for (const d of knownDomains) {
    const row = document.createElement('div');
    row.className = 'domain-row';
    row.innerHTML = `<span>${d}</span><button data-domain="${d}">حذف</button>`;
    row.querySelector('button').addEventListener('click', () => removeDomain(d));
    domainsList.appendChild(row);
  }
}

async function removeDomain(domain) {
  try {
    await api(`/api/domains/${encodeURIComponent(domain)}`, { method: 'DELETE' });
    await refreshStatus();
  } catch (err) {
    alert(`حذف ناموفق بود: ${err.message}`);
  }
}

addDomainForm.addEventListener('submit', async (e) => {
  e.preventDefault();
  addDomainMsg.textContent = '';
  addDomainMsg.className = 'msg';
  const domain = addDomainInput.value.trim();
  if (!domain) return;
  try {
    await api('/api/domains', { method: 'POST', body: JSON.stringify({ domain }) });
    addDomainMsg.textContent = `دامنه «${domain}» اضافه شد.`;
    addDomainMsg.className = 'msg ok';
    addDomainInput.value = '';
    await refreshStatus();
  } catch (err) {
    addDomainMsg.textContent = err.message;
    addDomainMsg.className = 'msg err';
  }
});

restartBtn.addEventListener('click', async () => {
  restartBtn.disabled = true;
  restartBtn.textContent = 'در حال راه‌اندازی مجدد...';
  try {
    await api('/api/restart', { method: 'POST' });
    await refreshStatus();
  } catch (err) {
    alert(`راه‌اندازی مجدد ناموفق بود: ${err.message}`);
  } finally {
    restartBtn.disabled = false;
    restartBtn.textContent = 'راه‌اندازی مجدد سرویس‌ها';
  }
});

async function loadGamepacks() {
  try {
    const data = await api('/api/gamepacks');
    gamepacksGrid.innerHTML = '';
    for (const pack of data.gamepacks || []) {
      const card = document.createElement('div');
      card.className = 'gamepack-card';
      card.innerHTML = `
        <span class="label">${pack.label}</span>
        <span class="domains">${pack.domains.join(' · ')}</span>
        <button data-key="${pack.key}">افزودن دامنه‌ها</button>
      `;
      const btn = card.querySelector('button');
      btn.addEventListener('click', async () => {
        btn.disabled = true;
        btn.textContent = 'در حال افزودن...';
        try {
          await api(`/api/gamepacks/${encodeURIComponent(pack.key)}`, { method: 'POST' });
          await refreshStatus();
          btn.textContent = 'اضافه شد ✓';
        } catch (err) {
          alert(`ناموفق: ${err.message}`);
          btn.textContent = 'افزودن دامنه‌ها';
        } finally {
          btn.disabled = false;
        }
      });
      gamepacksGrid.appendChild(card);
    }
  } catch (err) {
    if (err.message === 'not authenticated') {
      showLogin();
    }
  }
}

function refreshAll() {
  refreshStatus();
  loadGamepacks();
}

// On page load: if a valid session cookie already exists, jump
// straight to the app; otherwise show the login screen.
(async () => {
  try {
    await api('/api/status');
    showApp();
  } catch (err) {
    showLogin();
  }
})();
