/*
 * Logview theme control
 * FILE: logview/theme.js
 */
(function () {
  'use strict';
  var theme = 'dark';
  try { if (localStorage.getItem('logview_theme') === 'light') theme = 'light'; } catch (e) {}

  function sync(frame) {
    if (frame.contentWindow && frame.hasAttribute('src')) {
      frame.contentWindow.postMessage({type: 'logview-theme', theme: theme}, location.origin);
    }
  }

  function apply(value) {
    theme = value === 'dark' ? 'dark' : 'light';
    document.documentElement.classList.toggle('dark', theme === 'dark');
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
      apply(event.newValue === 'light' ? 'light' : 'dark');
    }
  });
  document.addEventListener('DOMContentLoaded', function () { apply(theme); });
  apply(theme);
})();
