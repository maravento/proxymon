(function () {
  'use strict';
  var theme = 'light';
  try { if (localStorage.getItem('logview_theme') === 'dark') theme = 'dark'; } catch (e) {}

  function sync(frame) {
    if (frame.contentWindow && frame.hasAttribute('src')) {
      frame.contentWindow.postMessage({type: 'logview-theme', theme: theme}, location.origin);
    }
  }

  function apply(value) {
    theme = value === 'dark' ? 'dark' : 'light';
    if (document.body) document.body.classList.toggle('dark', theme === 'dark');
    var style = document.getElementById('sqstatTheme');
    if (style) style.setAttribute('href', theme === 'dark' ? 'sqstat-dark.css' : 'sqstat.css');
    var button = document.getElementById('btnTheme');
    if (button) {
      button.textContent = theme === 'dark' ? '☀️' : '🌙';
      button.setAttribute('aria-pressed', String(theme === 'dark'));
      button.setAttribute('aria-label', theme === 'dark' ? 'Switch to light theme' : 'Switch to dark theme');
      button.title = theme === 'dark' ? 'Switch to light theme' : 'Switch to dark theme';
    }
    document.querySelectorAll('iframe').forEach(sync);
  }

  window.logviewTheme = {
    sync: sync,
    toggle: function () {
      apply(theme === 'dark' ? 'light' : 'dark');
      try { localStorage.setItem('logview_theme', theme); } catch (e) {}
    }
  };
  window.addEventListener('message', function (event) {
    if (event.source !== parent || event.origin !== location.origin) return;
    if (!event.data || event.data.type !== 'logview-theme') return;
    if (event.data.theme === 'dark' || event.data.theme === 'light') apply(event.data.theme);
  });
  window.addEventListener('storage', function (event) {
    if (event.key === 'logview_theme' || event.key === null) {
      apply(event.newValue === 'dark' ? 'dark' : 'light');
    }
  });
  document.addEventListener('DOMContentLoaded', function () { apply(theme); });
  apply(theme);
})();
