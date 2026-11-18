'use strict';
/* Публичный сайт: меню, форма заявки (UTM, защита от повторной отправки), согласие на аналитику. */
(function () {
  const $ = (s, r = document) => r.querySelector(s);
  // Меню на телефоне
  const burger = $('[data-burger]');
  if (burger) burger.onclick = () => { const h = $('.hdr'); h.classList.toggle('open'); burger.setAttribute('aria-expanded', h.classList.contains('open')); };

  // UTM: запоминаем первую метку визита, чтобы она дошла до заявки с любой страницы.
  const UTM = ['utm_source', 'utm_medium', 'utm_campaign', 'utm_content', 'utm_term'];
  const q = new URLSearchParams(location.search);
  const store = (k, v) => { try { sessionStorage.setItem(k, v); } catch { /* приватный режим */ } };
  const read = (k) => { try { return sessionStorage.getItem(k) || ''; } catch { return ''; } };
  UTM.forEach((k) => { if (q.get(k)) store(k, q.get(k)); });
  if (!read('mk_ref') && document.referrer && !document.referrer.startsWith(location.origin)) store('mk_ref', document.referrer);

  const token = () => (crypto.randomUUID ? crypto.randomUUID() : String(Date.now()) + Math.random().toString(16).slice(2));
  document.querySelectorAll('[data-lead]').forEach((form) => {
    let formToken = token();
    const msg = $('.form-msg', form);
    const btn = $('button[type=submit]', form);
    form.addEventListener('submit', async (e) => {
      e.preventDefault();
      msg.className = 'form-msg';
      if (!form.name.value.trim() || form.phone.value.replace(/\D/g, '').length < 10) { msg.textContent = 'Укажите имя и телефон.'; msg.classList.add('err'); return; }
      if (!form.consent.checked) { msg.textContent = 'Нужно согласие на обработку данных.'; msg.classList.add('err'); return; }
      const fd = new FormData(form);
      fd.set('form_token', formToken);
      fd.set('page', location.pathname);
      fd.set('referrer', read('mk_ref'));
      UTM.forEach((k) => fd.set(k, read(k)));
      if (!form.file || !form.file.files.length) fd.delete('file');
      btn.disabled = true;
      msg.textContent = 'Отправляем…';
      try {
        const res = await fetch('/api/public/leads', { method: 'POST', headers: { 'X-CRM': '1' }, body: fd });
        const out = await res.json().catch(() => ({}));
        if (!res.ok) throw new Error(out.error || 'Не удалось отправить заявку. Позвоните нам, пожалуйста.');
        // Успех показываем только после ответа сервера о сохранении заявки.
        form.reset();
        formToken = token();
        msg.textContent = 'Заявка принята. Мы перезвоним в рабочее время.';
        msg.classList.add('ok');
        if (window.ym && window.SITE.metrika) window.ym(window.SITE.metrika, 'reachGoal', 'lead');
      } catch (ex) { msg.textContent = ex.message; msg.classList.add('err'); } finally { btn.disabled = false; }
    });
  });

  // Аналитика — только после согласия посетителя (152-ФЗ).
  const S = window.SITE || {};
  const consent = (() => { try { return localStorage.getItem('mk_cookie'); } catch { return null; } })();
  const loadAnalytics = () => {
    if (S.metrika) {
      /* Яндекс Метрика */
      (function (m, e, t, r, i) { m[i] = m[i] || function () { (m[i].a = m[i].a || []).push(arguments); }; m[i].l = 1 * new Date(); const k = e.createElement(t); k.async = 1; k.src = r; e.head.appendChild(k); })(window, document, 'script', 'https://mc.yandex.ru/metrika/tag.js', 'ym');
      window.ym(S.metrika, 'init', { clickmap: true, trackLinks: true, accurateTrackBounce: true, webvisor: false });
    }
    if (S.ga4) {
      const s = document.createElement('script'); s.async = true; s.src = `https://www.googletagmanager.com/gtag/js?id=${encodeURIComponent(S.ga4)}`; document.head.appendChild(s);
      window.dataLayer = window.dataLayer || []; window.gtag = function () { window.dataLayer.push(arguments); }; window.gtag('js', new Date()); window.gtag('config', S.ga4);
    }
  };
  const banner = $('[data-cookie]');
  if (consent === 'all') loadAnalytics();
  else if (!consent && banner && (S.metrika || S.ga4)) banner.hidden = false;
  const save = (v) => { try { localStorage.setItem('mk_cookie', v); } catch { /* без сохранения */ } banner.hidden = true; if (v === 'all') loadAnalytics(); };
  $('[data-cookie-ok]')?.addEventListener('click', () => save('all'));
  $('[data-cookie-no]')?.addEventListener('click', () => save('necessary'));

  // Плавное появление блоков
  if ('IntersectionObserver' in window) {
    const io = new IntersectionObserver((es) => es.forEach((en) => { if (en.isIntersecting) { en.target.classList.add('in'); io.unobserve(en.target); } }), { threshold: 0.1 });
    document.querySelectorAll('.section').forEach((el) => { el.classList.add('reveal'); io.observe(el); });
  }
})();
