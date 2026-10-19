<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Logview — Proxy Monitor</title>
<style>
*{box-sizing:border-box}body{margin:0;height:100vh;display:flex;flex-direction:column;font-family:system-ui,sans-serif;background:#f0f4f8;color:#263238;color-scheme:light}html.dark body{background:#1e2a35;color:white;color-scheme:dark}
iframe{border:0;width:100%;flex:1;min-height:0;background:white}html.dark body iframe{background:#0f1117}iframe[hidden]{display:none}
</style>
<script src="theme.js"></script>
</head>
<body>

<iframe id="accessFrame" role="region" title="Log" src="access.php"></iframe>
<iframe id="connectionsFrame" role="region" title="Live" hidden></iframe>
<script>
var currentView = 'access';
function notifyView(name) {
  var frame = document.getElementById(name + 'Frame');
  frame.contentWindow.postMessage({type:'logview-visibility',visible:name === currentView}, location.origin);
}
function mountViews(view) {
  var frame = document.getElementById(view + 'Frame');
  var doc = frame.contentDocument;
  var toolbar = doc.querySelector('.toolbar, .live-controls');
  if (!toolbar) toolbar = doc.querySelector('.header form');
  if (!toolbar) toolbar = doc.body;
  var style = doc.createElement('style');
  style.textContent = '.view-switch{display:inline-flex;gap:4px;align-items:center;flex-shrink:0;margin-right:6px}.view-switch button{font:600 12px system-ui;padding:7px 12px;border:1px solid #607d8b;border-radius:5px;background:#253545;color:#fff;cursor:pointer}.view-switch button[aria-pressed="true"]{background:#1565c0;border-color:#1565c0}.view-switch button:focus-visible{outline:2px solid #3498db;outline-offset:2px}';
  doc.head.appendChild(style);
  var controls = doc.createElement('div');
  controls.className = 'view-switch';
  controls.setAttribute('role', 'group');
  controls.setAttribute('aria-label', 'Logview views');
  ['access', 'connections'].forEach(function(name) {
    var button = doc.createElement('button');
    button.type = 'button';
    button.textContent = name === 'access' ? 'Log' : 'Live';
    button.dataset.view = name;
    button.setAttribute('aria-pressed', String(name === currentView));
    button.addEventListener('click', function() { selectView(name); });
    controls.appendChild(button);
  });
  toolbar.prepend(controls);
  if (parent === window) {
    var themeButton = doc.createElement('button');
    themeButton.type = 'button';
    themeButton.id = 'btnTheme';
    themeButton.addEventListener('click', function() { logviewTheme.toggle(); });
    controls.appendChild(themeButton);
  }
}
function selectView(name) {
  currentView = name;
  ['access','connections'].forEach(function(view) {
    var selected = view === name;
    var frame = document.getElementById(view + 'Frame');
    frame.hidden = !selected;
    if (selected && view === 'connections' && !frame.hasAttribute('src')) frame.src = 'connections.php';
    if (frame.hasAttribute('src')) {
      notifyView(view);
      if (frame.contentDocument) frame.contentDocument.querySelectorAll('[data-view]').forEach(function(button) {
        button.setAttribute('aria-pressed', String(button.dataset.view === name));
      });
    }
  });
}
['access','connections'].forEach(function(view) {
  document.getElementById(view + 'Frame').addEventListener('load',function(){
    mountViews(view);
    notifyView(view);
    logviewTheme.sync(document.getElementById(view + 'Frame'));
  });
});
</script>
</body>
</html>
