// Textly – Anleitung: gemeinsamer Kopf, Fuss, Weiter/Zurück und die Markierungen in den Bildern.
// Keine Bibliotheken, kein Build-Schritt: die Seiten funktionieren auch direkt ab der Festplatte.

// ---- Einstellungen: nur hier anpassen ---------------------------------------------------------
const TEXTLY = {
  // GitHub-Konto und Projekt
  repo: 'Asu-Builds/Textly',
  version: '0.2.0',
};
TEXTLY.repoUrl = 'https://github.com/' + TEXTLY.repo;
// «latest» zeigt immer auf die neueste Version; der Dateiname bleibt dafür gleich
TEXTLY.download = TEXTLY.repoUrl + '/releases/latest/download/Textly-Setup.exe';
TEXTLY.issues = TEXTLY.repoUrl + '/issues';

// Reihenfolge der Kapitel (für Navigation und Weiter/Zurück)
const PAGES = [
  ['index.html', 'Start', '🏠'],
  ['installieren.html', 'Herunterladen und installieren', '⬇️'],
  ['erste-einladung.html', 'Deine erste Einladung', '✉️'],
  ['nichts-geht-verloren.html', 'Nichts geht verloren', '↩️'],
  ['bilder.html', 'Bilder einsetzen und zuschneiden', '🖼️'],
  ['tabellen.html', 'Tabellen', '▦'],
  ['formate.html', 'A5, A4, A3 – hoch oder quer', '📐'],
  ['word-powerpoint.html', 'Word- und PowerPoint-Dateien öffnen', '📄'],
  ['drucken-pdf.html', 'Drucken, PDF und E-Mail', '🖨️'],
  ['eigene-vorlagen.html', 'Eigene Vorlagen', '⭐'],
  ['tastenkuerzel.html', 'Tastenkürzel', '⌨️'],
  ['fragen.html', 'Häufige Fragen', '❓'],
];

(function () {
  const here = (location.pathname.split('/').pop() || 'index.html').toLowerCase();
  const idx = PAGES.findIndex(p => p[0] === here);

  // ---- Kopf
  const top = document.createElement('header');
  top.className = 'top';
  const nav = [
    ['erste-einladung.html', 'Anleitung'],
    ['fragen.html', 'Fragen'],
  ].map(([href, t]) => `<a href="${href}"${href === here ? ' aria-current="page"' : ''}>${t}</a>`).join('');
  top.innerHTML = `<div class="top-in">
      <a class="brand" href="index.html"><img src="logo.svg" alt="">Textly</a>
      <nav>${nav}<a class="btn small" data-download href="#">⬇ Herunterladen</a></nav>
    </div>`;
  document.body.prepend(top);

  // ---- Weiter / Zurück (nur auf Kapitelseiten)
  const main = document.querySelector('main');
  if (idx > 0 && main && !main.hasAttribute('data-no-pager')) {
    const prev = PAGES[idx - 1], next = PAGES[idx + 1];
    const pager = document.createElement('div');
    pager.className = 'pager';
    pager.innerHTML =
      (prev ? `<a href="${prev[0]}"><small>← Zurück</small>${prev[1]}</a>` : '<span></span>') +
      (next ? `<a class="next" href="${next[0]}"><small>Weiter →</small>${next[1]}</a>` : '');
    (main.querySelector('.read') || main).append(pager);
  }

  // ---- Fuss
  const foot = document.createElement('footer');
  foot.innerHTML = `<div class="foot-in">
      <span>Textly ${TEXTLY.version} · kostenlos · für Windows 10 und 11</span>
      <span><a href="kurzanleitung.pdf">Kurzanleitung zum Ausdrucken (PDF)</a> ·
        <a data-issues href="#">Frage stellen oder Fehler melden</a> ·
        <a href="${TEXTLY.repoUrl}">Projekt auf GitHub</a></span>
    </div>`;
  document.body.append(foot);

  // ---- Links und Platzhalter
  document.querySelectorAll('[data-download]').forEach(a => { a.href = TEXTLY.download; });
  document.querySelectorAll('[data-issues]').forEach(a => { a.href = TEXTLY.issues; });
  document.querySelectorAll('[data-version]').forEach(e => { e.textContent = TEXTLY.version; });

  // ---- Kapitelliste (Startseite und Fragen)
  document.querySelectorAll('[data-chapters]').forEach(box => {
    box.innerHTML = PAGES.slice(1).map(([href, t, ic], i) =>
      `<a class="tile${i === 1 ? ' main' : ''}" href="${href}"><span class="ic">${ic}</span><b>${t}</b>` +
      `<span>${(document.querySelector(`[data-blurb="${href}"]`) || {}).textContent || ''}</span></a>`).join('');
  });

  // ---- Bilder mit nummerierten Markierungen
  // <figure class="shot" data-shot="vorlage-offen" data-marks="tool-text,tool-finish" data-crop="x,y,b,h">
  // Die Lage der Knöpfe kommt aus bilder/marken.js (vom Bildschirmfoto-Werkzeug erzeugt).
  const all = window.TEXTLY_MARKEN || {};
  document.querySelectorAll('figure.shot[data-shot]').forEach(fig => {
    const name = fig.dataset.shot;
    const [cx, cy, cw, ch] = (fig.dataset.crop || '0,0,100,100').split(',').map(Number);
    // Klick öffnet das Bild in voller Grösse
    const frame = document.createElement('a');
    frame.className = 'frame';
    frame.href = `bilder/${name}.png`;
    frame.target = '_blank';
    frame.title = 'Bild gross anzeigen';
    frame.style.aspectRatio = `${1280 * cw} / ${760 * ch}`;
    const img = document.createElement('img');
    img.src = `bilder/${name}.png`;
    img.alt = fig.dataset.alt || fig.querySelector('figcaption')?.textContent || '';
    img.loading = 'lazy';
    Object.assign(img.style, {
      position: 'absolute', width: `${10000 / cw}%`, maxWidth: 'none',
      left: `${-cx * 100 / cw}%`, top: `${-cy * 100 / ch}%`,
    });
    frame.append(img);
    const keys = (fig.dataset.marks || '').split(',').map(s => s.trim()).filter(Boolean);
    keys.forEach((k, i) => {
      const r = (all[name] || {})[k];
      if (!r) { console.warn('Markierung fehlt:', name, k); return; }
      const pad = 0.5;
      const m = document.createElement('div');
      m.className = 'mark';
      Object.assign(m.style, {
        left: `${(r[0] - pad - cx) * 100 / cw}%`, top: `${(r[1] - pad - cy) * 100 / ch}%`,
        width: `${(r[2] + 2 * pad) * 100 / cw}%`, height: `${(r[3] + 2 * pad) * 100 / ch}%`,
      });
      m.innerHTML = `<b>${i + 1}</b>`;
      frame.append(m);
    });
    fig.prepend(frame);
  });
})();
